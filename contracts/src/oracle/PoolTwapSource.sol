// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFeedSource} from "../interfaces/IPriceFeed.sol";
import {InsufficientGasForOracleCall} from "../Types.sol";
import {CALL_OVERHEAD, ORACLE_GAS_BUFFER} from "../libraries/Constants.sol";
import {PoolTwapMath} from "./PoolTwapMath.sol";

interface IConcentratedPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title PoolTwapSource
/// @notice The pool source of `docs/SPEC.md` O7: the liquidity-weighted median of the time-weighted ETH prices of a fixed
///         set of at most four third-party WETH/stablecoin pools with the Uniswap v3 `observe` oracle (Uniswap v3 and
///         Aerodrome Slipstream on Base). Fixed at construction; nothing can add, remove or reweight a pool. It answers
///         (price, now), or (0, now) when the pools left in hold less than `minDepth` of weight, which the feed reads as
///         unavailable.
/// @dev    Each pool is read with three calls -- `slot0` and `observations` for the time of its last observation,
///         `observe` for the window -- each with a fixed gas stipend, proven affordable up front, copying a fixed
///         number of words: a failing, gas-burning or oversized answer leaves that pool out and nothing else. The
///         whole read runs inside the stipend the feed gives this source (O5), which must cover every call.
///         External calls: the pools, and at construction the stablecoins' `decimals`.
contract PoolTwapSource is IFeedSource {
    uint256 public constant MAX_POOLS = 4;
    bytes4 private constant SLOT0 = 0x3850c7bd; // slot0()
    bytes4 private constant OBSERVATIONS = 0x252c09d7; // observations(uint256)
    bytes4 private constant OBSERVE = 0x883bdbfd; // observe(uint32[])

    address public immutable weth;
    uint32 public immutable window;
    uint256 public immutable poolStaleness;
    uint256 public immutable minDepth;
    uint256 public immutable poolGasLimit;
    uint256 public immutable poolCount;
    address private immutable pool0;
    address private immutable pool1;
    address private immutable pool2;
    address private immutable pool3;
    uint256 private immutable meta0; // bit 8: WETH is token0; low byte: the stablecoin's decimals
    uint256 private immutable meta1;
    uint256 private immutable meta2;
    uint256 private immutable meta3;

    error BadConfig();

    constructor(
        address weth_,
        address[] memory pools_,
        uint32 window_,
        uint256 poolStaleness_,
        uint256 minDepth_,
        uint256 poolGasLimit_
    ) {
        uint256 n = pools_.length;
        if (n == 0 || n > MAX_POOLS || window_ == 0 || poolStaleness_ == 0 || poolGasLimit_ == 0) revert BadConfig();
        address[4] memory p;
        uint256[4] memory m;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (pools_[j] == pools_[i]) revert BadConfig();
            }
            (p[i], m[i]) = (pools_[i], _meta(weth_, pools_[i]));
        }
        weth = weth_;
        window = window_;
        poolStaleness = poolStaleness_;
        minDepth = minDepth_;
        poolGasLimit = poolGasLimit_;
        poolCount = n;
        (pool0, pool1, pool2, pool3) = (p[0], p[1], p[2], p[3]);
        (meta0, meta1, meta2, meta3) = (m[0], m[1], m[2], m[3]);
    }

    /// The orientation and the stablecoin's decimals, read from the pool itself: a WETH/stablecoin pool or nothing.
    function _meta(address weth_, address pool) private view returns (uint256) {
        address t0 = IConcentratedPool(pool).token0();
        address t1 = IConcentratedPool(pool).token1();
        if ((t0 == weth_) == (t1 == weth_)) revert BadConfig();
        uint8 d = IDecimals(t0 == weth_ ? t1 : t0).decimals();
        if (d > 18) revert BadConfig();
        return (t0 == weth_ ? 1 << 8 : 0) | d;
    }

    function pools() external view returns (address[] memory out) {
        address[4] memory p = [pool0, pool1, pool2, pool3];
        out = new address[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            out[i] = p[i];
        }
    }

    function read() external view returns (int256 value, uint256 updatedAt) {
        address[4] memory p = [pool0, pool1, pool2, pool3];
        uint256[4] memory m = [meta0, meta1, meta2, meta3];
        uint256[4] memory prices;
        uint256[4] memory weights;
        uint256 k;
        for (uint256 i = 0; i < poolCount; i++) {
            (bool ok, uint256 price, uint256 weight) = _quote(p[i], m[i]);
            if (ok) {
                (prices[k], weights[k]) = (price, weight);
                k++;
            }
        }
        return (int256(PoolTwapMath.combine(prices, weights, k, minDepth)), block.timestamp);
    }

    /// One pool over the window, or not ok when it must be left out.
    function _quote(address pool, uint256 meta) private view returns (bool, uint256, uint256) {
        // its last observation: the last block in which it traded or its liquidity changed
        (bool ok, bytes32[8] memory w) = _call(pool, abi.encodeWithSelector(SLOT0), 3);
        if (!ok || uint256(w[2]) > type(uint16).max) return (false, 0, 0);
        (ok, w) = _call(pool, abi.encodeWithSelector(OBSERVATIONS, uint256(w[2])), 1);
        if (!ok || uint256(w[0]) > type(uint32).max) return (false, 0, 0);
        uint32 age;
        unchecked {
            age = uint32(block.timestamp) - uint32(uint256(w[0])); // the pools' own 32-bit clock, wrapping
        }
        if (age > poolStaleness) return (false, 0, 0);
        // the window: (int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s), two entries each
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        (ok, w) = _call(pool, abi.encodeWithSelector(OBSERVE, ago), 8);
        if (!ok || uint256(w[0]) != 0x40 || uint256(w[1]) != 0xa0 || uint256(w[2]) != 2 || uint256(w[5]) != 2) {
            return (false, 0, 0);
        }
        int256 tc0 = int256(uint256(w[3]));
        int256 tc1 = int256(uint256(w[4]));
        if (tc0 != int56(tc0) || tc1 != int56(tc1)) return (false, 0, 0);
        if (uint256(w[6]) > type(uint160).max || uint256(w[7]) > type(uint160).max) return (false, 0, 0);
        uint256 spl;
        unchecked {
            spl = uint160(uint256(w[7]) - uint256(w[6])); // the pool's accumulator wraps modulo 2^160
        }
        return PoolTwapMath.quote(tc1 - tc0, spl, window, meta >> 8 == 1, uint8(meta));
    }

    /// @dev A staticcall with a fixed stipend, proven affordable first; copies exactly `words` words of the answer.
    function _call(address target, bytes memory data, uint256 words)
        private
        view
        returns (bool ok, bytes32[8] memory out)
    {
        uint256 stipend = poolGasLimit;
        if (gasleft() < ((stipend + CALL_OVERHEAD) * 64) / 63 + ORACLE_GAS_BUFFER) {
            revert InsufficientGasForOracleCall();
        }
        bool success;
        uint256 returned;
        assembly ("memory-safe") {
            success := staticcall(stipend, target, add(data, 0x20), mload(data), 0, 0)
            returned := returndatasize()
        }
        if (!success || returned < words * 32) return (false, out);
        assembly ("memory-safe") {
            returndatacopy(out, 0, mul(words, 0x20))
        }
        return (true, out);
    }
}
