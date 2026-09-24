// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {BranchSettlement} from "../src/core/BranchSettlement.sol";
import {WAD, L_PRECISION} from "../src/libraries/Constants.sol";
import "../src/Types.sol";

/// SPEC §9 where the model-driven traces cannot reach: the boundaries of the batch and of the write-off delay, a
/// shutdown with no open Trove, the reference price after the market moves, a broken feed after it is fixed, and who
/// may call the branch's settlement hooks. Expected values are computed here from the rules' own formulas.
contract SettlementTest is BranchFixture {
    address alice = account(0);
    address bob = account(1);
    address keeper = account(2);
    address holder = account(3);
    uint256 constant MAX = type(uint256).max;
    uint256 constant GAS = E / 1000;

    function setUp() public {
        deployBranch(2000 * E, 10_000_000 * E, 10_000_000 * E, GAS);
        weth.mint(alice, 10_000 * E);
        weth.mint(bob, 10_000 * E);
    }

    function _open(address who, uint256 coll, uint256 debt) internal returns (uint256) {
        vm.prank(who);
        return manager.openTrove(who, coll, debt, 5 * PCT, 0, MAX, 0, 0);
    }

    function _failOracle() internal {
        feed.set(1, PriceStatus.Failed);
        manager.pokeOracle(); // shutdown; the reference price is the last good one
    }

    function _settle(uint256 id) internal returns (uint256, uint256, uint256) {
        vm.prank(keeper);
        return settlement.settleTrove(id);
    }

    /// The whole supply outside the Stability Pool to `to`: the interfaces' share of an untagged Trove is its owner's.
    function _gatherTo(address to) internal {
        vm.prank(to);
        registry.claim();
        uint256 escrowed = stable.balanceOf(escrow);
        vm.prank(escrow);
        stable.transfer(to, escrowed);
    }

    function _need(uint256 debt, uint256 price) internal pure returns (uint256) {
        return (debt * WAD + price - 1) / price; // rounded up, in favour of the pot
    }

    // --- X1, X2 ----------------------------------------------------------------------------------------------------------

    function test_aTroveHandsThePotItsDebtAtTheReferencePriceAndTheCallerItsDeposit() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _open(bob, 200 * E, 50_000 * E);
        vm.warp(block.timestamp + 10 days);
        _failOracle();
        assertEq(manager.settlePrice(), 2000 * E, "X1: the last good price after an oracle failure");
        uint256 debt = manager.troveDebt(t);
        uint256 coll = manager.troveColl(t);
        vm.warp(block.timestamp + 10 days);
        assertEq(manager.troveDebt(t), debt, "B3: interest stops at shutdown");
        uint256 before = weth.balanceOf(keeper);
        (uint256 d, uint256 contribution, uint256 gross) = _settle(t);
        uint256 need = _need(debt, 2000 * E);
        assertEq(d, debt);
        assertEq(contribution, need, "X2: a healthy Trove hands over its debt's worth, rounded up");
        assertEq(gross, coll - need, "X2: the owner keeps the rest");
        assertEq(manager.ledger().badDebt, debt, "X2: its debt becomes a claim of every holder");
        assertEq(manager.ledger().badDebtColl, need);
        assertEq(settlement.grossOf(alice), coll - need);
        assertEq(weth.balanceOf(keeper) - before, GAS, "X2: the caller receives the Trove's gas deposit");
        assertEq(uint8(manager.getTrove(t).status), uint8(TroveStatus.ClosedBySettlement));
        vm.prank(keeper);
        vm.expectRevert(TroveNotOpen.selector);
        settlement.settleTrove(t);
    }

    function test_theReferencePriceIsFixedOnceAndLaterMovesChangeNothing() public {
        uint256 t = _open(alice, 40 * E, 20_000 * E); // about 160 % at the reference price
        _open(bob, 12 * E, 20_000 * E); // under water there
        uint256 p = 800 * E; // TCR about 104 %: under SCR
        feed.set(p, PriceStatus.Valid);
        manager.triggerShutdown();
        assertEq(manager.settlePrice(), p, "X1: the Valid price at shutdown");
        feed.set(4000 * E, PriceStatus.Valid); // the market recovers
        uint256 debt = manager.troveDebt(t);
        assertLt(_need(debt, p), manager.troveColl(t), "a healthy Trove at the reference price");
        (, uint256 contribution,) = _settle(t);
        assertEq(contribution, _need(debt, p), "X1: later market moves change nothing");
    }

    function test_settlingReadsNoPriceOnceTheReferencePriceIsFixed() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _open(bob, 200 * E, 50_000 * E);
        _failOracle();
        feed.setBroken(true); // any read of the feed would now revert
        _settle(t);
        assertEq(uint8(manager.getTrove(t).status), uint8(TroveStatus.ClosedBySettlement));
    }

    function test_settlementWaitsForTheShutdown() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        vm.prank(keeper);
        vm.expectRevert(BranchNotShutDown.selector);
        settlement.settleTrove(t);
        vm.expectRevert(BranchSettlement.WriteOffTooEarly.selector);
        settlement.writeOff(t);
    }

    // --- X3 --------------------------------------------------------------------------------------------------------------

    function test_aBatchSettlesAtMostFiftyTroves() public {
        uint256[] memory ids = new uint256[](51);
        for (uint256 i = 0; i < 51; i++) {
            ids[i] = _open(i % 2 == 0 ? alice : bob, 10 * E, 2_000 * E);
        }
        _failOracle();
        vm.prank(keeper);
        vm.expectRevert(BranchSettlement.BatchSize.selector);
        settlement.settleTroves(ids);
        vm.prank(keeper);
        vm.expectRevert(BranchSettlement.BatchSize.selector);
        settlement.settleTroves(new uint256[](0));
        uint256[] memory fifty = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            fifty[i] = ids[i];
        }
        uint256 before = weth.balanceOf(keeper);
        vm.prank(keeper);
        settlement.settleTroves(fifty);
        assertEq(manager.unsettled(), 1, "X3: fifty settled in one call");
        assertEq(weth.balanceOf(keeper) - before, 50 * GAS, "X2: one deposit per Trove to the caller");
    }

    // --- X4 --------------------------------------------------------------------------------------------------------------

    function test_nothingIsPaidToAnyHolderWhileATroveIsUnsettled() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _open(bob, 200 * E, 50_000 * E);
        _failOracle();
        _settle(t);
        vm.prank(bob);
        vm.expectRevert(SettlementPhaseOneOpen.selector);
        settlement.redeemBadDebtColl(1_000 * E, 0);
        vm.prank(alice);
        vm.expectRevert(BranchSettlement.SurplusNotReleased.selector);
        settlement.claimSurplus();
        assertFalse(settlement.phaseOneComplete());
    }

    // --- X5 --------------------------------------------------------------------------------------------------------------

    function test_aWriteOffWaitsThirtyDaysAndPaysHalfTheDeposit() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        uint256 other = _open(bob, 200 * E, 50_000 * E);
        _failOracle();
        uint256 at = manager.ledger().shutdownAt;
        vm.warp(at + 30 days - 1);
        vm.prank(keeper);
        vm.expectRevert(BranchSettlement.WriteOffTooEarly.selector);
        settlement.writeOff(t);
        vm.warp(at + 30 days);
        uint256 debt = manager.troveDebt(t);
        uint256 before = weth.balanceOf(keeper);
        vm.prank(keeper);
        settlement.writeOff(t);
        assertEq(weth.balanceOf(keeper) - before, GAS / 2, "X5: half the deposit for the write-off");
        assertEq(manager.unsettled(), 1);
        assertEq(manager.ledger().badDebt, debt, "X5: the debt is a claim at once");
        (uint256 d, uint256 need, bool set) = settlement.writtenOff(t);
        assertTrue(set);
        assertEq(d, debt);
        assertEq(need, _need(debt, 2000 * E));
        vm.prank(keeper);
        vm.expectRevert(BranchSettlement.AlreadyWrittenOff.selector);
        settlement.writeOff(t);
        // settled before phase 1 ends: the write-off is undone, and the rest of the deposit goes to the settler
        before = weth.balanceOf(keeper);
        (uint256 dd, uint256 contribution,) = _settle(t);
        assertEq(dd, debt, "X5: settled as if it had never been written off");
        assertEq(contribution, need);
        assertEq(weth.balanceOf(keeper) - before, GAS - GAS / 2);
        (,, set) = settlement.writtenOff(t);
        assertFalse(set);
        assertEq(settlement.parTotal(), need, "X5: the write-off's par was taken back");
        assertEq(manager.unsettled(), 1, "the other Trove is still unsettled");
        _settle(other);
        assertTrue(settlement.phaseOneComplete());
    }

    // --- X6: a shutdown with nothing to settle ---------------------------------------------------------------------------

    function test_aShutdownWithNoOpenTroveCompletesPhaseOneAtOnce() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _gatherTo(alice); // the upfront fee: the interfaces' share and the escrow's
        vm.prank(alice);
        manager.closeTrove(t);
        assertEq(manager.nOpen(), 0);
        _failOracle();
        assertTrue(settlement.keepFixed(), "X6: nothing to settle, phase 1 is complete at shutdown");
        assertTrue(settlement.phaseOneComplete());
        assertEq(settlement.surplusKeep(), L_PRECISION);
        assertEq(settlement.claimUnits(), manager.ledger().badDebt);
    }

    // --- X6, X11: the healthy owners' surplus absorbs the shortfall, every owner the same fraction -----------------------

    function test_everyOwnerGivesUpTheSameFractionOfHisSurplus() public {
        uint256 a = _open(alice, 60 * E, 20_000 * E); // 300 % at 2,000, about 114 % at the reference price
        uint256 b = _open(bob, 90 * E, 30_000 * E); // likewise
        uint256 w = _open(bob, 112 * E / 10, 10_000 * E); // about 112 %: under water at the reference price
        uint256 p = 380 * E; // TCR about 102 %: under SCR, above 100 %
        feed.set(p, PriceStatus.Valid);
        manager.triggerShutdown();
        uint256 ga;
        uint256 gb;
        uint256 short;
        {
            uint256 da = manager.troveDebt(a);
            uint256 db = manager.troveDebt(b);
            uint256 dw = manager.troveDebt(w);
            ga = manager.troveColl(a) - _need(da, p);
            gb = manager.troveColl(b) - _need(db, p);
            short = _need(dw, p) - manager.troveColl(w);
        }
        _settle(a);
        _settle(b);
        _settle(w);
        uint256 g = ga + gb;
        uint256 keep = (g - short) * L_PRECISION / g;
        assertEq(settlement.take(), short, "X6: the surplus absorbs the whole shortfall when it can");
        assertEq(settlement.surplusKeep(), keep, "X6: keep = (G - take) / G");
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        settlement.claimSurplus();
        assertEq(weth.balanceOf(alice) - before, ga * keep / L_PRECISION, "X11: alice keeps the common fraction");
        before = weth.balanceOf(bob);
        vm.prank(bob);
        settlement.claimSurplus();
        assertEq(weth.balanceOf(bob) - before, gb * keep / L_PRECISION, "X11: bob keeps the same fraction");
        vm.prank(bob);
        assertEq(settlement.claimSurplus(), 0, "X11: nothing is paid twice");
    }

    // --- X8, X10, L5: claims -------------------------------------------------------------------------------------------

    function test_claimsArePaidProRataRoundedDownAndLeaveAtMostAWei() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _failOracle();
        _settle(t);
        // every claim a holder can hold to one holder: the borrower's, the escrow's and the interfaces' share of the
        // upfront fee. The frontend registry keeps the wei it rounded up at deposit (I-17), so one claim unit stays out
        _gatherTo(alice);
        uint256 all = stable.balanceOf(alice);
        vm.prank(alice);
        stable.transfer(holder, all);
        uint256 bad = manager.ledger().badDebt;
        uint256 pot = manager.ledger().badDebtColl;
        assertEq(bad - all, stable.balanceOf(address(registry)), "every other claim is the registry's rounding");
        vm.prank(holder);
        uint256 part = settlement.redeemBadDebtColl(bad / 3, 0);
        assertEq(part, pot * (bad / 3) / bad, "X8: pro rata, rounded down");
        uint256 rest = manager.ledger().badDebtColl;
        uint256 r2 = all - bad / 3;
        uint256 due = rest * r2 / (bad - bad / 3);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CollOutBelowMinimum.selector, due, due + 1));
        settlement.redeemBadDebtColl(r2, due + 1);
        vm.prank(holder);
        assertEq(settlement.redeemBadDebtColl(r2, due), due, "X8: the minimum the caller accepts, inclusive");
        // what remains is the registry's claim to it, plus rounding (X10): each of the two claims, rounded down, left
        // under one wei behind, and `fair` is itself rounded down, so left < fair + 3
        uint256 left = manager.ledger().badDebtColl;
        uint256 fair = pot * (bad - all) / bad;
        assertLe(left, fair + 2, "X10: each earlier claim leaves under one wei behind");
        assertGe(left, fair, "X10: rounding never pays a claimant more than its share");
        vm.prank(holder);
        vm.expectRevert();
        settlement.redeemBadDebtColl(1, 0); // nothing left to burn
    }

    function test_aClaimOnAnEmptyPotRegistersUnitsThatShareTheLateRecovery() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _failOracle();
        vm.warp(block.timestamp + 30 days);
        vm.prank(keeper);
        settlement.writeOff(t); // phase 1 ends with an empty pot
        assertTrue(settlement.phaseOneComplete());
        uint256 units = 5_000 * E;
        vm.prank(alice);
        stable.transfer(holder, units);
        vm.prank(holder);
        assertEq(settlement.repayBadDebt(units), 0, "L5 3: the burn pays nothing now ...");
        assertEq(settlement.unitsOf(holder), units, "X8: ... but registers claim units");
        (uint256 debt, uint256 need,) = settlement.writtenOff(t);
        uint256 coll = manager.troveColl(t);
        _settle(t); // late: all it owes goes to the claim units
        uint256 claimUnits = settlement.claimUnits();
        assertEq(claimUnits, debt);
        uint256 perUnit = need * L_PRECISION / claimUnits;
        assertEq(settlement.latePerUnit(), perUnit, "X7: the late contribution per claim unit");
        uint256 before = weth.balanceOf(holder);
        vm.prank(holder);
        settlement.claimLate();
        assertEq(weth.balanceOf(holder) - before, units * perUnit / L_PRECISION, "X9: the holder's late share");
        assertLt(need, coll, "a healthy Trove: the owner keeps the rest");
    }

    // --- L3: the liquidation surplus does not wait for phase 1 -------------------------------------------------------------

    function test_theLiquidationSurplusIsClaimableDuringPhaseOne() public {
        uint256 t1 = _open(alice, 20 * E, 20_000 * E);
        uint256 t2 = _open(alice, 40 * E, 20_000 * E);
        _open(bob, 400 * E, 60_000 * E);
        vm.prank(bob);
        sp.deposit(30_000 * E);
        uint256 d1 = manager.troveDebt(t1);
        uint256 c1 = manager.troveColl(t1);
        uint256 price = 108 * PCT * d1 / c1;
        feed.set(price, PriceStatus.Valid);
        vm.prank(keeper);
        manager.liquidate(t1);
        uint256 expected = c1 - c1 * PCT / 2 / E - d1 * (WAD + 5 * PCT) / price;
        _failOracle();
        _settle(t2); // alice now has settlement surplus too, and bob's Trove is unsettled
        vm.prank(alice);
        vm.expectRevert(BranchSettlement.SurplusNotReleased.selector);
        settlement.claimSurplus();
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        manager.claimSurplus();
        assertEq(weth.balanceOf(alice) - before, expected, "L3: the liquidation surplus is claimable during phase 1");
    }

    // --- SPEC 10.5: the settlement hooks ------------------------------------------------------------------------------------

    function test_onlyTheSettlementMovesTheBranchAfterAShutdown() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _failOracle();
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        manager.fixSettlePrice();
        vm.expectRevert(NotAuthorized.selector);
        manager.settleOut(t, alice, true);
        vm.expectRevert(NotAuthorized.selector);
        manager.writeOffOut(t, alice);
        vm.expectRevert(NotAuthorized.selector);
        manager.undoWriteOff(t, 1);
        vm.expectRevert(NotAuthorized.selector);
        manager.addToPot(1);
        vm.expectRevert(NotAuthorized.selector);
        manager.burnClaim(alice, 1, 0);
        vm.expectRevert(NotAuthorized.selector);
        manager.settlementCollOut(alice, 1);
        vm.expectRevert(NotAuthorized.selector);
        settlement.onShutdownWithNoTroves();
        vm.stopPrank();
    }
}
