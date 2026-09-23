// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeedSource, ISequencerGuard} from "../interfaces/IPriceFeed.sol";

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80);
    function decimals() external view returns (uint8);
}

/// @notice Chainlink price feed -> IFeedSource, scaled to 18 decimals. Any failure in here happens INSIDE the
///         stipend of the calling feed, so it is simply a malformed answer.
contract ChainlinkSource is IFeedSource {
    IAggregatorV3 public immutable aggregator;
    uint256 public immutable scale;

    constructor(IAggregatorV3 aggregator_) {
        aggregator = aggregator_;
        scale = 10 ** (18 - aggregator_.decimals());
    }

    function read() external view returns (int256 value, uint256 updatedAt) {
        (, int256 answer,, uint256 updated,) = aggregator.latestRoundData();
        return (answer * int256(scale), updated);
    }
}

/// @notice Chainlink L2 sequencer uptime feed -> ISequencerGuard. answer == 0 means "up"; startedAt is the time of
///         the last status change.
contract ChainlinkSequencerGuard is ISequencerGuard {
    IAggregatorV3 public immutable uptimeFeed;

    constructor(IAggregatorV3 uptimeFeed_) {
        uptimeFeed = uptimeFeed_;
    }

    function status() external view returns (bool isUp, uint256 since) {
        (, int256 answer, uint256 startedAt,,) = uptimeFeed.latestRoundData();
        return (answer == 0, startedAt);
    }
}
