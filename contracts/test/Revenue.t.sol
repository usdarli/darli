// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DarliToken} from "../src/revenue/DarliToken.sol";
import {DarliStaking} from "../src/revenue/DarliStaking.sol";
import {RevenueRouter} from "../src/revenue/RevenueRouter.sol";
import {InterestEscrow} from "../src/core/InterestEscrow.sol";
import {IInterestEscrow, IDarliStaking} from "../src/interfaces/ICore.sol";
import {NotAuthorized, ZeroAmount} from "../src/Types.sol";
import {MockCollateral} from "./mocks/BranchMocks.sol";

/// SPEC V3-V5 at their boundaries, with expected values from the rules: what is handed over in one epoch is streamed over
/// the next and only then, nothing handed over later moves it, time with no stake rolls forward, and leaving never costs
/// what was earned. The model-driven trace (DarliStaking.trace.t.sol) shows the arithmetic step by step.
contract RevenueTest is Test {
    uint256 constant E = 1e18;
    uint256 constant WEEK = 7 days;
    // SPEC V5: what a staker can claim falls short of what was handed over by rounding dust under 1e-6 token per epoch
    uint256 constant DUST = 1e12;

    MockCollateral stable;
    DarliToken darli;
    InterestEscrow escrow;
    DarliStaking staking;
    RevenueRouter router;
    address alice = address(0x2000);
    address bob = address(0x2001);
    address anyone = address(0x2002);
    uint256 start;

    function setUp() public {
        vm.warp(1_700_000_000);
        start = block.timestamp;
        stable = new MockCollateral();
        darli = new DarliToken(address(this), 1_000_000 * E);
        uint256 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 2);
        escrow = new InterestEscrow(stable, predicted);
        staking = new DarliStaking(darli, stable, predicted);
        router = new RevenueRouter(stable, IInterestEscrow(address(escrow)), IDarliStaking(address(staking)));
        assertEq(address(router), predicted);
        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            darli.transfer(who, 10_000 * E);
            vm.prank(who);
            darli.approve(address(staking), type(uint256).max);
        }
    }

    function _handOver(uint256 amount) internal {
        stable.mint(address(escrow), amount);
        vm.prank(anyone);
        router.routeRevenue();
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        staking.stake(amount);
    }

    // --- V3 --------------------------------------------------------------------------------------------------------------

    function test_anyoneRoutesTheEscrowToTheFixedStakingContract() public {
        vm.prank(anyone);
        assertEq(router.routeRevenue(), 0, "an empty escrow routes nothing");
        stable.mint(address(escrow), 123 * E);
        vm.prank(anyone);
        assertEq(router.routeRevenue(), 123 * E, "V3: the whole balance, by anyone");
        assertEq(stable.balanceOf(address(escrow)), 0);
        assertEq(stable.balanceOf(address(staking)), 123 * E, "V3: to the staking contract fixed at construction");
        assertEq(address(router.staking()), address(staking));
    }

    function test_onlyTheRouterPullsTheEscrowAndHandsOver() public {
        stable.mint(address(escrow), 10 * E);
        vm.prank(anyone);
        vm.expectRevert(NotAuthorized.selector);
        escrow.pull(1);
        vm.prank(anyone);
        vm.expectRevert(NotAuthorized.selector);
        staking.notifyReward(1);
    }

    // --- V4, V5 ----------------------------------------------------------------------------------------------------------

    function test_aHandOverIsStreamedOverTheNextEpochAndOnlyThen() public {
        _stake(alice, 1_000 * E);
        vm.warp(start + 1 days);
        _handOver(7_000 * E);
        vm.warp(start + WEEK); // the end of the epoch it was handed over in
        assertEq(staking.earnedOf(alice), 0, "V4: nothing streams in the epoch of the hand-over");
        vm.warp(start + WEEK + WEEK / 2);
        uint256 half = staking.earnedOf(alice);
        assertLe(half, 3_500 * E, "V4: half the next epoch streams half");
        assertGe(half + DUST, 3_500 * E, "V5: short by dust only");
        vm.warp(start + 2 * WEEK);
        uint256 all = staking.earnedOf(alice);
        vm.warp(start + 5 * WEEK);
        assertEq(staking.earnedOf(alice), all, "V4: the stream ends with the next epoch");
        assertLe(all, 7_000 * E);
        assertGe(all + DUST, 7_000 * E, "V5: short by dust only");
    }

    function test_aLaterHandOverNeverPostponesAnEarlierOne() public {
        _stake(alice, 1_000 * E);
        _handOver(7_000 * E);
        uint256 t = block.timestamp;
        for (uint256 h = 0; h < 2 * 7 * 24; h++) {
            // one wei every hour for two weeks: under a re-spreading stream the end date would keep moving away
            vm.warp(block.timestamp + 1 hours);
            _handOver(1);
        }
        assertLe(block.timestamp - t, 2 * WEEK);
        vm.prank(alice);
        uint256 got = staking.claim();
        assertGe(got + DUST, 7_000 * E, "V4: paid in full within two periods, whatever is handed over after it");
    }

    function test_timeWithNoStakeRollsIntoTheNextEpoch() public {
        _handOver(7_000 * E); // epoch 0: queued
        vm.warp(start + 2 * WEEK); // epoch 1 streams it with nobody staked
        _stake(alice, 1_000 * E);
        assertEq(staking.earnedOf(alice), 0);
        vm.warp(start + 3 * WEEK); // epoch 2 streams what nobody received in epoch 1
        uint256 got = staking.earnedOf(alice);
        assertLe(got, 7_000 * E);
        assertGe(got + DUST, 7_000 * E, "V4: what streamed to nobody is paid in the next epoch");
    }

    function test_stakersShareProRataAndLeavingKeepsWhatWasEarned() public {
        _stake(alice, 1_000 * E);
        _stake(bob, 3_000 * E);
        _handOver(4_000 * E);
        vm.warp(start + WEEK + WEEK / 2);
        vm.prank(bob);
        staking.unstake(3_000 * E); // bob leaves halfway through the paying epoch
        assertEq(darli.balanceOf(bob), 10_000 * E, "V4: unstaking returns the DARLI");
        vm.warp(start + 3 * WEEK);
        uint256 a = staking.earnedOf(alice);
        uint256 b = staking.earnedOf(bob);
        // bob: 3/4 of the first half; alice: 1/4 of the first half and all of the second
        assertApproxEqAbs(b, 1_500 * E, DUST, "V4: pro rata to stake, for the time staked");
        assertApproxEqAbs(a, 2_500 * E, DUST, "V4: pro rata to stake, for the time staked");
        vm.prank(bob);
        assertEq(staking.claim(), b, "V4: earned rewards stay claimable after unstaking");
    }

    /// Once the stream has nothing left to pay, time is skipped in one step: ten years with nothing to stream cost a
    /// staker what one week does. Without the skip the stream walks one turn per week elapsed, 520 of them here.
    function test_anEmptyStreamSkipsIdleTimeInOneStep() public {
        _stake(alice, 1 * E);
        vm.warp(block.timestamp + WEEK);
        uint256 g = gasleft();
        _stake(alice, 1 * E);
        uint256 oneWeek = g - gasleft();
        vm.warp(block.timestamp + 520 * WEEK);
        g = gasleft();
        _stake(alice, 1 * E);
        uint256 tenYears = g - gasleft();
        // the two calls differ only in the time elapsed; 2,000 gas covers warm/cold storage differences and is far
        // below the 520 loop turns the skip avoids (each several hundred gas)
        assertLe(tenYears, oneWeek + 2_000, "V4: an empty stream must not walk the idle weeks one by one");
    }

    function test_stakeBoundsAndTheFixedSupply() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        staking.stake(0);
        _stake(alice, 10 * E);
        vm.prank(alice);
        vm.expectRevert(DarliStaking.UnstakeExceedsStake.selector);
        staking.unstake(10 * E + 1);
        assertEq(darli.totalSupply(), 1_000_000 * E, "V4: the supply minted at construction is all there is");
        vm.expectRevert(DarliToken.NothingToMint.selector);
        new DarliToken(alice, 0);
    }
}
