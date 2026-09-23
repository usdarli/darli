// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMath} from "../src/libraries/FixedPointMath.sol";
import {WAD, YEAR, MINUTE_DECAY_FACTOR_6H} from "../src/libraries/Constants.sol";

/// Differential tests against model/model.py (vectors: script/export_vectors.py) + rounding properties.
contract FixedPointMathTest is Test {
    string json;

    function setUp() public {
        json = vm.readFile("test/vectors/math.json");
    }

    function test_diff_decPow() public view {
        uint256[] memory b = vm.parseJsonUintArray(json, ".decpow.base");
        uint256[] memory n = vm.parseJsonUintArray(json, ".decpow.exp");
        uint256[] memory o = vm.parseJsonUintArray(json, ".decpow.out");
        assertGt(b.length, 300);
        for (uint256 i = 0; i < b.length; i++) {
            assertEq(FixedPointMath.decPow(b[i], n[i]), o[i], "decPow differs from the reference model");
        }
    }

    function test_decayFactorConstantMatchesModel() public view {
        // exact floor(0.5^(1/360) * 1e18), not the float-rounded ...628800.
        assertEq(vm.parseJsonUint(json, ".decay6h"), MINUTE_DECAY_FACTOR_6H);
    }

    function test_diff_stepA_roundsUp() public view {
        uint256[] memory w = vm.parseJsonUintArray(json, ".stepA.aggW");
        uint256[] memory dt = vm.parseJsonUintArray(json, ".stepA.dt");
        uint256[] memory o = vm.parseJsonUintArray(json, ".stepA.out");
        for (uint256 i = 0; i < w.length; i++) {
            assertEq(FixedPointMath.aggregateInterest(w[i], dt[i]), o[i]);
        }
    }

    function test_diff_stepB_roundsDown() public view {
        uint256[] memory d = vm.parseJsonUintArray(json, ".stepB.debt");
        uint256[] memory r = vm.parseJsonUintArray(json, ".stepB.rate");
        uint256[] memory dt = vm.parseJsonUintArray(json, ".stepB.dt");
        uint256[] memory o = vm.parseJsonUintArray(json, ".stepB.out");
        for (uint256 i = 0; i < d.length; i++) {
            assertEq(FixedPointMath.troveInterest(d[i], r[i], dt[i]), o[i]);
        }
    }

    /// The rounding gap that feeds epsilon (SPEC B1): aggregate (ceil) >= sum of troves (floor), always.
    function testFuzz_aggregateNeverBelowSumOfTroves(uint96 d1, uint96 d2, uint64 r1, uint64 r2, uint32 dt)
        public
        pure
    {
        uint256 rate1 = bound(r1, 1, 25e17);
        uint256 rate2 = bound(r2, 1, 25e17);
        uint256 agg = FixedPointMath.aggregateInterest(uint256(d1) * rate1 + uint256(d2) * rate2, dt);
        uint256 sum = FixedPointMath.troveInterest(d1, rate1, dt) + FixedPointMath.troveInterest(d2, rate2, dt);
        assertGe(agg, sum);
        assertLe(agg - sum, 2, "gap is at most one wei per trove");
    }

    function testFuzz_decPowIsMonotoneAndBounded(uint256 base, uint32 n) public pure {
        base = bound(base, 0, WAD);
        uint256 a = FixedPointMath.decPow(base, n);
        assertLe(a, WAD);
        if (n > 0 && base < WAD) assertLe(FixedPointMath.decPow(base, uint256(n) + 1), a + 1);
    }

    function test_halfLife() public pure {
        uint256 afterSixHours = FixedPointMath.decPow(MINUTE_DECAY_FACTOR_6H, 360);
        assertApproxEqAbs(afterSixHours, WAD / 2, 1e3);
    }
}
