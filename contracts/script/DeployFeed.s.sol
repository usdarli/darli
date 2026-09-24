// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DualSourcePriceFeed} from "../src/oracle/DualSourcePriceFeed.sol";
import {PoolTwapSource} from "../src/oracle/PoolTwapSource.sol";
import {ChainlinkSource, ChainlinkSequencerGuard, IAggregatorV3} from "../src/oracle/ChainlinkAdapters.sol";
import {IFeedSource, ISequencerGuard} from "../src/interfaces/IPriceFeed.sol";

/// @notice The WETH branch's price feed (`docs/SPEC.md` 7): the Chainlink ETH/USD feed and the Base sequencer guard as
///         the primary, the pool source (O7) as the second source. Deployed before DeployDarli, which takes its address
///         as WETH_FEED. Every value is a `docs/SPEC.md` §2 constant written here, from the evidence in `docs/RESULTS.md`
///         (the oracle's thresholds against a year of Base history) and the cold reads measured in `contracts/fork`.
///
///             forge script script/DeployFeed.s.sol --rpc-url ... --broadcast
contract DeployFeed is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006; // Base
    address constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD on Base, 8 decimals
    address constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // Chainlink Base sequencer uptime feed
    // SPEC 2, the pool source (O7): WETH/stablecoin pools with the v3 `observe` oracle
    address constant UNI_USDC_005 = 0xd0b53D9277642d899DF5C87A3966A349A798F224; // Uniswap v3, 0.05 %
    address constant UNI_USDC_03 = 0x6c561B446416E1A00E8E93E221854d6eA4171372; // Uniswap v3, 0.3 %
    address constant AERO_USDC = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59; // Aerodrome Slipstream, spacing 100
    address constant AERO_USDT = 0x9785eF59E2b499fB741674ecf6fAF912Df7b3C1b; // Aerodrome Slipstream, spacing 100
    uint32 constant WINDOW = 10 minutes;
    uint256 constant POOL_STALENESS = 1 hours;
    uint256 constant MIN_DEPTH = 5_000_000e18; // weight, in dollars
    uint256 constant MAX_DEVIATION = 5e16; // 5 %
    uint256 constant POOL_CALL_GAS = 80_000;
    uint256 constant POOL_SOURCE_GAS = 600_000; // about twice a cold read of the four pools
    // SPEC 2, the primary
    uint256 constant STALENESS = 1 hours; // three heartbeats of the feed
    uint256 constant TIMEOUT = 24 hours;
    uint256 constant GRACE = 1 hours;
    uint256 constant FEED_GAS = 100_000;
    uint256 constant SEQUENCER_GAS = 100_000;

    function run() external returns (DualSourcePriceFeed feed) {
        address[] memory pools = new address[](4);
        (pools[0], pools[1], pools[2], pools[3]) = (UNI_USDC_005, UNI_USDC_03, AERO_USDC, AERO_USDT);
        vm.startBroadcast();
        PoolTwapSource pooled = new PoolTwapSource(WETH, pools, WINDOW, POOL_STALENESS, MIN_DEPTH, POOL_CALL_GAS);
        feed = new DualSourcePriceFeed(
            IFeedSource(address(new ChainlinkSource(IAggregatorV3(ETH_USD)))),
            pooled,
            ISequencerGuard(address(new ChainlinkSequencerGuard(IAggregatorV3(SEQUENCER)))),
            STALENESS,
            TIMEOUT,
            GRACE,
            FEED_GAS,
            SEQUENCER_GAS,
            POOL_SOURCE_GAS,
            MAX_DEVIATION
        );
        vm.stopBroadcast();
        console2.log("WETH_FEED", address(feed));
    }
}
