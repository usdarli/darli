// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IRateSortedList} from "../interfaces/ICore.sol";
import {NotAuthorized} from "../Types.sol";

/// @title RateSortedList
/// @notice The redemption queue of one branch (`docs/SPEC.md` R2): its Active Troves, doubly linked, ordered by
///         (annualRate, id) from the highest at the head to the lowest at the tail. Redemption starts at `last()` and
///         walks `prev()`: lowest rate first and, among equal rates, the lower Trove id first, exactly as
///         `Branch.redemption_order()` of the reference model.
/// @dev    Because (rate, id) is a total order, a given set of Troves has exactly one valid list. Hints can therefore only
///         change the cost of an insertion, never where it lands: a hint that is stale, wrong, absent or hostile is
///         repaired by walking from it, or from the head when it points nowhere useful. Exact hints cost O(1).
///         `remove` needs no hint and no walk, so closing, liquidating or settling a Trove is constant work (AGENTS.md:
///         no scan over all Troves after a shutdown). No external calls, no events: the branch emits the Trove events.
contract RateSortedList is IRateSortedList {
    error BranchIsZero();
    error IdIsZero();
    error AlreadyInList(uint256 id);
    error NotInList(uint256 id);

    struct Node {
        uint256 prev; // nearer the head: ranks higher
        uint256 next; // nearer the tail: ranks lower
        uint128 rate; // the branch bounds rates far below 2^128 (SPEC 2); larger values revert on the cast
        bool exists;
    }

    /// @notice the only address that may change the list; set once, no setter (no admin path).
    address public immutable branch;

    uint256 private _head;
    uint256 private _tail;
    uint256 private _size;
    mapping(uint256 => Node) private _nodes;

    constructor(address branch_) {
        if (branch_ == address(0)) revert BranchIsZero();
        branch = branch_;
    }

    modifier onlyBranch() {
        if (msg.sender != branch) revert NotAuthorized();
        _;
    }

    // --- mutations (branch only) --------------------------------------------------------------------------------------

    function insert(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint) external onlyBranch {
        _insert(id, annualRate, prevHint, nextHint);
    }

    function remove(uint256 id) external onlyBranch {
        _remove(id);
    }

    function reinsert(uint256 id, uint256 newRate, uint256 prevHint, uint256 nextHint) external onlyBranch {
        _remove(id);
        _insert(id, newRate, prevHint, nextHint);
    }

    // --- views --------------------------------------------------------------------------------------------------------

    function findInsertPosition(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint)
        external
        view
        returns (uint256 prevId, uint256 nextId)
    {
        return _findPosition(id, annualRate, prevHint, nextHint);
    }

    function first() external view returns (uint256) {
        return _head;
    }

    function last() external view returns (uint256) {
        return _tail;
    }

    function next(uint256 id) external view returns (uint256) {
        return _nodes[id].next;
    }

    function prev(uint256 id) external view returns (uint256) {
        return _nodes[id].prev;
    }

    function size() external view returns (uint256) {
        return _size;
    }

    function contains(uint256 id) external view returns (bool) {
        return _nodes[id].exists;
    }

    function rateOf(uint256 id) external view returns (uint256) {
        return _nodes[id].rate;
    }

    // --- internals ----------------------------------------------------------------------------------------------------

    function _insert(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint) private {
        if (id == 0) revert IdIsZero();
        Node storage node = _nodes[id];
        if (node.exists) revert AlreadyInList(id);
        uint128 rate = SafeCast.toUint128(annualRate);
        (uint256 p, uint256 q) = _findPosition(id, annualRate, prevHint, nextHint);
        node.prev = p;
        node.next = q;
        node.rate = rate;
        node.exists = true;
        if (p == 0) {
            _head = id;
        } else {
            _nodes[p].next = id;
        }
        if (q == 0) {
            _tail = id;
        } else {
            _nodes[q].prev = id;
        }
        ++_size;
    }

    function _remove(uint256 id) private {
        Node storage node = _nodes[id];
        if (!node.exists) revert NotInList(id);
        (uint256 p, uint256 q) = (node.prev, node.next);
        if (p == 0) {
            _head = q;
        } else {
            _nodes[p].next = q;
        }
        if (q == 0) {
            _tail = p;
        } else {
            _nodes[q].prev = p;
        }
        delete _nodes[id];
        --_size;
    }

    /// (aRate, aId) ranks strictly ahead of (bRate, bId): nearer the head, redeemed later.
    function _ahead(uint256 aRate, uint256 aId, uint256 bRate, uint256 bId) private pure returns (bool) {
        return aRate > bRate || (aRate == bRate && aId > bId);
    }

    // Every walk below looks at the list WITHOUT `id`. During an insertion `id` is not listed, so this changes nothing;
    // for the view it means that asking about a listed Trove at a new rate returns the hints `reinsert` needs.

    function _listed(uint256 x, uint256 id) private view returns (bool) {
        return x != id && _nodes[x].exists;
    }

    function _headWithout(uint256 id) private view returns (uint256 h) {
        h = _head;
        if (h != 0 && h == id) {
            h = _nodes[h].next;
        }
    }

    function _tailWithout(uint256 id) private view returns (uint256 t) {
        t = _tail;
        if (t != 0 && t == id) {
            t = _nodes[t].prev;
        }
    }

    function _nextWithout(uint256 x, uint256 id) private view returns (uint256 n) {
        n = _nodes[x].next;
        if (n != 0 && n == id) {
            n = _nodes[n].next;
        }
    }

    function _prevWithout(uint256 x, uint256 id) private view returns (uint256 p) {
        p = _nodes[x].prev;
        if (p != 0 && p == id) {
            p = _nodes[p].prev;
        }
    }

    /// (p, q) is THE position of (rate, id): adjacent, p ahead of it (or p = 0 at the head), q behind it (or q = 0 at the
    /// tail). p and q must already be listed (or zero).
    function _valid(uint256 id, uint256 rate, uint256 p, uint256 q) private view returns (bool) {
        if (p == 0 && q == 0) {
            return _headWithout(id) == 0;
        }
        if (p == 0) {
            return _headWithout(id) == q && _ahead(rate, id, _nodes[q].rate, q);
        }
        if (q == 0) {
            return _tailWithout(id) == p && _ahead(_nodes[p].rate, p, rate, id);
        }
        return _nextWithout(p, id) == q && _ahead(_nodes[p].rate, p, rate, id) && _ahead(rate, id, _nodes[q].rate, q);
    }

    function _findPosition(uint256 id, uint256 rate, uint256 prevHint, uint256 nextHint)
        private
        view
        returns (uint256, uint256)
    {
        uint256 p = _listed(prevHint, id) ? prevHint : 0;
        uint256 q = _listed(nextHint, id) ? nextHint : 0;
        if (_valid(id, rate, p, q)) {
            return (p, q);
        }
        // A listed node that ranks ahead is a correct starting point however stale it is: walk towards the tail from it.
        if (p != 0 && _ahead(_nodes[p].rate, p, rate, id)) {
            return _descend(id, rate, p);
        }
        if (q != 0 && _ahead(rate, id, _nodes[q].rate, q)) {
            return _ascend(id, rate, q);
        }
        return _descend(id, rate, 0);
    }

    /// Walk towards the tail from `start` (0 = from the head) while the next node still ranks ahead.
    function _descend(uint256 id, uint256 rate, uint256 start) private view returns (uint256 p, uint256 q) {
        p = start;
        q = start == 0 ? _headWithout(id) : _nextWithout(start, id);
        while (q != 0 && _ahead(_nodes[q].rate, q, rate, id)) {
            p = q;
            q = _nextWithout(q, id);
        }
    }

    /// Walk towards the head from `start` while the previous node still ranks behind.
    function _ascend(uint256 id, uint256 rate, uint256 start) private view returns (uint256 p, uint256 q) {
        q = start;
        p = _prevWithout(start, id);
        while (p != 0 && _ahead(rate, id, _nodes[p].rate, p)) {
            q = p;
            p = _prevWithout(p, id);
        }
    }
}
