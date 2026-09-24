// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DualSourcePriceFeed} from "../src/oracle/DualSourcePriceFeed.sol";
import {PoolTwapSource} from "../src/oracle/PoolTwapSource.sol";
import {ChainlinkSource, ChainlinkSequencerGuard, IAggregatorV3} from "../src/oracle/ChainlinkAdapters.sol";
import {IFeedSource, ISequencerGuard} from "../src/interfaces/IPriceFeed.sol";

/// @notice The WETH branch's price feed (`docs/SPEC.md` 7): the Chainlink ETH/USD feed and the Base sequencer guard as
///         the primary, the pool source (O7) as the second source. Deployed before DeployDarli, which takes its address
///         as WETH_FEED. Every value SPEC 13 item 2 leaves open is read from the environment and nothing defaults for it:
///         the pool set (POOLS, comma-separated), POOL_WINDOW, POOL_STALENESS, MIN_DEPTH, POOL_CALL_GAS,
///         POOL_SOURCE_GAS, MAX_DEVIATION, FEED_GAS, SEQUENCER_GAS, STALENESS, TIMEOUT, GRACE.
///
///             forge script script/DeployFeed.s.sol --rpc-url ... --broadcast
contract DeployFeed is Script {
    address constant WETH = 0x4200000000000000000000000000000000000006; // Base
    address constant ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // Chainlink ETH/USD on Base, 8 decimals
    address constant SEQUENCER = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // Chainlink Base sequencer uptime feed

    function run() external returns (DualSourcePriceFeed feed) {
        address[] memory pools = vm.envAddress("POOLS", ",");
        vm.startBroadcast();
        PoolTwapSource pooled = new PoolTwapSource(
            WETH,
            pools,
            uint32(vm.envUint("POOL_WINDOW")),
            vm.envUint("POOL_STALENESS"),
            vm.envUint("MIN_DEPTH"),
            vm.envUint("POOL_CALL_GAS")
        );
        feed = new DualSourcePriceFeed(
            IFeedSource(address(new ChainlinkSource(IAggregatorV3(ETH_USD)))),
            pooled,
            ISequencerGuard(address(new ChainlinkSequencerGuard(IAggregatorV3(SEQUENCER)))),
            vm.envUint("STALENESS"),
            vm.envUint("TIMEOUT"),
            vm.envUint("GRACE"),
            vm.envUint("FEED_GAS"),
            vm.envUint("SEQUENCER_GAS"),
            vm.envUint("POOL_SOURCE_GAS"),
            vm.envUint("MAX_DEVIATION")
        );
        vm.stopBroadcast();
        console2.log("WETH_FEED", address(feed));
    }
}
