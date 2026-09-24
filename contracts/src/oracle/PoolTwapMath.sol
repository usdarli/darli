// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title PoolTwapMath
/// @notice `docs/SPEC.md` O7: one pool's time-weighted price and weight over a window, and their liquidity-weighted
///         median. Bit for bit the model's `pool_twap_quote` and `pool_twap_price` (`test_diff_poolTwapMathMatchesModel`).
///         Prices and weights have 18 decimals; WETH is the base, each stablecoin is taken at one dollar.
library PoolTwapMath {
    int256 internal constant MAX_TICK = 887272;

    /// @param tickDelta tickCumulative now minus tickCumulative `window` seconds ago
    /// @param splDelta the same for secondsPerLiquidityCumulativeX128, already reduced modulo 2^160
    /// @return ok false when the pool must be left out (tick out of range, no liquidity record)
    function quote(int256 tickDelta, uint256 splDelta, uint32 window, bool wethIs0, uint8 decimals)
        internal
        pure
        returns (bool ok, uint256 price, uint256 weight)
    {
        int256 w = int256(uint256(window));
        int256 t = tickDelta / w;
        if (tickDelta < 0 && tickDelta % w != 0) t--; // floor, toward minus infinity
        if (!wethIs0) t = -t; // WETH as the base
        if (t > MAX_TICK || t < -MAX_TICK || splDelta == 0) return (false, 0, 0);
        // harmonic mean liquidity over the window
        uint256 liq = (uint256(window) * type(uint160).max) / (splDelta << 32);
        if (liq > type(uint128).max) liq = type(uint128).max;
        uint256 s = TickMath.getSqrtPriceAtTick(int24(t));
        price = FullMath.mulDiv(FullMath.mulDiv(s, s, 1 << 64), 10 ** (36 - decimals), 1 << 128);
        // the pool's virtual stablecoin reserve at that price
        weight = FullMath.mulDiv(liq, s, 1 << 96) * 10 ** (18 - decimals);
        return (true, price, weight);
    }

    /// @return the weighted median of the quotes, or 0 (unavailable) when their weight is below `minDepth`: sorted by
    ///         price, ties kept in the order given, the first price at which the cumulative weight reaches half. Not a
    ///         mean: a price is unbounded, and a pool drained to an extreme tick would move a mean arbitrarily far with
    ///         almost no weight.
    function combine(uint256[4] memory prices, uint256[4] memory weights, uint256 n, uint256 minDepth)
        internal
        pure
        returns (uint256)
    {
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += weights[i];
        }
        if (total < minDepth || total == 0) return 0;
        // insertion sort by price, stable: at most four entries
        for (uint256 i = 1; i < n; i++) {
            (uint256 p, uint256 w) = (prices[i], weights[i]);
            uint256 j = i;
            while (j > 0 && prices[j - 1] > p) {
                (prices[j], weights[j]) = (prices[j - 1], weights[j - 1]);
                j--;
            }
            (prices[j], weights[j]) = (p, w);
        }
        uint256 acc;
        for (uint256 i = 0; i < n; i++) {
            acc += weights[i];
            if (2 * acc >= total) return prices[i];
        }
        return 0; // unreachable: the cumulative weight reaches the total
    }
}
