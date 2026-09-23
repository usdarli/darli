// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BranchFixture} from "./BranchFixture.sol";
import {BranchManager, BranchConfig} from "../src/core/BranchManager.sol";
import {FrontendRegistry} from "../src/core/FrontendRegistry.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {ICollateralVault, IFrontendRegistry, ITroveNFT, IRateSortedList} from "../src/interfaces/ICore.sol";
import {IStabilityPool} from "../src/interfaces/IStabilityPool.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MIN_SP_RESIDUAL, DUST_THRESHOLD} from "../src/libraries/Constants.sol";
import "../src/Types.sol";

/// What the model-driven trace cannot show: who may call what, which operations never read the price, and the
/// boundaries of the split, the debt cap and the dust rule. The trace (BranchManager.trace.t.sol) shows the arithmetic.
contract BranchManagerTest is BranchFixture {
    address alice = account(0);
    address bob = account(1);
    address carol = account(2);
    uint256 constant MAX = type(uint256).max;

    function setUp() public {
        deployBranch(2000 * E, 1_000_000 * E, 1_000_000 * E, E / 1000);
        for (uint256 i = 0; i < 3; i++) {
            weth.mint(account(i), 1000 * E);
        }
    }

    function _open(address who, uint256 coll, uint256 debt, uint256 rate, uint32 fid) internal returns (uint256) {
        vm.prank(who);
        return manager.openTrove(who, coll, debt, rate, fid, MAX, 0, 0);
    }

    // --- SPEC B9: the risk-reducing operations never read the price ------------------------------------------------------

    function test_repayAddCollAndCloseNeverReadThePrice() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        _open(bob, 20 * E, 10_000 * E, 5 * PCT, 0); // so that alice's is not the last Trove, and she can buy USDarli
        vm.warp(block.timestamp + 3 days);
        feed.setBroken(true); // any read of the feed would now revert
        vm.prank(alice);
        manager.repay(t, 1_000 * E);
        vm.prank(alice);
        manager.addColl(t, 1 * E);
        vm.prank(alice);
        manager.adjustTrove(t, int256(1 * E), -int256(500 * E), 0); // top-up and repayment only: addColl + repay
        // the risk-increasing ones do read it, and are refused
        vm.startPrank(alice);
        vm.expectRevert(bytes("feed read"));
        manager.borrow(t, 100 * E, MAX);
        vm.expectRevert(bytes("feed read"));
        manager.withdrawColl(t, 1 * E);
        vm.stopPrank();
        // close: alice needs the upfront fee and the interest on top of what she borrowed
        vm.prank(bob);
        stable.transfer(alice, 1_000 * E);
        vm.prank(alice);
        manager.closeTrove(t);
        assertEq(uint8(manager.getTrove(t).status), uint8(TroveStatus.ClosedByOwner));
    }

    function test_riskReducingOperationsIgnoreEveryOracleStatus() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        PriceStatus[3] memory bad = [PriceStatus.NetworkUnstable, PriceStatus.PriceInvalid, PriceStatus.Failed];
        for (uint256 i = 0; i < 3; i++) {
            feed.set(1 * E, bad[i]); // not observed by pokeOracle, so the branch is still live
            vm.prank(alice);
            manager.repay(t, 10 * E);
            vm.prank(bob);
            manager.addColl(t, 1);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(PriceNotValid.selector, bad[i]));
            manager.borrow(t, 10 * E, MAX);
        }
    }

    // --- SPEC 10.5: rights, and whose USDarli is burned ------------------------------------------------------------------

    function test_repayBurnsFromTheCallerNeverFromTheOwner() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        _open(bob, 20 * E, 10_000 * E, 5 * PCT, 0);
        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 bobBefore = stable.balanceOf(bob);
        uint256 debtBefore = manager.troveDebt(t);
        vm.prank(bob);
        manager.repay(t, 1_000 * E); // anyone may repay someone else's Trove, with his own tokens
        assertEq(stable.balanceOf(alice), aliceBefore, "10.5: repay burned from the owner instead of the caller");
        assertEq(stable.balanceOf(bob), bobBefore - 1_000 * E);
        assertEq(manager.troveDebt(t), debtBefore - 1_000 * E);
        uint256 bobWeth = weth.balanceOf(bob);
        vm.prank(bob);
        manager.addColl(t, 2 * E); // and top it up, with his own collateral
        assertEq(weth.balanceOf(bob), bobWeth - 2 * E);
        assertEq(manager.troveColl(t), 22 * E);
    }

    function test_onlyTheOwnerOrAnApprovedAddressChangesTheTrove() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        vm.startPrank(carol);
        vm.expectRevert(NotAuthorized.selector);
        manager.borrow(t, 100 * E, MAX);
        vm.expectRevert(NotAuthorized.selector);
        manager.withdrawColl(t, 1 * E);
        vm.expectRevert(NotAuthorized.selector);
        manager.adjustTrove(t, int256(1 * E), -int256(1 * E), MAX);
        vm.expectRevert(NotAuthorized.selector);
        manager.adjustRate(t, 6 * PCT, MAX, 0, 0);
        vm.expectRevert(NotAuthorized.selector);
        manager.closeTrove(t);
        vm.stopPrank();
        // approved on the NFT, carol may act, and what she borrows is hers
        vm.prank(alice);
        nft.approve(carol, t);
        uint256 before = stable.balanceOf(carol);
        vm.prank(carol);
        manager.borrow(t, 100 * E, MAX);
        assertEq(stable.balanceOf(carol), before + 100 * E);
    }

    function test_wiredEntryPointsRefuseEveryoneElse() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        vm.startPrank(carol);
        vm.expectRevert(NotAuthorized.selector);
        manager.mintAggInterest();
        vm.expectRevert(NotAuthorized.selector);
        manager.onTroveTransfer(t);
        vm.expectRevert(NotAuthorized.selector);
        vault.accountIn(1);
        vm.expectRevert(NotAuthorized.selector);
        vault.send(carol, 1);
        vm.expectRevert(NotAuthorized.selector);
        nft.mint(carol, 99);
        vm.expectRevert(NotAuthorized.selector);
        nft.burn(t);
        vm.expectRevert(NotAuthorized.selector);
        list.remove(t);
        vm.expectRevert(NotAuthorized.selector);
        registry.recordDeposit(1 * E);
        vm.expectRevert(NotAuthorized.selector);
        registry.credit(0, carol, 1 * E);
        vm.stopPrank();
    }

    function test_zeroAmountsAndUnknownFrontendsAreRefused() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        vm.startPrank(alice);
        vm.expectRevert(ZeroAmount.selector);
        manager.repay(t, 0);
        vm.expectRevert(ZeroAmount.selector);
        manager.addColl(t, 0);
        vm.expectRevert(ZeroAmount.selector);
        manager.borrow(t, 0, MAX);
        vm.expectRevert(ZeroAmount.selector);
        manager.withdrawColl(t, 0);
        vm.expectRevert(ZeroAmount.selector);
        manager.adjustTrove(t, 0, 0, MAX);
        vm.expectRevert(abi.encodeWithSelector(UnknownFrontend.selector, uint32(3)));
        manager.openTrove(alice, 20 * E, 10_000 * E, 5 * PCT, 3, MAX, 0, 0);
        vm.stopPrank();
    }

    // --- SPEC V1: the Stability Pool's share starts exactly at MIN_SP_RESIDUAL -------------------------------------------

    function _accrueAndMeasure(uint256 t) internal returns (uint256 minted, uint256 spGain) {
        vm.warp(block.timestamp + 5 days);
        uint256 debtBefore = manager.ledger().aggDebt;
        uint256 spBefore = stable.balanceOf(address(sp));
        manager.applyPendingDebt(t);
        minted = manager.ledger().aggDebt - debtBefore;
        spGain = stable.balanceOf(address(sp)) - spBefore;
    }

    function test_stabilityPoolShareStartsExactlyAtTheResidual() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 20 * PCT, 0);
        vm.prank(alice);
        sp.deposit(MIN_SP_RESIDUAL - 1);
        (uint256 minted, uint256 gain) = _accrueAndMeasure(t);
        assertGt(minted, 0);
        assertEq(gain, 0, "V1: a pool below MIN_SP_RESIDUAL received yield");
        vm.prank(alice);
        sp.deposit(1);
        (minted, gain) = _accrueAndMeasure(t);
        assertEq(gain, minted * 72 * PCT / E, "V1: a pool at MIN_SP_RESIDUAL did not receive its 72 %");
        assertGt(sp.scaleToB(sp.currentScale()), 0, "V1: yield minted to the pool without being credited to it");
    }

    // --- SPEC B11: the built-in debt cap -------------------------------------------------------------------------------

    function test_debtCapDoublesEachPeriodUpToTheCeilingAndNeverBlocksInterest() public {
        deployBranch(2000 * E, 10_000 * E, 30_000 * E, 0);
        weth.mint(alice, 1000 * E);
        weth.mint(bob, 1000 * E);
        assertEq(manager.debtCap(), 10_000 * E);
        uint256 t = _open(alice, 50 * E, 9_000 * E, 50 * PCT, 0);
        vm.prank(bob);
        vm.expectRevert(DebtCapExceeded.selector);
        manager.openTrove(bob, 50 * E, 2_000 * E, 5 * PCT, 0, MAX, 0, 0);
        vm.warp(block.timestamp + 30 days - 1);
        assertEq(manager.debtCap(), 10_000 * E, "B11: the cap rose before its period");
        vm.warp(block.timestamp + 1);
        assertEq(manager.debtCap(), 20_000 * E);
        _open(bob, 50 * E, 2_000 * E, 5 * PCT, 0);
        vm.warp(block.timestamp + 30 days);
        assertEq(manager.debtCap(), 30_000 * E, "B11: the cap passed its ceiling");
        // at the cap, interest still accrues and is minted: the cap limits new debt, never interest (M-27)
        uint256 room = 30_000 * E - manager.ledger().aggDebt - manager.pendingAggInterest() - 100 * E;
        vm.prank(bob);
        manager.borrow(2, room, MAX);
        vm.warp(block.timestamp + 3650 days);
        assertEq(manager.debtCap(), 30_000 * E, "B11: the cap passed its ceiling");
        manager.applyPendingDebt(t);
        assertGt(manager.ledger().aggDebt, manager.debtCap(), "B11: interest was blocked by the cap");
    }

    // --- SPEC B5: the last Trove may close short by dust, not more --------------------------------------------------------

    function test_lastTroveClosesShortByDustOnly() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 5 * PCT, 1);
        vm.warp(block.timestamp + 10 days);
        manager.applyPendingDebt(t);
        // collect everything the protocol minted elsewhere: escrow, and every claim in the registry
        uint256 escrowBalance = stable.balanceOf(escrow);
        vm.prank(escrow);
        stable.transfer(alice, escrowBalance);
        for (uint256 i = 6; i < N_ACCOUNTS; i++) {
            vm.prank(account(i));
            registry.claim();
            uint256 b = stable.balanceOf(account(i));
            vm.prank(account(i));
            stable.transfer(alice, b);
        }
        vm.prank(alice);
        registry.claim();
        uint256 debt = manager.troveDebt(t);
        uint256 short = debt - stable.balanceOf(alice); // the registry's rounding remainder: ownerless dust
        assertLe(short, DUST_THRESHOLD);
        // more than dust short is refused
        uint256 give = DUST_THRESHOLD + 1 - short;
        vm.prank(alice);
        stable.transfer(bob, give);
        vm.prank(alice);
        vm.expectRevert(ShortfallAboveDust.selector);
        manager.closeTrove(t);
        vm.prank(bob);
        stable.transfer(alice, give);
        // dust short is allowed; with the branch empty, the shortfall and the ledger's rounding remainder are all
        // parked in badDebt, and the supply still equals the aggregate debt (T3)
        vm.prank(alice);
        manager.closeTrove(t);
        BranchLedger memory l = manager.ledger();
        assertGe(l.badDebt, short, "B5: the shortfall must be parked in badDebt");
        assertEq(l.badDebt, l.aggDebt, "4.2: an empty branch parks its whole remainder in badDebt");
        assertEq(stable.totalSupply(), l.aggDebt, "T3: supply == aggregate debt");
        assertLt(l.badDebt, DUST_THRESHOLD, "a dust remainder does not shut the branch down");
        assertEq(l.shutdownAt, 0);
    }

    // --- SPEC B1, V2: an NFT transfer settles the Trove for the old owner first --------------------------------------------

    function test_transferCreditsTheOldOwnerFirst() public {
        uint256 t = _open(alice, 20 * E, 10_000 * E, 30 * PCT, 2); // frontend 2 pays 40 % back to the Trove's owner
        vm.warp(block.timestamp + 30 days);
        uint256 before = registry.claimable(alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, t);
        assertGt(registry.claimable(alice), before, "B1: the kickback accrued before the transfer left the old owner");
        assertEq(registry.claimable(bob), 0, "B1: the new owner received kickback from before the transfer");
        assertEq(manager.getTrove(t).lastDebtUpdate, block.timestamp, "B1: the transfer did not run step B");
        vm.warp(block.timestamp + 30 days);
        manager.applyPendingDebt(t);
        assertGt(registry.claimable(bob), 0);
    }

    // --- SPEC V2: a frontend keeps its share; without one, the share is the owner's ----------------------------------------

    /// Expected credits from each Trove's own fee and interest: floor(amount x 3 %) per touch, then the kickback split.
    function test_untaggedShareReturnsToTheBorrower() public {
        uint256 cli = _open(alice, 50 * E, 30_000 * E, 10 * PCT, 0); // no frontend: a command-line or own client
        uint256 tagged = _open(bob, 50 * E, 30_000 * E, 10 * PCT, 2); // frontend 2 pays 40 % back to the owner
        uint256 feeCli = manager.getTrove(cli).recordedDebt - 30_000 * E;
        uint256 feeTagged = manager.getTrove(tagged).recordedDebt - 30_000 * E;
        vm.warp(block.timestamp + 90 days);
        uint256 dCli = manager.getTrove(cli).recordedDebt;
        uint256 dTagged = manager.getTrove(tagged).recordedDebt;
        manager.applyPendingDebt(cli);
        manager.applyPendingDebt(tagged);
        uint256 aCli = manager.getTrove(cli).recordedDebt - dCli;
        uint256 aTagged = manager.getTrove(tagged).recordedDebt - dTagged;
        assertEq(
            registry.claimable(alice), _share(feeCli) + _share(aCli), "V2: an untagged Trove's share is its owner's"
        );
        uint256 kickFee = _share(feeTagged) * 40 / 100;
        uint256 kickInterest = _share(aTagged) * 40 / 100;
        assertEq(registry.claimable(bob), kickFee + kickInterest, "V2: the kickback of a tagged Trove");
        assertEq(
            registry.claimable(account(7)),
            _share(feeTagged) - kickFee + _share(aTagged) - kickInterest,
            "V2: a frontend keeps its share of the Troves it brought"
        );
        assertEq(
            registry.claimable(alice) + registry.claimable(bob) + registry.claimable(account(7)),
            registry.totalCredited(),
            "V2: every credit has an owner"
        );
    }

    function _share(uint256 x) internal pure returns (uint256) {
        return x * 3 / 100;
    }

    // --- SPEC V2: kickback only rises, and only its payout may raise it -------------------------------------------------------

    function test_kickbackOnlyRisesAndOnlyByItsPayout() public {
        vm.expectRevert(NotAuthorized.selector);
        registry.increaseKickback(2, 50 * PCT);
        vm.startPrank(account(7));
        vm.expectRevert(FrontendRegistry.KickbackOutOfRange.selector);
        registry.increaseKickback(2, 39 * PCT);
        vm.expectRevert(FrontendRegistry.KickbackOutOfRange.selector);
        registry.increaseKickback(2, E + 1);
        registry.increaseKickback(2, 50 * PCT);
        vm.stopPrank();
        (, uint96 k) = registry.frontends(2);
        assertEq(k, 50 * PCT);
    }

    // --- SPEC B12: collateral sent straight to the vault belongs to nobody ------------------------------------------------

    function test_strayCollateralStaysOutsideEveryLedger() public {
        _open(alice, 20 * E, 10_000 * E, 5 * PCT, 0);
        uint256 accounted = vault.accountedColl();
        weth.mint(address(vault), 7 * E);
        assertEq(vault.accountedColl(), accounted, "B12: a donation entered the ledger");
        assertEq(weth.balanceOf(address(vault)), accounted + 7 * E);
        assertEq(accounted, manager.activeColl() + manager.defaultColl() + manager.gasPool(), "B12: named accounts");
    }

    // --- construction ---------------------------------------------------------------------------------------------------

    function test_inconsistentParametersAreRefused() public {
        BranchConfig memory c = BranchConfig({
            stable: IStableToken(address(stable)),
            collToken: IERC20(address(weth)),
            feed: IPriceFeed(address(feed)),
            vault: ICollateralVault(address(vault)),
            nft: ITroveNFT(address(nft)),
            list: IRateSortedList(address(list)),
            stabilityPool: IStabilityPool(address(sp)),
            frontends: IFrontendRegistry(address(registry)),
            escrow: escrow,
            mcr: 110 * PCT,
            ccr: 110 * PCT, // MCR < CCR violated
            scr: 110 * PCT,
            minDebt: 2000 * E,
            minRate: PCT / 2,
            maxRate: 250 * PCT,
            cap0: 1,
            capCeiling: 1,
            gasDeposit: 0,
            spShare: 72 * PCT,
            penSp: 5 * PCT,
            penRedist: 10 * PCT,
            liqBonus: PCT / 2,
            liqBonusCap: 2 * E
        });
        vm.expectRevert(BranchManager.InvalidConfig.selector);
        new BranchManager(c);
        c.ccr = 150 * PCT;
        c.escrow = address(0);
        vm.expectRevert(BranchManager.InvalidConfig.selector);
        new BranchManager(c);
    }
}
