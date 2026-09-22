// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceFeed, IFeedSource, ISequencerGuard} from "../interfaces/IPriceFeed.sol";
import {PriceStatus, InsufficientGasForOracleCall} from "../Types.sol";
import {CALL_OVERHEAD, ORACLE_GAS_BUFFER} from "../libraries/Constants.sol";

/// @title SingleSourcePriceFeed
/// @notice `docs/SPEC.md` 7 for one source. Everything is immutable: the protocol cannot swap the feed.
///         Decision procedure (order matters):
///           1. network: sequencer down / in grace            -> NetworkUnstable
///           2. source answer malformed | stale               -> PriceInvalid (temporary)
///           3. credible failure, only with >= TIMEOUT of uninterrupted sequencer uptime:
///                a) staleness: readable updatedAt older than TIMEOUT
///                b) malformed answers observed TIMEOUT apart with no healthy observation in between
///         Reference model: `model/model.py` `OracleFeed`, scenario_20, fuzz_oracle.py (F1-F9).
contract SingleSourcePriceFeed is IPriceFeed {
    IFeedSource public immutable source;
    ISequencerGuard public immutable sequencer; // address(0) on L1
    uint256 public immutable stalenessThreshold;
    uint256 public immutable failureTimeout;
    uint256 public immutable gracePeriod;
    uint256 public immutable feedGasLimit;
    uint256 public immutable sequencerGasLimit;

    uint256 public lastGoodPrice;
    uint64 public lastValidAt;
    uint64 public invalidSince; // 0 = no malformed observation pending

    error FeedUnhealthyAtCreation();
    error BadConfig();

    constructor(
        IFeedSource source_,
        ISequencerGuard sequencer_,
        uint256 stalenessThreshold_,
        uint256 failureTimeout_,
        uint256 gracePeriod_,
        uint256 feedGasLimit_,
        uint256 sequencerGasLimit_
    ) {
        if (stalenessThreshold_ == 0 || stalenessThreshold_ >= failureTimeout_) revert BadConfig();
        source = source_;
        sequencer = sequencer_;
        stalenessThreshold = stalenessThreshold_;
        failureTimeout = failureTimeout_;
        gracePeriod = gracePeriod_;
        feedGasLimit = feedGasLimit_;
        sequencerGasLimit = sequencerGasLimit_;
        // lastGoodPrice exists from birth; a stipend that is too small for an honest read is caught here.
        (uint256 price, PriceStatus status) = _fetch();
        if (status != PriceStatus.Valid) revert FeedUnhealthyAtCreation();
        lastGoodPrice = price;
    }

    function fetchPrice() external returns (uint256, PriceStatus) {
        return _fetch();
    }

    function fetchRedemptionPrice() external returns (uint256, PriceStatus) {
        return _fetch();
    }

    // ------------------------------------------------------------------------------------------------------------

    function _fetch() private returns (uint256 price, PriceStatus status) {
        // 1. network first: a sequencer outage makes every feed look stale.
        (bool netOkForGrace, bool netOkForFailure) = _network();
        if (!netOkForGrace) return (lastGoodPrice, PriceStatus.NetworkUnstable);

        // 2. one guarded read
        (bool ok, int256 value, uint256 updatedAt) = _guardedRead(address(source), feedGasLimit, IFeedSource.read.selector);
        bool malformed = !ok || value <= 0 || updatedAt > block.timestamp;

        if (malformed) {
            if (invalidSince == 0) {
                invalidSince = uint64(block.timestamp); // survives only if the transaction does not revert
                return (lastGoodPrice, PriceStatus.PriceInvalid);
            }
            if (block.timestamp - invalidSince >= failureTimeout && netOkForFailure) {
                return (lastGoodPrice, PriceStatus.Failed);
            }
            return (lastGoodPrice, PriceStatus.PriceInvalid);
        }

        uint256 age = block.timestamp - updatedAt;
        if (age > stalenessThreshold) {
            // a well-formed but old answer neither sets nor clears the malformed marker
            if (age > failureTimeout && netOkForFailure) return (lastGoodPrice, PriceStatus.Failed);
            return (lastGoodPrice, PriceStatus.PriceInvalid);
        }

        price = uint256(value);
        lastGoodPrice = price;
        lastValidAt = uint64(block.timestamp);
        invalidSince = 0;
        return (price, PriceStatus.Valid);
    }

    function _network() private view returns (bool okForGrace, bool okForFailure) {
        if (address(sequencer) == address(0)) return (true, true);
        (bool ok, int256 isUp, uint256 since) =
            _guardedRead(address(sequencer), sequencerGasLimit, ISequencerGuard.status.selector);
        // an unreadable uptime feed is treated as "network unstable": the conservative, temporary state
        if (!ok || isUp != 1 || since > block.timestamp) return (false, false);
        uint256 up = block.timestamp - since;
        return (up >= gracePeriod, up >= failureTimeout);
    }

    /// @dev Fixed stipend, proven affordable UP FRONT. Because the callee always receives its full stipend, any
    ///      failure inside it (revert, out-of-gas, burning everything) is the callee's fault, and no amount of gas
    ///      chosen by the caller can make a healthy source look malformed.
    ///      Low-level staticcall on purpose: `try/catch` does not catch a return-data decoding failure or a call to
    ///      an address without code, and copying unbounded return data is a gas bomb. Exactly 64 bytes are read.
    function _guardedRead(address target, uint256 stipend, bytes4 selector)
        private
        view
        returns (bool ok, int256 a, uint256 b)
    {
        if (gasleft() < ((stipend + CALL_OVERHEAD) * 64) / 63 + ORACLE_GAS_BUFFER) revert InsufficientGasForOracleCall();
        bool success;
        uint256 returned;
        bytes32 w0;
        bytes32 w1;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            success := staticcall(stipend, target, ptr, 4, ptr, 0x40)
            returned := returndatasize()
            w0 := mload(ptr)
            w1 := mload(add(ptr, 0x20))
        }
        if (!success || returned < 0x40) return (false, 0, 0);
        return (true, int256(uint256(w0)), uint256(w1));
    }
}
