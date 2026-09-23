// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Code constants of `docs/SPEC.md` 2. Identical on every deployment.
uint256 constant WAD = 1e18;
uint256 constant YEAR = 365 days;

// Stability Pool (6.4)
uint256 constant P_PRECISION = 1e36;
uint256 constant SCALE_FACTOR = 1e9;
uint256 constant P_FLOOR = 1e27;
uint256 constant MAX_SCALE_DIFF = 8;
uint256 constant MIN_SP_RESIDUAL = 1e18;
uint256 constant MAX_SP_DEPOSITS = 1e30;

// Redistribution accumulators (6.2)
uint256 constant L_PRECISION = 1e36;

// Borrowing (4.3, 4.5)
uint256 constant UPFRONT_FEE_PERIOD = 7 days; // the upfront fee is this much interest at the branch average rate
uint256 constant RATE_ADJUST_COOLDOWN = 7 days; // a rate change sooner than this after the last one pays the upfront fee
uint256 constant DEBT_CAP_PERIOD = 30 days; // the built-in cap doubles at most once per period

uint256 constant DUST_THRESHOLD = 1e12;
uint256 constant MAX_BRANCHES_PER_SYSTEM = 10;
uint256 constant REWARD_STREAM_PERIOD = 7 days;

// Redemption fee decay (5): exponent is capped so decPow cannot run unbounded.
uint256 constant MAX_DECAY_MINUTES = 525_600_000;
// floor(0.5^(1/360) * 1e18): six-hour half-life, per minute. Checked against the reference model.
uint256 constant MINUTE_DECAY_FACTOR_6H = 998076443575628738;

// Oracle call guard (7)
uint256 constant CALL_OVERHEAD = 2_600;
uint256 constant ORACLE_GAS_BUFFER = 20_000;
