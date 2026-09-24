// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {BranchFixture} from "./BranchFixture.sol";
import "../src/Types.sol";

/// The gas deposit (SPEC 2) is sized against the gas a keeper spends on the calls the deposit pays for. Each is measured
/// here as the first touch of every account and slot in its transaction, as a keeper would meet it. The bounds pin the
/// measurements: a change that makes settlement or liquidation dearer fails here before it silently outgrows the deposit.
contract SettlementGasTest is BranchFixture {
    uint256 constant MAX = type(uint256).max;
    uint256 constant N = 51; // one Trove alone, then a full batch of MAX_SETTLE_BATCH
    // each bound is the cold cost measured when this test was written plus about 15 %, rounded; the gas deposit is
    // proposed against the bounds, so a change that outgrows one must revisit the deposit, not the bound
    uint256 constant SETTLE_ONE_BOUND = 420_000;
    uint256 constant SETTLE_PER_TROVE_IN_BATCH_BOUND = 150_000;
    uint256 constant WRITE_OFF_BOUND = 300_000;
    uint256 constant LIQUIDATE_BOUND = 500_000;

    function setUp() public {
        deployBranch(2000 * E, 100_000_000 * E, 100_000_000 * E, E / 1000);
        for (uint256 i = 0; i < N; i++) {
            address who = account(i);
            weth.mint(who, 100 * E);
            vm.startPrank(who);
            weth.approve(address(manager), MAX);
            stable.approve(address(sp), MAX);
            manager.openTrove(who, 10 * E, i == N - 1 ? 18_000 * E : 10_000 * E, PCT / 2 + i * PCT / 10, 0, MAX, 0, 0);
            vm.stopPrank();
        }
        vm.prank(account(0));
        sp.deposit(9_000 * E);
    }

    function _coolAll() internal {
        address[10] memory a = [
            address(manager),
            address(settlement),
            address(vault),
            address(nft),
            address(list),
            address(sp),
            address(weth),
            address(stable),
            address(feed),
            address(registry)
        ];
        for (uint256 i = 0; i < a.length; i++) {
            vm.cool(a[i]);
        }
    }

    function _shutdown() internal {
        feed.set(1, PriceStatus.Failed);
        manager.pokeOracle();
    }

    function test_settlingAndWritingOffATroveCostWhatTheDepositIsSizedFor() public {
        _shutdown();
        _coolAll();
        vm.prank(account(90));
        uint256 g = gasleft();
        settlement.settleTrove(1);
        uint256 one = g - gasleft();
        uint256[] memory ids = new uint256[](50);
        for (uint256 i = 0; i < 50; i++) {
            ids[i] = i + 2;
        }
        _coolAll();
        vm.prank(account(90));
        g = gasleft();
        settlement.settleTroves(ids);
        uint256 batch = g - gasleft();
        console2.log("settleTrove, one Trove, cold:", one);
        console2.log("settleTroves, 50 Troves, cold, per Trove:", batch / 50);
        assertLt(one, SETTLE_ONE_BOUND, "X2: one settlement fits its measured bound");
        assertLt(batch / 50, SETTLE_PER_TROVE_IN_BATCH_BOUND, "X2: a batch fits its measured bound per Trove");
    }

    function test_aWriteOffCostsWhatHalfTheDepositIsSizedFor() public {
        _shutdown();
        vm.warp(block.timestamp + 30 days);
        _coolAll();
        vm.prank(account(90));
        uint256 g = gasleft();
        settlement.writeOff(1);
        uint256 used = g - gasleft();
        console2.log("writeOff, cold:", used);
        assertLt(used, WRITE_OFF_BOUND, "X5: a write-off fits its measured bound");
    }

    function test_aLiquidationCostsWhatTheDepositAndTheBonusAreSizedFor() public {
        // the last Trove (ICR 111 % at 2,000) pushed under MCR; the pool absorbs half, the rest is redistributed
        feed.set(1_900 * E, PriceStatus.Valid);
        _coolAll();
        vm.prank(account(90));
        uint256 g = gasleft();
        manager.liquidate(N);
        uint256 used = g - gasleft();
        console2.log("liquidate, cold:", used);
        assertLt(used, LIQUIDATE_BOUND, "L3: a liquidation fits its measured bound");
    }
}
