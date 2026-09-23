// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StableToken} from "../src/core/StableToken.sol";
import {FrontendRegistry} from "../src/core/FrontendRegistry.sol";
import {CollateralVault} from "../src/core/CollateralVault.sol";
import {TroveNFT} from "../src/core/TroveNFT.sol";
import {RateSortedList} from "../src/core/RateSortedList.sol";
import {BranchManager, BranchConfig} from "../src/core/BranchManager.sol";
import {IStabilityPool} from "../src/interfaces/IStabilityPool.sol";
import {IBranchManager} from "../src/interfaces/IBranchManager.sol";
import {IFrontendRegistry, ICollateralVault, ITroveNFT, IRateSortedList} from "../src/interfaces/ICore.sol";
import {IStableToken} from "../src/interfaces/IStableToken.sol";
import {StabilityPool} from "../src/core/StabilityPool.sol";
import {MockCollateral, MockPriceFeed} from "./mocks/BranchMocks.sol";

/// Deploys one branch exactly as `contracts/script/branch_trace.py` configures the model's, at the real addresses the
/// deployment predicts (`vm.computeCreateAddress`), not placeholders.
abstract contract BranchFixture is Test {
    uint256 constant E = 1e18;
    uint256 constant PCT = 1e16;
    uint256 constant START = 1_700_000_000;
    uint256 constant N_ACCOUNTS = 8; // six users, two frontend payouts

    StableToken stable;
    FrontendRegistry registry;
    MockPriceFeed feed;
    MockCollateral weth;
    CollateralVault vault;
    TroveNFT nft;
    RateSortedList list;
    StabilityPool sp;
    BranchManager manager;
    address escrow = makeAddr("InterestEscrow");

    function account(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function deployBranch(uint256 minDebt, uint256 cap0, uint256 capCeiling, uint256 gasDeposit) internal {
        vm.warp(START);
        stable = new StableToken("USDarli", "USDarli", address(this));
        registry = new FrontendRegistry(IStableToken(address(stable)), 3 * PCT);
        feed = new MockPriceFeed(2000 * E);
        weth = new MockCollateral();
        uint256 n = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), n + 4);
        vault = new CollateralVault(weth, predicted);
        nft = new TroveNFT(predicted, "Darli Trove (WETH)", "DTROVE-WETH");
        list = new RateSortedList(predicted);
        sp = new StabilityPool(stable, weth, IBranchManager(predicted));
        manager = new BranchManager(
            BranchConfig({
                stable: IStableToken(address(stable)),
                collToken: weth,
                feed: feed,
                vault: ICollateralVault(address(vault)),
                nft: ITroveNFT(address(nft)),
                list: IRateSortedList(address(list)),
                stabilityPool: IStabilityPool(address(sp)),
                frontends: IFrontendRegistry(address(registry)),
                escrow: escrow,
                mcr: 110 * PCT,
                ccr: 150 * PCT,
                scr: 110 * PCT,
                minDebt: minDebt,
                minRate: PCT / 2,
                maxRate: 250 * PCT,
                cap0: cap0,
                capCeiling: capCeiling,
                gasDeposit: gasDeposit,
                spShare: 72 * PCT,
                penSp: 5 * PCT,
                penRedist: 10 * PCT,
                liqBonus: PCT / 2,
                liqBonusCap: 2 * E
            })
        );
        assertEq(address(manager), predicted, "the branch is not at the address its parts were built against");
        address[] memory minters = new address[](1);
        minters[0] = address(manager);
        stable.sealMinters(minters);
        assertEq(registry.register(account(6), 0), 1);
        assertEq(registry.register(account(7), 40 * PCT), 2);
        for (uint256 i = 0; i < N_ACCOUNTS; i++) {
            vm.startPrank(account(i));
            weth.approve(address(manager), type(uint256).max);
            stable.approve(address(sp), type(uint256).max);
            vm.stopPrank();
        }
    }
}
