// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeedSource, ISequencerGuard} from "../interfaces/IPriceFeed.sol";
import {DualSourcePriceFeed} from "./DualSourcePriceFeed.sol";

/// @title SingleSourcePriceFeed
/// @notice `docs/SPEC.md` 7 for one source: the dual-source feed without a pool source (O8: exactly the single-source
///         procedure). Everything is immutable: the protocol cannot swap the feed.
contract SingleSourcePriceFeed is DualSourcePriceFeed {
    constructor(
        IFeedSource source_,
        ISequencerGuard sequencer_,
        uint256 stalenessThreshold_,
        uint256 failureTimeout_,
        uint256 gracePeriod_,
        uint256 feedGasLimit_,
        uint256 sequencerGasLimit_
    )
        DualSourcePriceFeed(
            source_,
            IFeedSource(address(0)),
            sequencer_,
            stalenessThreshold_,
            failureTimeout_,
            gracePeriod_,
            feedGasLimit_,
            sequencerGasLimit_,
            0,
            0
        )
    {}
}
