// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {MIN_SP_RESIDUAL} from "../src/libraries/Constants.sol";
import "../src/Types.sol";

/// SPEC §6: what the model-driven trace cannot pin down on its own. Expected values are computed here from the rule's
/// own formula and the Trove's numbers, not read back from the contract.
contract LiquidationTest is BranchFixture {
    address alice = account(0);
    address bob = account(1);
    address keeper = account(2);
    uint256 constant MAX = type(uint256).max;
    uint256 constant GAS = E / 1000;

    function setUp() public {
        deployBranch(2000 * E, 10_000_000 * E, 10_000_000 * E, GAS);
        weth.mint(alice, 2000 * E);
        weth.mint(bob, 2000 * E);
    }

    function _open(address who, uint256 coll, uint256 debt) internal returns (uint256) {
        vm.prank(who);
        return manager.openTrove(who, coll, debt, 5 * PCT, 0, MAX, 0, 0);
    }

    function _priceForIcr(uint256 id, uint256 icrPct) internal view returns (uint256) {
        return icrPct * PCT * manager.troveDebt(id) / manager.troveColl(id);
    }

    function _fundPool(address who, uint256 amount) internal {
        vm.prank(who);
        sp.deposit(amount);
    }

    // --- L1 ---------------------------------------------------------------------------------------------------------

    function test_onlyATroveBelowMcrWithAValidPriceOnALiveBranchIsLiquidated() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E); // ICR 200 %
        _open(bob, 200 * E, 20_000 * E);
        vm.prank(keeper);
        vm.expectRevert(TroveNotLiquidatable.selector);
        manager.liquidate(t);
        // the lowest price at which the Trove is still at MCR (rounded up): not below it, so not liquidatable
        uint256 atMcr = (110 * PCT * manager.troveDebt(t) + manager.troveColl(t) - 1) / manager.troveColl(t);
        feed.set(atMcr, PriceStatus.Valid);
        vm.prank(keeper);
        vm.expectRevert(TroveNotLiquidatable.selector);
        manager.liquidate(t);
        feed.set(atMcr - 1, PriceStatus.Valid); // one wei of price lower, and it is
        vm.prank(keeper);
        manager.liquidate(t);
        t = _open(alice, 20 * E, 20_000 * E);
        feed.set(_priceForIcr(t, 105), PriceStatus.PriceInvalid);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PriceNotValid.selector, PriceStatus.PriceInvalid));
        manager.liquidate(t);
        feed.set(_priceForIcr(t, 105), PriceStatus.Valid);
        vm.prank(keeper);
        manager.liquidate(t);
        assertEq(uint8(manager.getTrove(t).status), uint8(TroveStatus.ClosedByLiquidation));
        vm.prank(keeper);
        vm.expectRevert(TroveNotOpen.selector);
        manager.liquidate(t);
        // after a shutdown Troves are settled, not liquidated
        feed.set(1, PriceStatus.Failed);
        manager.pokeOracle();
        vm.prank(keeper);
        vm.expectRevert(BranchShutDown.selector);
        manager.liquidate(2);
    }

    // --- L3: the liquidator's pay ----------------------------------------------------------------------------------------

    function test_liquidatorReceivesTheCappedBonusAndTheGasDeposit() public {
        uint256 t = _open(alice, 1000 * E, 1_000_000 * E); // 0.5 % of 1000 ETH is 5 ETH: the 2 ETH cap applies
        _open(bob, 1000 * E, 100_000 * E);
        feed.set(_priceForIcr(t, 105), PriceStatus.Valid);
        uint256 before = weth.balanceOf(keeper);
        vm.prank(keeper);
        LiquidationValues memory v = manager.liquidate(t);
        assertEq(v.liquidatorBonus, 2 * E, "L3: the liquidator's share is capped at 2 ETH");
        assertEq(weth.balanceOf(keeper) - before, 2 * E + GAS, "L3: the liquidator receives the bonus and the deposit");
        assertEq(manager.gasLeft(t), 0);
    }

    // --- L2: the waterfall -----------------------------------------------------------------------------------------------

    function test_theLastTroveWithAnEmptyPoolBecomesBadDebtAndShutsTheBranch() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        uint256 debt = manager.troveDebt(t);
        feed.set(_priceForIcr(t, 105), PriceStatus.Valid);
        vm.prank(keeper);
        LiquidationValues memory v = manager.liquidate(t);
        assertTrue(v.becameBadDebt, "L2: with no pool and no other Trove the remainder is bad debt");
        assertEq(v.debtOffset, 0);
        assertEq(v.debtRemainder, debt);
        BranchLedger memory l = manager.ledger();
        assertEq(l.badDebt, debt, "L2: the whole debt is recorded as bad debt");
        assertEq(l.badDebtColl, v.collRemainder, "L2: its collateral goes with it");
        assertTrue(l.shutdownAt != 0, "L2 / L6: recorded bad debt shuts the branch down");
    }

    function test_poolAbsorbsFirstAndTheRestIsRedistributed() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        uint256 other = _open(bob, 400 * E, 50_000 * E);
        _fundPool(bob, 5_000 * E);
        uint256 debt = manager.troveDebt(t);
        uint256 coll = manager.troveColl(t);
        uint256 price = _priceForIcr(t, 107);
        feed.set(price, PriceStatus.Valid);
        uint256 otherDebt = manager.troveDebt(other);
        vm.prank(keeper);
        LiquidationValues memory v = manager.liquidate(t);
        uint256 bonus = coll * PCT / 2 / E;
        uint256 x = 5_000 * E - MIN_SP_RESIDUAL; // the pool absorbs all it can above its residual
        assertEq(v.debtOffset, x, "L2: the pool absorbs what it has above MIN_SP_RESIDUAL");
        assertEq(v.collToSP, x * 105 * PCT / price, "L2: the pool's collateral carries the 5 % premium");
        assertEq(v.debtRemainder, debt - x);
        uint256 collY = (debt - x) * 110 * PCT / price;
        uint256 left = coll - bonus - v.collToSP;
        assertEq(v.collRemainder, collY < left ? collY : left, "L2: redistribution carries at most the 10 % premium");
        assertEq(sp.totalDeposits(), MIN_SP_RESIDUAL);
        // The other Trove now carries the redistributed debt. Its stake S is the whole stake, so it receives
        // floor(S * floor(Y * 1e36 / S) / 1e36) of the remainder Y (the carried error starts at zero). Since
        // floor(Y * 1e36 / S) * S > Y * 1e36 - S and S < 1e36, that is more than Y - 1: at most one wei short, never over.
        uint256 gained = manager.troveDebt(other) - otherDebt;
        assertLe(gained, debt - x, "L4: redistribution handed out more than the remainder");
        assertGe(gained + 1, debt - x, "L4: one stake takes the whole remainder, to one wei of rounding down");
    }

    function test_premiumsAreCapsAnUnderwaterTroveHandsOverEverything() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _open(bob, 400 * E, 50_000 * E);
        _fundPool(bob, 30_000 * E); // enough to absorb the whole debt
        uint256 coll = manager.troveColl(t);
        feed.set(_priceForIcr(t, 95), PriceStatus.Valid); // under water
        vm.prank(keeper);
        LiquidationValues memory v = manager.liquidate(t);
        uint256 bonus = coll * PCT / 2 / E;
        assertEq(v.debtRemainder, 0);
        assertEq(v.collToSP, coll - bonus, "L2: an under-water Trove hands the pool everything left after the bonus");
        assertEq(v.collSurplus, 0, "L3: nothing is left for the owner");
        assertEq(manager.surplus(alice), 0);
    }

    // --- L3 and B9: the owner's surplus ---------------------------------------------------------------------------------

    function test_surplusBelongsToTheOwnerAndIsClaimedWithoutAPrice() public {
        uint256 t = _open(alice, 20 * E, 20_000 * E);
        _open(bob, 400 * E, 50_000 * E);
        _fundPool(bob, 30_000 * E);
        uint256 coll = manager.troveColl(t);
        uint256 debt = manager.troveDebt(t);
        uint256 price = _priceForIcr(t, 108);
        feed.set(price, PriceStatus.Valid);
        vm.prank(keeper);
        LiquidationValues memory v = manager.liquidate(t);
        uint256 expected = coll - coll * PCT / 2 / E - debt * 105 * PCT / price;
        assertEq(v.collSurplus, expected, "L3: the surplus is what the premium and the bonus leave");
        assertEq(manager.surplus(alice), expected);
        feed.setBroken(true);
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        manager.claimSurplus();
        assertEq(weth.balanceOf(alice) - before, expected, "L3: the owner claims the surplus, no price needed");
        assertEq(manager.surplus(alice), 0);
    }

    // --- SP1 and B9: the pool after a shutdown ---------------------------------------------------------------------------

    function test_depositsCloseAtShutdownWithdrawalsAndClaimsNeverDo() public {
        _open(alice, 20 * E, 20_000 * E);
        _fundPool(alice, 10_000 * E);
        feed.set(1, PriceStatus.Failed);
        manager.pokeOracle();
        assertTrue(manager.ledger().shutdownAt != 0);
        vm.prank(alice);
        vm.expectRevert(BranchShutDown.selector);
        sp.deposit(1 * E);
        feed.setBroken(true);
        vm.prank(alice);
        uint256 out = sp.withdraw(10_000 * E);
        assertEq(out, 10_000 * E, "SP1: a withdrawal is never blocked and never needs a price");
        vm.prank(alice);
        sp.claim();
    }
}
