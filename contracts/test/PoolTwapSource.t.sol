// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolTwapSource} from "../src/oracle/PoolTwapSource.sol";
import {PoolTwapMathHarness} from "./OracleTrace.t.sol";
import {MockDecimals, MockV3Pool} from "./mocks/OracleMocks.sol";

/// SPEC O7 at the pool level: which pools are left out (stale, reverting, burning their stipend, answering in the
/// wrong shape), the depth floor, both token orders, and the configurations refused at construction. The arithmetic
/// itself is checked against the model in OracleTrace.t.sol and on real pools on a fork.
contract PoolTwapSourceTest is Test {
    uint32 constant W = 1800;
    uint256 constant STALE = 1 hours;
    uint256 constant GAS = 100_000;
    int24 constant TICK_2000 = -200_311; // about 2,000 dollars, WETH token0, 6-decimal stablecoin

    address weth = address(new MockDecimals(18));
    address usdc = address(new MockDecimals(6));
    address dai = address(new MockDecimals(18));
    PoolTwapMathHarness math = new PoolTwapMathHarness();
    MockV3Pool deep;
    MockV3Pool flipped;
    MockV3Pool thin;
    PoolTwapSource source;

    function setUp() public {
        vm.warp(1_700_000_000);
        deep = new MockV3Pool(weth, usdc);
        deep.setSteady(TICK_2000, 1e18, W);
        flipped = new MockV3Pool(usdc, weth); // the stablecoin is token0: the tick is negated
        flipped.setSteady(-TICK_2000 - 30, 5e17, W);
        thin = new MockV3Pool(weth, dai);
        thin.setSteady(79_000, 1e9, W); // far off, and a trillionth of the liquidity
        address[] memory p = new address[](3);
        (p[0], p[1], p[2]) = (address(deep), address(flipped), address(thin));
        source = new PoolTwapSource(weth, p, W, STALE, 1e20, GAS);
    }

    function _q(MockV3Pool pool, bool wethIs0, uint8 d) internal view returns (uint256 price, uint256 weight) {
        int256 tickDelta = int256(pool.tcNow()) - int256(pool.tcAgo());
        uint256 spl = uint256(pool.splNow()) - uint256(pool.splAgo());
        (, price, weight) = math.quote(tickDelta, spl, W, wethIs0, d);
    }

    function _expect(bool useDeep, bool useFlipped, bool useThin, uint256 minDepth) internal view returns (uint256) {
        uint256[4] memory p;
        uint256[4] memory w;
        uint256 k;
        if (useDeep) {
            (p[k], w[k]) = _q(deep, true, 6);
            k++;
        }
        if (useFlipped) {
            (p[k], w[k]) = _q(flipped, false, 6);
            k++;
        }
        if (useThin) {
            (p[k], w[k]) = _q(thin, true, 18);
            k++;
        }
        return math.combine(p, w, k, minDepth);
    }

    function _read() internal view returns (uint256 v) {
        (int256 value, uint256 t) = source.read();
        assertEq(t, block.timestamp, "O7: the pools' average is always current");
        return uint256(value);
    }

    function test_aPoolIsLeftOutWhenStaleOrFailingAndTheDepthFloorHolds() public {
        uint256 all = _read();
        assertEq(all, _expect(true, true, true, 1e20), "O7: the liquidity-weighted mean of every pool");
        // the thin pool holds a billionth of the others' liquidity, at about 2,700 dollars against 2,000; the deep pool
        // holds two thirds of the weight, so the median is its price, exactly
        (uint256 deepPrice, uint256 deepWeight) = _q(deep, true, 6);
        (, uint256 thinWeight) = _q(thin, true, 18);
        assertLt(thinWeight * 1e8, deepWeight, "the thin pool is thin");
        assertEq(all, deepPrice, "O7: a thin pool far away moves the median by nothing");
        assertGt(all, 1_900e18);
        assertLt(all, 2_100e18);
        // stale: its last observation is older than POOL_STALENESS
        vm.warp(block.timestamp + STALE + 1);
        deep.setLastObservation(uint32(block.timestamp));
        thin.setLastObservation(uint32(block.timestamp));
        assertEq(_read(), _expect(true, false, true, 1e20), "O7: a stale pool is left out");
        // failing, in each way a call can fail: the rest still answer
        flipped.setLastObservation(uint32(block.timestamp));
        uint256[3] memory modes = [uint256(1), 2, 3];
        for (uint256 i = 0; i < 3; i++) {
            thin.setMode(modes[i]);
            assertEq(_read(), _expect(true, true, false, 1e20), "O7: a failing pool is left out, nothing else");
        }
        thin.setMode(0);
        // the depth floor: without the two deep pools the thin one alone is below it
        deep.setMode(1);
        flipped.setMode(2);
        assertEq(_read(), 0, "O7: below MIN_DEPTH the source is unavailable");
    }

    function test_theConfigurationIsReadFromThePoolsAndBadOnesAreRefused() public {
        address[] memory p = source.pools();
        assertEq(p.length, 3);
        address[] memory bad = new address[](1);
        bad[0] = address(new MockV3Pool(usdc, dai)); // no WETH in it
        vm.expectRevert(PoolTwapSource.BadConfig.selector);
        new PoolTwapSource(weth, bad, W, STALE, 0, GAS);
        bad[0] = address(new MockV3Pool(weth, address(new MockDecimals(19))));
        vm.expectRevert(PoolTwapSource.BadConfig.selector);
        new PoolTwapSource(weth, bad, W, STALE, 0, GAS);
        address[] memory twice = new address[](2);
        (twice[0], twice[1]) = (address(deep), address(deep));
        vm.expectRevert(PoolTwapSource.BadConfig.selector);
        new PoolTwapSource(weth, twice, W, STALE, 0, GAS);
        address[] memory five = new address[](5);
        vm.expectRevert(PoolTwapSource.BadConfig.selector);
        new PoolTwapSource(weth, five, W, STALE, 0, GAS);
        address[] memory one = new address[](1);
        one[0] = address(deep);
        vm.expectRevert(PoolTwapSource.BadConfig.selector);
        new PoolTwapSource(weth, one, 0, STALE, 0, GAS);
    }
}
