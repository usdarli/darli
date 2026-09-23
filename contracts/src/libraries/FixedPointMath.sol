// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD, MAX_DECAY_MINUTES} from "./Constants.sol";

/// @title FixedPointMath
/// @notice Every rounding direction used by the core is explicit here. The reference model
///         (`model/model.py`) is the oracle for these functions: see test/FixedPointMath.t.sol.
library FixedPointMath {
    /// @dev floor(a * b / d), full 512-bit intermediate.
    function mulDivDown(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(a, b, d);
    }

    /// @dev ceil(a * b / d), full 512-bit intermediate.
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(a, b, d, Math.Rounding.Ceil);
    }

    /// @dev ceil(a / b). Reverts on b == 0.
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.ceilDiv(a, b);
    }

    /// @dev WAD multiplication rounded half up. Only used inside decPow.
    function _mulHalfUp(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b + WAD / 2) / WAD;
    }

    /// @notice base^n for a WAD-scaled base <= 1e18, exponentiation by squaring.
    /// @dev Must match `dec_pow` in the reference model bit for bit (differential test).
    function decPow(uint256 base, uint256 n) internal pure returns (uint256) {
        if (n > MAX_DECAY_MINUTES) n = MAX_DECAY_MINUTES;
        if (n == 0) return WAD;
        uint256 y = WAD;
        uint256 x = base;
        while (n > 1) {
            if (n % 2 == 1) y = _mulHalfUp(x, y);
            x = _mulHalfUp(x, x);
            n /= 2;
        }
        return _mulHalfUp(x, y);
    }

    /// @notice Step A of SPEC B1: aggregate interest, rounded UP (in favour of the system).
    function aggregateInterest(uint256 aggWeightedDebtSum, uint256 elapsed) internal pure returns (uint256) {
        return mulDivUp(aggWeightedDebtSum, elapsed, YEAR_TIMES_WAD);
    }

    /// @notice Step B of SPEC B1: interest of one trove, rounded DOWN.
    function troveInterest(uint256 recordedDebt, uint256 annualRate, uint256 elapsed) internal pure returns (uint256) {
        return mulDivDown(recordedDebt * annualRate, elapsed, YEAR_TIMES_WAD);
    }

    uint256 private constant YEAR_TIMES_WAD = 365 days * WAD;
}
