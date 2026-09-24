// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {CollateralRegistry} from "../src/core/CollateralRegistry.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {IBranchRedemption} from "../src/interfaces/IBranchManager.sol";
import {FixedPointMath} from "../src/libraries/FixedPointMath.sol";
import {
    WAD,
    REDEMPTION_FEE_FLOOR,
    MINUTE_DECAY_FACTOR_6H,
    MAX_BRANCHES_PER_SYSTEM
} from "../src/libraries/Constants.sol";
import "../src/Types.sol";

/// SPEC §5 where the model-driven trace cannot reach: a second price, a Trove under 100 %, a branch under SCR, the
/// boundaries of the fee, and who may call what. Expected values are computed here from the rule's own formula.
contract RedemptionTest is BranchFixture {
    address alice = account(0);
    address bob = account(1);
    address carol = account(2);
    uint256 constant MAX = type(uint256).max;

    function setUp() public {
        deployBranch(2000 * E, 10_000_000 * E, 10_000_000 * E, E / 1000);
        for (uint256 i = 0; i < 3; i++) {
            weth.mint(account(i), 1000 * E);
        }
    }

    function _open(address who, uint256 coll, uint256 debt, uint256 rate) internal returns (uint256) {
        vm.prank(who);
        return manager.openTrove(who, coll, debt, rate, 0, MAX, 0, 0);
    }

    function _redeem(address who, uint256 amount, uint256 maxIterations) internal returns (uint256) {
        vm.prank(who);
        return collRegistry.redeem(amount, maxIterations, WAD);
    }

    function _give(address from, address to, uint256 amount) internal {
        vm.prank(from);
        stable.transfer(to, amount);
    }

    /// The fee rate of R5, written out: min(WAD, floor + min(WAD, decayed + amount * WAD^2 / (supply * beta))).
    function _expectedFeeRate(uint256 amount) internal view returns (uint256) {
        uint256 minutes_ = (block.timestamp - collRegistry.lastFeeOperationTime()) / 60;
        uint256 decayed = collRegistry.baseRate() * FixedPointMath.decPow(MINUTE_DECAY_FACTOR_6H, minutes_) / WAD;
        uint256 bumped = decayed + amount * WAD * WAD / (stable.totalSupply() * BETA_WAD);
        if (bumped > WAD) bumped = WAD;
        uint256 rate = REDEMPTION_FEE_FLOOR + bumped;
        return rate > WAD ? WAD : rate;
    }

    // --- B4 and R2: a Zombie that borrows back is in the queue again ------------------------------------------------------

    function test_zombieBorrowingBackThroughAdjustRejoinsTheQueue() public {
        uint256 low = _open(alice, 20 * E, 10_000 * E, 1 * PCT);
        uint256 high = _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        vm.warp(block.timestamp + 30 days);
        uint256 debt = manager.troveDebt(low);
        _give(bob, carol, debt + 5_000 * E);
        _redeem(carol, debt, 1);
        assertEq(manager.troveDebt(low), 0, "the head is redeemed to exactly zero");
        assertEq(uint8(manager.getTrove(low).status), uint8(TroveStatus.Zombie));
        assertEq(manager.lastZombieTroveId(), 0, "R2: a Zombie at zero debt is not the tracked one");
        assertFalse(list.contains(low));
        vm.prank(alice);
        manager.adjustTrove(low, 0, int256(15_000 * E), MAX); // back above the minimum through adjustTrove
        assertEq(uint8(manager.getTrove(low).status), uint8(TroveStatus.Active), "B4: the Trove is Active again");
        assertTrue(list.contains(low), "B4: ... and back in the redemption queue");
        assertEq(list.last(), low, "R2: at the lowest rate it is the head of the queue");
        uint256 lowBefore = manager.troveDebt(low);
        uint256 highBefore = manager.troveDebt(high);
        _redeem(carol, 2_000 * E, 1);
        assertEq(lowBefore - manager.troveDebt(low), 2_000 * E, "R2: the lowest rate is redeemed first");
        assertEq(manager.troveDebt(high), highBefore, "R2: the 5 % Trove is untouched");
    }

    // --- R2: the tracked Zombie ------------------------------------------------------------------------------------------

    function test_aZombieLeftWithDebtIsRedeemedFirstAndForgottenAtZero() public {
        uint256 low = _open(alice, 20 * E, 10_000 * E, 1 * PCT);
        uint256 high = _open(bob, 200 * E, 50_000 * E, 0.5e16); // a LOWER rate than `low`, opened later
        uint256 highDebt = manager.troveDebt(high);
        _give(bob, carol, 50_000 * E);
        _give(alice, carol, 10_000 * E);
        _redeem(carol, highDebt - 1_000 * E, 1); // leaves 1,000: under the minimum, not zero
        assertEq(uint8(manager.getTrove(high).status), uint8(TroveStatus.Zombie));
        assertEq(manager.lastZombieTroveId(), high, "R2: the Zombie with debt left is tracked");
        assertEq(list.last(), low, "R2: it has left the queue");
        uint256 lowBefore = manager.troveDebt(low);
        _redeem(carol, 400 * E, 5);
        assertEq(manager.troveDebt(high), 600 * E, "R2: the tracked Zombie is redeemed first");
        assertEq(manager.troveDebt(low), lowBefore);
        _redeem(carol, 1_000 * E, 5); // 600 from the Zombie, which reaches zero, then 400 from the queue
        assertEq(manager.troveDebt(high), 0);
        assertEq(manager.lastZombieTroveId(), 0, "R2: a Zombie redeemed to zero is no longer tracked");
        assertEq(lowBefore - manager.troveDebt(low), 400 * E, "R2: the rest comes from the head of the queue");
    }

    // --- R4: a Trove under 100 % is skipped, and counts as an iteration ----------------------------------------------------

    function test_aTroveUnder100PercentIsSkippedButCountsAsAnIteration() public {
        uint256 strong = _open(bob, 500 * E, 50_000 * E, 5 * PCT);
        uint256 weak = _open(alice, 12 * E, 20_000 * E, 1 * PCT); // ICR about 120 %, head of the queue
        _give(bob, carol, 5_000 * E);
        feed.set(1650 * E, PriceStatus.Valid); // the weak Trove at about 99 %; the branch far above SCR
        assertLt(manager.troveColl(weak) * 1650 * E / manager.troveDebt(weak), WAD);
        uint256 weakDebt = manager.troveDebt(weak);
        uint256 strongDebt = manager.troveDebt(strong);
        uint256 balance = stable.balanceOf(carol);
        assertEq(_redeem(carol, 1_000 * E, 1), 0, "R4: the only iteration allowed went to the skipped Trove");
        assertEq(stable.balanceOf(carol), balance, "nothing redeemed, nothing burned");
        assertEq(manager.troveDebt(weak), weakDebt, "R4: a Trove under 100 % is never redeemed");
        assertEq(_redeem(carol, 1_000 * E, 2), 1_000 * E);
        assertEq(manager.troveDebt(weak), weakDebt, "R4: a Trove under 100 % is never redeemed");
        assertEq(strongDebt - manager.troveDebt(strong), 1_000 * E, "R2: the next Trove in the queue is");
    }

    // --- R4 and R7: the redemption price converts, the fee stays in the Trove ------------------------------------------------

    function test_debtIsConvertedAtTheRedemptionPriceAndTheFeeStaysInTheTrove() public {
        uint256 t = _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        _open(alice, 200 * E, 20_000 * E, 6 * PCT);
        _give(bob, carol, 10_000 * E);
        vm.warp(block.timestamp + 1 days);
        feed.setRedemptionPrice(2100 * E); // above the price of 2,000: redemption dearer for the redeemer
        uint256 r = 3_000 * E;
        uint256 rate = _expectedFeeRate(r);
        uint256 out = r * WAD / (2100 * E);
        uint256 toRedeemer = out - out * rate / WAD;
        uint256 coll = manager.troveColl(t);
        uint256 before = weth.balanceOf(carol);
        _redeem(carol, r, 1);
        assertEq(weth.balanceOf(carol) - before, toRedeemer, "R4: debt is converted at the redemption price");
        assertEq(coll - manager.troveColl(t), toRedeemer, "R7: the fee stays in the Trove as collateral");
    }

    function test_aRedemptionPriceBelowThePriceIsRaisedToIt() public {
        _open(bob, 400 * E, 50_000 * E, 5 * PCT);
        uint256 t = _open(alice, 12 * E, 20_000 * E, 1 * PCT); // the head of the queue, about 120 %
        _give(bob, carol, 30_000 * E);
        feed.set(1760 * E, PriceStatus.Valid); // the head at about 105 %
        feed.setRedemptionPrice(1600 * E); // ... and under 100 % at the feed's redemption price
        uint256 d = manager.troveDebt(t);
        uint256 c = manager.troveColl(t);
        assertLt(c * 1600 * E / d, WAD, "the head is under 100 % at the feed's redemption price");
        uint256 rate = _expectedFeeRate(d);
        uint256 out = d * WAD / (1760 * E);
        uint256 toRedeemer = out - out * rate / WAD;
        uint256 before = weth.balanceOf(carol);
        _redeem(carol, d, 1); // at 1,600 the Trove would owe more collateral than it holds, and the redemption revert
        assertEq(weth.balanceOf(carol) - before, toRedeemer, "R4: converted at the price, not below it");
        assertEq(manager.troveColl(t), c - toRedeemer, "R4: the Trove keeps what the conversion at the price leaves");
        assertEq(manager.troveDebt(t), 0);
    }

    /// I-8: taking R of debt and R / max(price, redemptionPrice), less the fee, of collateral from a Trove at or above
    /// 100 % at `price` never lowers its ICR, whichever side of the price the feed's redemption price is on. Checked by
    /// cross-multiplication, as in the model.
    function testFuzz_aRedemptionNeverLowersTheIcrOfATroveAt100PercentOrMore(
        uint256 amount,
        uint256 price,
        uint256 redemptionPrice
    ) public {
        _open(bob, 500 * E, 50_000 * E, 5 * PCT);
        uint256 t = _open(alice, 12 * E, 20_000 * E, 1 * PCT); // the head of the queue, ICR about 120 %
        _give(bob, carol, 30_000 * E);
        uint256 d0 = manager.troveDebt(t);
        uint256 c0 = manager.troveColl(t);
        price = bound(price, (d0 * WAD + c0 - 1) / c0, 3000 * E); // from exactly 100 % upwards
        feed.set(price, PriceStatus.Valid);
        feed.setRedemptionPrice(bound(redemptionPrice, price / 2, price * 2));
        amount = bound(amount, 1, 30_000 * E);
        _redeem(carol, amount, 1);
        assertGe(manager.troveColl(t) * d0, c0 * manager.troveDebt(t), "I-8: a redemption lowered the ICR");
    }

    // --- SPEC 10.5: the request, not what the routing makes of it, is bounded by the balance --------------------------

    function test_aRequestAboveTheBalanceIsRefusedEvenWhenLessWouldBeRedeemed() public {
        _open(alice, 20 * E, 10_000 * E, 1 * PCT);
        _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        _give(bob, carol, 20_000 * E);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralRegistry.RequestAboveBalance.selector, 20_000 * E + 1, 20_000 * E)
        );
        collRegistry.redeem(20_000 * E + 1, 1, WAD); // one iteration reaches only the ~10,000 of the head
        assertGt(_redeem(carol, 20_000 * E, 1), 0, "exactly the balance is allowed");
    }

    // --- R1: which branches are redeemable ---------------------------------------------------------------------------------

    function test_onlyALiveBranchWithAValidPriceAtOrAboveScrIsRedeemed() public {
        _open(alice, 20 * E, 20_000 * E, 1 * PCT);
        _open(bob, 20 * E, 20_000 * E, 5 * PCT);
        _give(bob, carol, 10_000 * E);
        feed.set(2000 * E, PriceStatus.PriceInvalid);
        vm.prank(carol);
        vm.expectRevert(CollateralRegistry.NoRedeemableBranch.selector);
        collRegistry.redeem(1_000 * E, 5, WAD);
        // TCR exactly at SCR is redeemable, one wei of price lower is not
        uint256 d = manager.ledger().aggDebt + manager.pendingAggInterest();
        uint256 c = manager.activeColl() + manager.defaultColl();
        uint256 atScr = (110 * PCT * d + c - 1) / c;
        feed.set(atScr - 1, PriceStatus.Valid);
        assertFalse(manager.redemptionState().redeemable, "R1: under SCR the branch is not redeemable");
        vm.prank(carol);
        vm.expectRevert(CollateralRegistry.NoRedeemableBranch.selector);
        collRegistry.redeem(1_000 * E, 5, WAD);
        feed.set(atScr, PriceStatus.Valid);
        assertEq(_redeem(carol, 1_000 * E, 5), 1_000 * E, "R1: at SCR the branch is redeemable");
        // after a shutdown: settlement, not redemption
        feed.set(1, PriceStatus.Failed);
        manager.pokeOracle();
        feed.set(2000 * E, PriceStatus.Valid);
        assertFalse(manager.redemptionState().redeemable, "R1: a shut-down branch is not redeemable");
        vm.prank(carol);
        vm.expectRevert(CollateralRegistry.NoRedeemableBranch.selector);
        collRegistry.redeem(1_000 * E, 5, WAD);
    }

    // --- R5, R6: the fee ---------------------------------------------------------------------------------------------------

    function test_theFeeFollowsItsFormulaFromTheInitialBaseRateAndIsCapped() public {
        assertEq(collRegistry.baseRate(), INITIAL_BASE_RATE, "R6: the base rate starts at its deployment value");
        assertEq(collRegistry.lastFeeOperationTime(), START);
        _open(alice, 200 * E, 20_000 * E, 1 * PCT);
        _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        uint256 supply = stable.totalSupply();
        assertEq(collRegistry.redemptionFeeRate(1_000 * E), _expectedFeeRate(1_000 * E), "R5: the fee rate");
        assertEq(
            collRegistry.redemptionFeeRate(1_000 * E),
            REDEMPTION_FEE_FLOOR + INITIAL_BASE_RATE + 1_000 * E * WAD * WAD / (supply * BETA_WAD),
            "R5: floor + base rate + amount / (supply * beta), no time elapsed"
        );
        assertEq(collRegistry.redemptionFeeRate(supply * 4), WAD, "R5: the fee is capped at 100 %");
        // the caller's bound: exactly the fee passes, one wei under it does not
        _give(bob, carol, 20_000 * E);
        uint256 fee = collRegistry.redemptionFeeRate(5_000 * E);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(CollateralRegistry.FeeRateAboveMax.selector, fee, fee - 1));
        collRegistry.redeem(5_000 * E, 5, fee - 1);
        vm.prank(carol);
        collRegistry.redeem(5_000 * E, 5, fee);
        assertEq(
            collRegistry.baseRate(),
            INITIAL_BASE_RATE + 5_000 * E * WAD * WAD / (supply * BETA_WAD),
            "R5: the stored base rate rises by what was redeemed, over the supply before it"
        );
    }

    function test_theBaseRateFollowsWhatWasRedeemedNotWhatWasAsked() public {
        uint256 low = _open(alice, 20 * E, 10_000 * E, 1 * PCT);
        _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        _give(bob, carol, 40_000 * E);
        uint256 supply = stable.totalSupply();
        uint256 headDebt = manager.troveDebt(low);
        uint256 redeemed = _redeem(carol, 40_000 * E, 1); // asks for 40,000; one iteration reaches the head only
        assertEq(redeemed, headDebt);
        assertEq(
            collRegistry.baseRate(),
            INITIAL_BASE_RATE + headDebt * WAD * WAD / (supply * BETA_WAD),
            "R5: the stored base rate follows the amount actually redeemed (M-6)"
        );
    }

    function test_theBaseRateDecaysWithASixHourHalfLifeCountedInWholeMinutes() public {
        _open(alice, 200 * E, 20_000 * E, 1 * PCT);
        _open(bob, 200 * E, 50_000 * E, 5 * PCT);
        _give(bob, carol, 20_000 * E);
        vm.warp(START + 59);
        _redeem(carol, 100 * E, 5);
        assertEq(collRegistry.lastFeeOperationTime(), START, "R5: under a minute, the fee clock does not move");
        vm.warp(START + 60);
        uint256 stored = collRegistry.baseRate();
        _redeem(carol, 100 * E, 5);
        assertEq(collRegistry.lastFeeOperationTime(), START + 60, "R5: after a whole minute it does");
        stored = collRegistry.baseRate();
        vm.warp(START + 60 + 6 hours);
        uint256 decayed = stored * FixedPointMath.decPow(MINUTE_DECAY_FACTOR_6H, 360) / WAD;
        assertEq(collRegistry.redemptionFeeRate(0), REDEMPTION_FEE_FLOOR + decayed, "R5: decay over 360 minutes");
        // Half, to within rounding: flooring 0.5^(1/360) to 18 digits loses under 1e-18 absolute, so under 1.01e-18
        // relative per factor and under 3.7e-16 over 360 of them; decPow's at most 18 half-up multiplications add under
        // 1e-18 relative each on values of at least 0.5; the final floor adds under 1e-17 on a base rate above 1e17.
        // The total is under 4.2e-16, inside the 1e-14 (1e4 of assertApproxEqRel's 1e18) allowed here.
        assertApproxEqRel(decayed * 2, stored, 1e4, "R5: six hours halve the base rate");
    }

    // --- SPEC 10.5: wiring ---------------------------------------------------------------------------------------------------

    function test_onlyTheRegistryRedeemsFromTheBranch() public {
        _open(alice, 20 * E, 10_000 * E, 1 * PCT);
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        manager.redeemFromBranch(alice, 1_000 * E, 2000 * E, 2000 * E, 0, 10);
    }

    function test_registryConstructionRefusesInconsistentParameters() public {
        IBranchRedemption[] memory none = new IBranchRedemption[](0);
        IBranchRedemption[] memory one = new IBranchRedemption[](1);
        one[0] = IBranchRedemption(address(manager));
        IBranchRedemption[] memory tooMany = new IBranchRedemption[](MAX_BRANCHES_PER_SYSTEM + 1);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = IBranchRedemption(address(manager));
        }
        IStableToken s = IStableToken(address(stable));
        vm.expectRevert(CollateralRegistry.InvalidConfig.selector);
        new CollateralRegistry(s, none, BETA_WAD, 0);
        vm.expectRevert(CollateralRegistry.InvalidConfig.selector);
        new CollateralRegistry(s, tooMany, BETA_WAD, 0);
        vm.expectRevert(CollateralRegistry.InvalidConfig.selector);
        new CollateralRegistry(s, one, 0, 0); // beta = 0 would divide by zero in every fee
        vm.expectRevert(CollateralRegistry.InvalidConfig.selector);
        new CollateralRegistry(s, one, BETA_WAD, WAD + 1);
        new CollateralRegistry(s, one, BETA_WAD, WAD);
    }
}
