// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeedSource, ISequencerGuard} from "../../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../../src/Types.sol";

contract MockSource is IFeedSource {
    enum Mode { Ok, Revert, BurnAllGas, ShortReturn }

    int256 public value;
    uint256 public updatedAt;
    Mode public mode;
    uint256 public burn; // gas an honest read consumes before answering

    constructor(int256 v, uint256 burn_) {
        value = v;
        updatedAt = block.timestamp;
        burn = burn_;
    }

    function set(int256 v, uint256 t) external { value = v; updatedAt = t; }
    function push() external { updatedAt = block.timestamp; }
    function setMode(Mode m) external { mode = m; }

    function read() external view returns (int256, uint256) {
        if (mode == Mode.Revert) revert("source down");
        if (mode == Mode.BurnAllGas) { while (true) {} }
        if (mode == Mode.ShortReturn) { assembly { mstore(0, 1) return(0, 0x20) } }
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return (value, updatedAt);
    }
}

/// proxy -> aggregator: a plain nested call; an inner failure bubbles up as a revert of the proxy,
/// which still owns ~1/64 of ITS gas and hands it back to the caller.
contract NestedProxySource is IFeedSource {
    IFeedSource public immutable inner;
    constructor(IFeedSource inner_) { inner = inner_; }
    function read() external view returns (int256, uint256) { return inner.read(); }
}

contract MockSequencer is ISequencerGuard {
    bool public isUp = true;
    uint256 public since;
    constructor() { since = block.timestamp; }
    function set(bool up) external { if (up != isUp) { isUp = up; since = block.timestamp; } }
    function status() external view returns (bool, uint256) { return (isUp, since); }
}

/// TEST ONLY: the "gasleft <= gasBefore/64" guard, to measure its two weaknesses on a real EVM.
contract Heuristic64Feed {
    IFeedSource public immutable source;
    uint64 public invalidSince;
    uint256 public lastGoodPrice = 1;
    error InsufficientGasForExternalCall();

    constructor(IFeedSource s) { source = s; }

    function fetchPrice() external returns (uint256, PriceStatus) {
        uint256 gasBefore = gasleft();
        try source.read() returns (int256 v, uint256) {
            invalidSince = 0;
            lastGoodPrice = uint256(v);
            return (uint256(v), PriceStatus.Valid);
        } catch {
            if (gasleft() <= gasBefore / 64) revert InsufficientGasForExternalCall();
            if (invalidSince == 0) invalidSince = uint64(block.timestamp);
            return (lastGoodPrice, PriceStatus.PriceInvalid);
        }
    }
}
