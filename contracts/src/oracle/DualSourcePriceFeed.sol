// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceFeed, IFeedSource, ISequencerGuard} from "../interfaces/IPriceFeed.sol";
import {PriceStatus, InsufficientGasForOracleCall} from "../Types.sol";
import {CALL_OVERHEAD, ORACLE_GAS_BUFFER} from "../libraries/Constants.sol";

/// @title DualSourcePriceFeed
/// @notice `docs/SPEC.md` 7: a primary source (an external feed) and an optional pool source (O7), both fixed at
///         construction; the protocol cannot swap either. Decision procedure (O2, O3, O8; order matters):
///           1. network: sequencer down / in grace                                  -> NetworkUnstable
///           2. the primary: healthy (well-formed, fresh), dead (O3's conditions, sequencer up for the timeout), or
///              temporarily bad; the pool source: available or not
///           3. healthy primary: Valid at its price, unless the pool source is available and further than
///              maxDeviation away -> PriceInvalid, and Failed once that lasted a timeout with no Valid between
///              dead primary: Valid at the pool source's price if available (the fallback), Failed if the pool source
///              is dead too (absent, or unavailable a timeout long), else PriceInvalid
///              temporarily bad primary: PriceInvalid, whatever the pool source says
///         Without a pool source this is exactly the single-source procedure.
///         Reference model: `model/model.py` `OracleFeed`, scenarios 20 and 36, fuzz_oracle.py (F1-F13); replayed
///         step by step in `test_diff_oracleMatchesModel`.
contract DualSourcePriceFeed is IPriceFeed {
    IFeedSource public immutable source;
    IFeedSource public immutable poolSource; // address(0): single-source
    ISequencerGuard public immutable sequencer; // address(0) on L1
    uint256 public immutable stalenessThreshold;
    uint256 public immutable failureTimeout;
    uint256 public immutable gracePeriod;
    uint256 public immutable feedGasLimit;
    uint256 public immutable sequencerGasLimit;
    uint256 public immutable poolGasLimit;
    uint256 public immutable maxDeviation; // WAD: 5e16 = 5 %

    uint256 public lastGoodPrice;
    uint64 public lastValidAt;
    uint64 public invalidSince; // the primary's malformed marker; 0 = none pending
    uint64 public poolInvalidSince; // the pool source's unavailable marker
    uint64 public disagreeSince; // the sources' disagreement marker

    enum Primary {
        Temp,
        Healthy,
        Dead
    }

    error FeedUnhealthyAtCreation();
    error BadConfig();

    constructor(
        IFeedSource source_,
        IFeedSource poolSource_,
        ISequencerGuard sequencer_,
        uint256 stalenessThreshold_,
        uint256 failureTimeout_,
        uint256 gracePeriod_,
        uint256 feedGasLimit_,
        uint256 sequencerGasLimit_,
        uint256 poolGasLimit_,
        uint256 maxDeviation_
    ) {
        if (stalenessThreshold_ == 0 || stalenessThreshold_ >= failureTimeout_) {
            revert BadConfig();
        }
        if (address(poolSource_) != address(0) && (maxDeviation_ == 0 || poolGasLimit_ == 0)) revert BadConfig();
        source = source_;
        poolSource = poolSource_;
        sequencer = sequencer_;
        stalenessThreshold = stalenessThreshold_;
        failureTimeout = failureTimeout_;
        gracePeriod = gracePeriod_;
        feedGasLimit = feedGasLimit_;
        sequencerGasLimit = sequencerGasLimit_;
        poolGasLimit = poolGasLimit_;
        maxDeviation = maxDeviation_;
        // lastGoodPrice exists from birth; a stipend too small for an honest read, or a pool source that cannot answer
        // or disagrees, is caught here.
        (uint256 price, PriceStatus status) = _fetch();
        if (status != PriceStatus.Valid || poolInvalidSince != 0) revert FeedUnhealthyAtCreation();
        lastGoodPrice = price;
    }

    function fetchPrice() external returns (uint256, PriceStatus) {
        return _fetch();
    }

    function fetchRedemptionPrice() external returns (uint256, PriceStatus) {
        return _fetch();
    }

    // ------------------------------------------------------------------------------------------------------------

    function _fetch() private returns (uint256, PriceStatus) {
        // 1. network first: a sequencer outage makes every source look stale.
        (bool netOkForGrace, bool netOkForFailure) = _network();
        if (!netOkForGrace) return (lastGoodPrice, PriceStatus.NetworkUnstable);

        // 2. the primary's guarded read, then the pool source's
        (bool ok, int256 value, uint256 updatedAt) =
            _guardedRead(address(source), feedGasLimit, IFeedSource.read.selector);
        (bool poolOk, uint256 poolPrice, bool poolDead) = _poolSide(netOkForFailure);
        Primary primary = _classify(!ok || value <= 0 || updatedAt > block.timestamp, updatedAt, netOkForFailure);

        // 3. the decision (O8)
        if (primary == Primary.Healthy) {
            uint256 price = uint256(value);
            if (poolOk && _disagree(price, poolPrice)) {
                if (disagreeSince == 0) {
                    disagreeSince = uint64(block.timestamp); // survives only if the transaction does not revert
                } else if (block.timestamp - disagreeSince >= failureTimeout && netOkForFailure) {
                    return (lastGoodPrice, PriceStatus.Failed);
                }
                return (lastGoodPrice, PriceStatus.PriceInvalid);
            }
            return _valid(price);
        }
        if (primary == Primary.Dead) {
            if (poolOk) return _valid(poolPrice); // the fallback: a dead primary no longer shuts the branch down
            if (poolDead) return (lastGoodPrice, PriceStatus.Failed);
        }
        return (lastGoodPrice, PriceStatus.PriceInvalid);
    }

    /// The primary: healthy, dead, or temporarily bad. Only a healthy primary clears its malformed marker; a
    /// well-formed but old answer neither sets nor clears it.
    function _classify(bool malformed, uint256 updatedAt, bool netOkForFailure) private returns (Primary) {
        if (malformed) {
            if (invalidSince == 0) {
                invalidSince = uint64(block.timestamp); // survives only if the transaction does not revert
                return Primary.Temp;
            }
            return block.timestamp - invalidSince >= failureTimeout && netOkForFailure ? Primary.Dead : Primary.Temp;
        }
        uint256 age = block.timestamp - updatedAt;
        if (age > stalenessThreshold) {
            return age > failureTimeout && netOkForFailure ? Primary.Dead : Primary.Temp;
        }
        invalidSince = 0;
        return Primary.Healthy;
    }

    /// The pool source (O7): available, and dead once unavailable at observations a timeout apart. Without one it is
    /// always dead, which makes this feed the single-source one.
    function _poolSide(bool netOkForFailure) private returns (bool poolOk, uint256 poolPrice, bool poolDead) {
        if (address(poolSource) == address(0)) return (false, 0, true);
        (bool ok, int256 value, uint256 updatedAt) =
            _guardedRead(address(poolSource), poolGasLimit, IFeedSource.read.selector);
        poolOk = ok && value > 0 && updatedAt <= block.timestamp;
        if (poolOk) {
            poolInvalidSince = 0;
            return (true, uint256(value), false);
        }
        if (poolInvalidSince == 0) poolInvalidSince = uint64(block.timestamp);
        poolDead = block.timestamp - poolInvalidSince >= failureTimeout && netOkForFailure;
    }

    function _disagree(uint256 a, uint256 b) private view returns (bool) {
        (uint256 hi, uint256 lo) = a > b ? (a, b) : (b, a);
        return hi * 1e18 > lo * (1e18 + maxDeviation);
    }

    function _valid(uint256 price) private returns (uint256, PriceStatus) {
        lastGoodPrice = price;
        lastValidAt = uint64(block.timestamp);
        disagreeSince = 0;
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
        if (gasleft() < ((stipend + CALL_OVERHEAD) * 64) / 63 + ORACLE_GAS_BUFFER) {
            revert InsufficientGasForOracleCall();
        }
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
