// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RateSortedList} from "../src/core/RateSortedList.sol";

/// Plays the branch: random insertions, removals and rate changes, each with hints that are exact, empty, listed but
/// wrong, stale or arbitrary. It keeps its own record of which Trove is listed at which rate (the ghost), and never calls
/// the list in a way the list is entitled to refuse, so with `fail_on_revert` any revert is a finding.
contract RateSortedListHandler is Test {
    RateSortedList public immutable list;
    uint256 constant MAX_ID = 96;

    uint256[] internal _ids; // listed, in no particular order
    mapping(uint256 => uint256) public ghostRate;
    mapping(uint256 => bool) public ghostListed;

    constructor() {
        list = new RateSortedList(address(this));
    }

    function ghost() external view returns (uint256[] memory ids, uint256[] memory rates) {
        ids = _ids;
        rates = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            rates[i] = ghostRate[ids[i]];
        }
    }

    function _rate(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 8;
        if (k < 5) {
            return [uint256(5e15), 1e16, 2e16, 3e16, 7e16][k]; // a handful of rates: ties are the common case
        }
        return bound(seed >> 8, 5e15, 25e17); // the branch's whole range (SPEC 2)
    }

    function _hint(uint256 seed) internal view returns (uint256) {
        uint256 k = seed % 4;
        if (k == 0) {
            return 0;
        }
        if (k == 1 && _ids.length > 0) {
            return _ids[(seed >> 8) % _ids.length]; // listed, and almost always the wrong neighbour
        }
        if (k == 2) {
            return bound(seed >> 8, 1, MAX_ID); // listed, or removed some time ago: a stale hint
        }
        return seed; // arbitrary
    }

    function _hints(uint256 id, uint256 rate, uint256 h1, uint256 h2) internal view returns (uint256, uint256) {
        if (h1 % 5 == 0) {
            return list.findInsertPosition(id, rate, 0, 0); // exact, as a front end would compute them
        }
        return (_hint(h1), _hint(h2));
    }

    function insert(uint256 idSeed, uint256 rateSeed, uint256 h1, uint256 h2) external {
        uint256 id = bound(idSeed, 1, MAX_ID);
        if (ghostListed[id]) {
            return;
        }
        uint256 rate = _rate(rateSeed);
        (uint256 p, uint256 q) = _hints(id, rate, h1, h2);
        list.insert(id, rate, p, q);
        ghostListed[id] = true;
        ghostRate[id] = rate;
        _ids.push(id);
    }

    function remove(uint256 pick) external {
        if (_ids.length == 0) {
            return;
        }
        uint256 i = pick % _ids.length;
        uint256 id = _ids[i];
        list.remove(id);
        _ids[i] = _ids[_ids.length - 1];
        _ids.pop();
        ghostListed[id] = false;
        ghostRate[id] = 0;
    }

    function reinsert(uint256 pick, uint256 rateSeed, uint256 h1, uint256 h2) external {
        if (_ids.length == 0) {
            return;
        }
        uint256 id = _ids[pick % _ids.length];
        uint256 rate = _rate(rateSeed);
        (uint256 p, uint256 q) = _hints(id, rate, h1, h2);
        list.reinsert(id, rate, p, q);
        ghostRate[id] = rate;
    }
}

contract RateSortedListInvariantTest is StdInvariant, Test {
    RateSortedListHandler handler;
    RateSortedList list;

    function setUp() public {
        handler = new RateSortedListHandler();
        list = handler.list();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = RateSortedListHandler.insert.selector;
        selectors[1] = RateSortedListHandler.remove.selector;
        selectors[2] = RateSortedListHandler.reinsert.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// SPEC R2 after any sequence: the list holds exactly the listed Troves, at their rates, in the one order the rule
    /// allows. The reference order is computed here from the ghost by a plain sort, independently of the list's walks.
    function invariant_orderIsCanonical() public view {
        (uint256[] memory ids, uint256[] memory rates) = handler.ghost();
        uint256 n = ids.length;
        for (uint256 i = 1; i < n; i++) {
            (uint256 id, uint256 r) = (ids[i], rates[i]);
            uint256 j = i;
            while (j > 0 && (rates[j - 1] > r || (rates[j - 1] == r && ids[j - 1] > id))) {
                ids[j] = ids[j - 1];
                rates[j] = rates[j - 1];
                j--;
            }
            ids[j] = id;
            rates[j] = r;
        }
        assertEq(list.size(), n, "R2: size() differs from the number of listed Troves");
        uint256 x = list.last();
        uint256 behind;
        for (uint256 i = 0; i < n; i++) {
            assertEq(x, ids[i], "R2: redemption order is not (rate, id) ascending");
            assertEq(list.rateOf(x), rates[i], "R2: a Trove is listed at the wrong rate");
            assertEq(list.next(x), behind, "R2: next and prev links disagree");
            assertTrue(list.contains(x));
            behind = x;
            x = list.prev(x);
        }
        assertEq(x, 0, "R2: the list holds a Trove that is not listed");
        assertEq(list.first(), behind, "R2: the head is not the highest (rate, id)");
    }
}
