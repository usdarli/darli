// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {DarliLiquidityVault} from "../src/liquidity/DarliLiquidityVault.sol";

/// SPEC D4: the vault's fixed range, offline. The range is built from par exactly as DarliDeployer initialises the pool,
/// widened to the tick spacing, for either order of the two tokens. The vault on a real pool is tested on a fork
/// (contracts/fork).
contract LiquidityVaultTest is Test {
    address constant PM = address(0x9999);
    address constant REWARD = address(0x8888);
    uint160 constant Q96 = 2 ** 96;

    function _vault(address stable, address quote, uint8 dec, int24 spacing, int24 half)
        internal
        returns (DarliLiquidityVault)
    {
        return new DarliLiquidityVault(IPoolManager(PM), stable, quote, dec, 100, spacing, half, IERC20(REWARD));
    }

    function _checkRange(DarliLiquidityVault v, uint160 par, int24 spacing, int24 half) internal view {
        int24 center = TickMath.getTickAtSqrtPrice(par);
        assertEq(v.tickLower() % spacing, 0, "D4: the range is on the tick spacing");
        assertEq(v.tickUpper() % spacing, 0);
        assertLe(v.tickLower(), center - half, "D4: at least `half` ticks below par");
        assertGe(v.tickUpper(), center + half, "D4: at least `half` ticks above par");
        assertGt(v.tickLower(), center - half - spacing, "D4: widened by less than one spacing");
        assertLt(v.tickUpper(), center + half + spacing + 1);
        assertLe(v.sqrtPriceLower(), par);
        assertGe(v.sqrtPriceUpper(), par, "D4: par is inside the range");
        assertEq(v.sqrtPriceLower(), TickMath.getSqrtPriceAtTick(v.tickLower()));
    }

    function test_theRangeBracketsParForEitherTokenOrderAndAnySpacing() public {
        address low = address(0x1000);
        address high = address(0x2000);
        int24[3] memory spacings = [int24(1), int24(10), int24(60)];
        for (uint256 i = 0; i < 3; i++) {
            int24 sp = spacings[i];
            // USDarli is token0: price = 1e6 / 1e18
            DarliLiquidityVault a = _vault(low, high, 6, sp, 100);
            assertEq(Currency.unwrap(a.currency0()), low);
            _checkRange(a, Q96 / 1e6, sp, 100);
            // USDarli is token1: price = 1e18 / 1e6
            DarliLiquidityVault b = _vault(high, low, 6, sp, 100);
            assertEq(Currency.unwrap(b.currency1()), high);
            _checkRange(b, Q96 * 1e6, sp, 100);
            // an 18-decimal quote: par is 1
            _checkRange(_vault(low, high, 18, sp, 100), Q96, sp, 100);
        }
    }

    function test_inconsistentParametersAreRefused() public {
        vm.expectRevert(DarliLiquidityVault.InvalidConfig.selector);
        _vault(address(0x1000), address(0x1000), 6, 1, 100); // the same token twice
        vm.expectRevert(DarliLiquidityVault.InvalidConfig.selector);
        _vault(address(0x1000), address(0x2000), 8, 1, 100); // decimals the pool price is not built for
        vm.expectRevert(DarliLiquidityVault.InvalidConfig.selector);
        _vault(address(0x1000), address(0x2000), 6, 0, 100);
        vm.expectRevert(DarliLiquidityVault.InvalidConfig.selector);
        _vault(address(0x1000), address(0x2000), 6, 1, 0);
    }
}
