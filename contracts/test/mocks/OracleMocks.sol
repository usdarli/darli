// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeedSource, ISequencerGuard} from "../../src/interfaces/IPriceFeed.sol";
import {PriceStatus} from "../../src/Types.sol";

contract MockSource is IFeedSource {
    enum Mode {
        Ok,
        Revert,
        BurnAllGas,
        ShortReturn
    }

    int256 public value;
    uint256 public updatedAt;
    Mode public mode;
    uint256 public burn; // gas an honest read consumes before answering

    constructor(int256 v, uint256 burn_) {
        value = v;
        updatedAt = block.timestamp;
        burn = burn_;
    }

    function set(int256 v, uint256 t) external {
        value = v;
        updatedAt = t;
    }

    function push() external {
        updatedAt = block.timestamp;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function read() external view returns (int256, uint256) {
        if (mode == Mode.Revert) revert("source down");
        if (mode == Mode.BurnAllGas) while (true) {}
        if (mode == Mode.ShortReturn) {
            // braces are not optional here: `forge fmt` rewrites a braceless `if` with inline assembly and then
            // reports its own output as unformatted, so `forge fmt --check` can never go green without them.
            assembly {
                mstore(0, 1)
                return(0, 0x20)
            }
        }
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return (value, updatedAt);
    }
}

/// proxy -> aggregator: a plain nested call; an inner failure bubbles up as a revert of the proxy,
/// which still owns ~1/64 of ITS gas and hands it back to the caller.
contract NestedProxySource is IFeedSource {
    IFeedSource public immutable inner;

    constructor(IFeedSource inner_) {
        inner = inner_;
    }

    function read() external view returns (int256, uint256) {
        return inner.read();
    }
}

contract MockSequencer is ISequencerGuard {
    bool public isUp = true;
    uint256 public since;

    constructor() {
        since = block.timestamp;
    }

    function set(bool up) external {
        // `since` moves ONLY when the status really changes: the grace period and the failure timeout are both measured
        // from it, so an unconditional update would silently keep the sequencer looking freshly recovered for ever.
        if (up != isUp) {
            isUp = up;
            since = block.timestamp;
        }
    }

    function status() external view returns (bool, uint256) {
        return (isUp, since);
    }
}

/// TEST ONLY: the "gasleft <= gasBefore/64" guard, to measure its two weaknesses on a real EVM.
contract Heuristic64Feed {
    IFeedSource public immutable source;
    uint64 public invalidSince;
    uint256 public lastGoodPrice = 1;
    error InsufficientGasForExternalCall();

    constructor(IFeedSource s) {
        source = s;
    }

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

/// The pool source as the feed sees it: (price, now), 0 when unavailable; or a revert, or a read that burns its stipend.
contract MockPoolSource is IFeedSource {
    uint256 public value;
    bool public available = true;
    uint256 public mode; // 0 ok, 1 revert, 2 burn every gas unit it is given

    constructor(uint256 v) {
        value = v;
    }

    function setValue(uint256 v) external {
        value = v;
    }

    function setAvailable(bool on) external {
        available = on;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function read() external view returns (int256, uint256) {
        if (mode == 1) revert("pools down");
        if (mode == 2) {
            while (true) {}
        }
        return (available ? int256(value) : int256(0), block.timestamp);
    }
}

contract MockDecimals {
    uint8 public immutable decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// A concentrated-liquidity pool's oracle surface (Uniswap v3 / Aerodrome Slipstream): token0/token1, slot0,
/// observations and observe. The test sets the two cumulative readings the window spans and the last observation time.
contract MockV3Pool {
    address public token0;
    address public token1;
    int56 public tcAgo;
    int56 public tcNow;
    uint160 public splAgo;
    uint160 public splNow;
    uint32 public lastObservation;
    uint256 public mode; // 0 ok, 1 revert, 2 burn all gas, 3 a short answer

    constructor(address t0, address t1) {
        (token0, token1) = (t0, t1);
        lastObservation = uint32(block.timestamp);
    }

    /// A pool that sat at `tick` with liquidity `liq` for the whole `window`.
    function setSteady(int24 tick, uint128 liq, uint32 window) external {
        tcAgo = 0;
        tcNow = int56(tick) * int56(uint56(window));
        splAgo = 0;
        splNow = uint160((uint256(window) << 128) / liq);
        lastObservation = uint32(block.timestamp);
    }

    function setLastObservation(uint32 t) external {
        lastObservation = t;
    }

    function setMode(uint256 m) external {
        mode = m;
    }

    function _misbehave() internal view {
        if (mode == 1) revert("pool");
        if (mode == 2) {
            while (true) {}
        }
        if (mode == 3) {
            assembly {
                return(0, 0x20)
            }
        }
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        _misbehave();
        return (0, 0, 7, 10, 10, 0, true);
    }

    function observations(uint256 i) external view returns (uint32, int56, uint160, bool) {
        _misbehave();
        require(i == 7, "index");
        return (lastObservation, tcNow, splNow, true);
    }

    function observe(uint32[] calldata) external view returns (int56[] memory tc, uint160[] memory spl) {
        _misbehave();
        tc = new int56[](2);
        spl = new uint160[](2);
        (tc[0], tc[1], spl[0], spl[1]) = (tcAgo, tcNow, splAgo, splNow);
    }
}
