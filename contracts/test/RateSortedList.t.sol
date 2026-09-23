// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RateSortedList} from "../src/core/RateSortedList.sol";
import {NotAuthorized} from "../src/Types.sol";

/// SPEC R2: the redemption queue. This contract plays the branch (the only address allowed to change the list).
contract RateSortedListTest is Test {
    RateSortedList list;
    uint256 constant PCT = 1e16;

    function setUp() public {
        list = new RateSortedList(address(this));
    }

    // --- helpers ------------------------------------------------------------------------------------------------------

    /// The queue as redemption walks it: from the tail, lowest (rate, id) first.
    function _queue(RateSortedList l) internal view returns (uint256[] memory q) {
        q = new uint256[](l.size());
        uint256 x = l.last();
        for (uint256 i = 0; i < q.length; i++) {
            q[i] = x;
            x = l.prev(x);
        }
        assertEq(x, 0, "R2: the walk from the tail must end exactly at size()");
    }

    /// Links agree in both directions and every step towards the tail goes strictly down in (rate, id).
    function _assertWellFormed(RateSortedList l) internal view {
        uint256 x = l.first();
        uint256 before;
        uint256 n;
        while (x != 0) {
            assertEq(l.prev(x), before, "R2: prev and next links disagree");
            if (before != 0) {
                uint256 rb = l.rateOf(before);
                uint256 rx = l.rateOf(x);
                assertTrue(rb > rx || (rb == rx && before > x), "R2: the list is not strictly ordered by (rate, id)");
            }
            before = x;
            x = l.next(x);
            n++;
        }
        assertEq(before, l.last(), "R2: the walk from the head does not end at the tail");
        assertEq(n, l.size(), "R2: size() differs from the number of linked Troves");
    }

    // --- the rule -----------------------------------------------------------------------------------------------------

    function test_tiesAreBrokenByTroveId() public {
        // inserted in an order that is neither ascending nor descending, always without hints
        list.insert(7, 2 * PCT, 0, 0);
        list.insert(3, 2 * PCT, 0, 0);
        list.insert(8, 3 * PCT, 0, 0);
        list.insert(9, 2 * PCT, 0, 0);
        list.insert(4, 1 * PCT, 0, 0);
        list.insert(5, 2 * PCT, 0, 0);
        uint256[6] memory want = [uint256(4), 3, 5, 7, 9, 8];
        uint256[] memory q = _queue(list);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(q[i], want[i], "R2: lowest rate first, and the lower id first among equal rates");
        }
        _assertWellFormed(list);
    }

    /// The same Troves as scenario S-31 of the model, with the same expected queues written out by hand.
    function test_aRateChangeDoesNotDecideThePlaceAmongTies() public {
        list.insert(1, 3 * PCT, 0, 0);
        list.insert(2, 1 * PCT, 0, 0);
        list.insert(3, 2 * PCT, 0, 0);
        list.insert(4, 1 * PCT, 0, 0);
        list.insert(5, 1 * PCT, 0, 0);
        uint256[] memory q = _queue(list);
        uint256[5] memory want = [uint256(2), 4, 5, 3, 1];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(q[i], want[i], "R2: order before the rate change");
        }
        list.reinsert(1, 1 * PCT, 0, 0); // moves ONTO an existing rate: it goes by its id, not to the back of the rate
        q = _queue(list);
        want = [uint256(1), 2, 4, 5, 3];
        for (uint256 i = 0; i < 5; i++) {
            assertEq(q[i], want[i], "R2: order after the rate change");
        }
        _assertWellFormed(list);
    }

    // --- rights and preconditions -------------------------------------------------------------------------------------

    function test_onlyTheBranchCanChangeTheList() public {
        list.insert(1, PCT, 0, 0);
        address stranger = address(0xBAD);
        vm.startPrank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        list.insert(2, PCT, 0, 0);
        vm.expectRevert(NotAuthorized.selector);
        list.remove(1);
        vm.expectRevert(NotAuthorized.selector);
        list.reinsert(1, 2 * PCT, 0, 0);
        vm.stopPrank();
        assertEq(list.size(), 1);
        assertEq(list.rateOf(1), PCT);
    }

    function test_constructorRejectsZeroBranch() public {
        vm.expectRevert(RateSortedList.BranchIsZero.selector);
        new RateSortedList(address(0));
    }

    function test_rejectsIdZeroDuplicatesAndAbsentIds() public {
        vm.expectRevert(RateSortedList.IdIsZero.selector);
        list.insert(0, PCT, 0, 0);
        list.insert(1, PCT, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RateSortedList.AlreadyInList.selector, 1));
        list.insert(1, 2 * PCT, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RateSortedList.NotInList.selector, 2));
        list.remove(2);
        vm.expectRevert(abi.encodeWithSelector(RateSortedList.NotInList.selector, 2));
        list.reinsert(2, PCT, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(RateSortedList.NotInList.selector, 0));
        list.remove(0);
        list.remove(1);
        assertEq(list.size(), 0);
        assertEq(list.first(), 0);
        assertEq(list.last(), 0);
        assertFalse(list.contains(1));
    }

    function test_rateAboveUint128Reverts() public {
        uint256 r = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, r));
        list.insert(1, r, 0, 0);
        list.insert(1, type(uint128).max, 0, 0); // the largest storable rate is stored exactly
        assertEq(list.rateOf(1), type(uint128).max);
    }

    // --- hints decide the cost, never the place ----------------------------------------------------------------------

    function _build(RateSortedList l, uint256 n, uint256 seed) internal {
        for (uint256 i = 1; i <= n; i++) {
            uint256 r = (uint256(keccak256(abi.encode(seed, i))) % 4 + 1) * PCT; // four rates: ties everywhere
            l.insert(i, r, 0, 0);
        }
    }

    /// Any pair of hints -- empty, listed but wrong, unlisted, arbitrary -- yields the one position the rule allows.
    function testFuzz_hintsNeverChangeThePosition(uint256 seed, uint256 h1, uint256 h2, uint8 mode, uint8 rateK)
        public
    {
        _build(list, 30, seed);
        uint256 id = 16; // an id in the middle of the listed ones, so ties fall on both sides of it
        list.remove(id);
        uint256 rate = (uint256(rateK) % 5) * PCT; // includes a rate below every listed one
        if (mode % 3 == 1) {
            h1 = bound(h1, 0, 31); // listed ids (and 0, 16, 31: head marker, the removed id, never listed)
            h2 = bound(h2, 0, 31);
        } else if (mode % 3 == 2) {
            (h1, h2) = (h2 % 32, h1); // one listed-or-small, one arbitrary
        }
        (uint256 p0, uint256 q0) = list.findInsertPosition(id, rate, 0, 0);
        (uint256 p, uint256 q) = list.findInsertPosition(id, rate, h1, h2);
        assertEq(p, p0, "R2: a hint changed the position (prev)");
        assertEq(q, q0, "R2: a hint changed the position (next)");
        list.insert(id, rate, h1, h2);
        assertEq(list.prev(id), p0, "R2: inserted away from the position");
        assertEq(list.next(id), q0, "R2: inserted away from the position");
        _assertWellFormed(list);
    }

    /// For a listed Trove the view answers as if it were not there, so its answer is the hint `reinsert` needs.
    function test_findInsertPositionLooksPastTheTroveItself() public {
        _build(list, 12, 7);
        (uint256 p, uint256 q) = (list.prev(6), list.next(6));
        (uint256 p1, uint256 q1) = list.findInsertPosition(6, list.rateOf(6), 0, 0);
        assertEq(p1, p, "at its own rate a listed Trove's position is where it stands");
        assertEq(q1, q, "at its own rate a listed Trove's position is where it stands");
        (p, q) = list.findInsertPosition(6, 9 * PCT, 0, 0); // above every listed rate: the head
        assertEq(p, 0);
        assertTrue(q != 6 && q == (list.first() == 6 ? list.next(6) : list.first()));
        list.reinsert(6, 9 * PCT, p, q);
        assertEq(list.first(), 6);
        _assertWellFormed(list);
    }

    function _insertCost(RateSortedList l, uint256 id, uint256 rate, uint256 p, uint256 q) internal returns (uint256) {
        uint256 g = gasleft();
        l.insert(id, rate, p, q);
        return g - gasleft();
    }

    function _removeCost(RateSortedList l, uint256 id) internal returns (uint256) {
        uint256 g = gasleft();
        l.remove(id);
        return g - gasleft();
    }

    /// With exact hints an insertion does the same work in a list of 8 as in a list of 256: the hints are checked, not
    /// searched for; and a removal never looks at anything but the two neighbours. The costs are compared for equality,
    /// not within a tolerance: both calls go through the same measuring code and execute the same opcodes on storage in
    /// the same warm/cold state, so any difference at all would be a walk (one step of which reads two storage slots).
    function test_exactHintsCostTheSameAtAnySize() public {
        RateSortedList small = new RateSortedList(address(this));
        RateSortedList large = new RateSortedList(address(this));
        for (uint256 i = 1; i <= 256; i++) {
            if (i <= 8) {
                small.insert(i, i * 1e15, 0, i - 1);
            }
            large.insert(i, i * 1e15, 0, i - 1); // each new one ranks ahead of all: exact hints (0, previous head)
        }
        uint256 costSmall = _insertCost(small, 1000, 4 * 1e15 + 1, 5, 4);
        uint256 costLarge = _insertCost(large, 1000, 128 * 1e15 + 1, 129, 128);
        assertEq(costLarge, costSmall, "R2: an exactly hinted insertion walked the list");
        costSmall = _removeCost(small, 3);
        costLarge = _removeCost(large, 200);
        assertEq(costLarge, costSmall, "R2: removal depends on the size of the list");
        _assertWellFormed(small);
        _assertWellFormed(large);
    }

    // --- differential: the model's queue, replayed with good and bad hints -----------------------------------------------

    uint256 stalePrev;
    uint256 staleNext;

    function _hints(uint256 i, uint256 id, uint256 p, uint256 q) internal view returns (uint256, uint256) {
        uint256 k = i % 5;
        if (k == 0) return (p, q); // exact
        if (k == 1) return (0, 0); // none
        if (k == 2) return (q, p); // both listed (when non-zero), both on the wrong side
        if (k == 3) return (stalePrev, staleNext); // the previous operation's hints: stale, possibly removed ids
        return (uint256(keccak256(abi.encode(i))), id / 2 + 1); // arbitrary, and some listed id or other
    }

    struct Vectors {
        uint256[] kind; // 0 insert, 1 remove, 2 reinsert, 3 compare the whole queue
        uint256[] id;
        uint256[] rate;
        uint256[] prv; // the neighbours the model's rule names: exact hints
        uint256[] nxt;
        uint256[] len; // per comparison: the queue length, then that many ids in `order`
        uint256[] order;
    }

    function _load() internal view returns (Vectors memory v) {
        string memory json = vm.readFile("test/vectors/sorted_list.json");
        v.kind = vm.parseJsonUintArray(json, ".ops.kind");
        v.id = vm.parseJsonUintArray(json, ".ops.id");
        v.rate = vm.parseJsonUintArray(json, ".ops.rate");
        v.prv = vm.parseJsonUintArray(json, ".ops.prev");
        v.nxt = vm.parseJsonUintArray(json, ".ops.next");
        v.len = vm.parseJsonUintArray(json, ".checks.len");
        v.order = vm.parseJsonUintArray(json, ".checks.order");
    }

    function _compare(Vectors memory v, uint256 c, uint256 o) internal view {
        assertEq(list.size(), v.len[c], "R2: queue length differs from the model");
        uint256 x = list.last();
        for (uint256 j = 0; j < v.len[c]; j++) {
            assertEq(x, v.order[o + j], "R2: redemption order differs from the model");
            x = list.prev(x);
        }
        assertEq(x, 0, "R2: the list holds a Trove the model's queue does not");
    }

    function _apply(Vectors memory v, uint256 i) internal {
        if (v.kind[i] == 1) {
            list.remove(v.id[i]);
            return;
        }
        // the neighbours the model's rule names are exactly the position the list computes
        (uint256 p, uint256 q) = list.findInsertPosition(v.id[i], v.rate[i], 0, 0);
        assertEq(p, v.prv[i], "R2: position differs from the model (prev)");
        assertEq(q, v.nxt[i], "R2: position differs from the model (next)");
        (uint256 hp, uint256 hq) = _hints(i, v.id[i], p, q);
        if (v.kind[i] == 0) {
            list.insert(v.id[i], v.rate[i], hp, hq);
        } else {
            list.reinsert(v.id[i], v.rate[i], hp, hq);
        }
        (stalePrev, staleNext) = (p, q);
    }

    function test_diff_redemptionOrderMatchesModel() public {
        Vectors memory v = _load();
        assertGt(v.len.length, 300, "too few queues to be a differential test");
        uint256 c;
        uint256 o;
        for (uint256 i = 0; i < v.kind.length; i++) {
            if (v.kind[i] == 3) {
                _compare(v, c, o);
                o += v.len[c];
                c++;
            } else {
                _apply(v, i);
            }
        }
        assertEq(c, v.len.length, "not every recorded queue was compared");
        assertEq(o, v.order.length);
        _assertWellFormed(list);
    }
}
