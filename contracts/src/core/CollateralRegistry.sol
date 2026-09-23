// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICollateralRegistry} from "../interfaces/ICore.sol";
import {IBranchRedemption} from "../interfaces/IBranchManager.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {WAD, REDEMPTION_FEE_FLOOR, MINUTE_DECAY_FACTOR_6H, MAX_BRANCHES_PER_SYSTEM} from "../libraries/Constants.sol";
import {RedemptionState, ZeroAmount} from "../Types.sol";

/// @title CollateralRegistry
/// @notice The system's redemption entry point (`docs/SPEC.md` §5). Anyone may redeem USDarli for collateral, at one unit
///         of reference currency per token minus the fee, from every branch that is live, has a Valid price and is at or
///         above SCR (R1). The request is split across those branches in proportion to the debt their Stability Pools do
///         not cover, truncated to that uncovered total, with a running remainder (R3). The fee rate is fixed from the
///         requested amount before redeeming; the stored base rate then follows what was actually redeemed, with the same
///         β (R5).
/// @dev    A line-by-line port of `System.redeem` in `model/model.py`, replayed against it wei for wei
///         (`test_diff_branchTraceMatchesModel`, `test_diff_routingMatchesModel`). Nothing here can be changed after
///         construction: the branch list, β and the initial base rate are immutable in effect, and there is no owner.
///         External calls: the stablecoin (supply and the redeemer's balance, read only) and the branches of this system.
contract CollateralRegistry is ICollateralRegistry, ReentrancyGuardTransient {
    IStableToken public immutable stable;
    /// @notice β scaled by WAD: the fee rises by amount / (supply × β) per redemption (R5). A deployment constant.
    uint256 public immutable betaWad;

    IBranchRedemption[] internal _branches;
    uint256 public baseRate;
    uint256 public lastFeeOperationTime;

    event Redemption(
        address indexed redeemer, uint256 requested, uint256 redeemed, uint256 feeRate, uint256 newBaseRate
    );

    error InvalidConfig();
    error NoRedeemableBranch();
    error NothingToRedeem();
    error FeeRateAboveMax(uint256 feeRate, uint256 maxFeeRate);
    error RequestAboveBalance(uint256 amount, uint256 balance);

    /// @param branches_ every branch of the system, at their final (predicted) addresses; at most MAX_BRANCHES_PER_SYSTEM.
    /// @param initialBaseRate_ the base rate at deployment, decaying from then on (R6: 100 % uncapped, 10 % for the pilot).
    constructor(
        IStableToken stable_,
        IBranchRedemption[] memory branches_,
        uint256 betaWad_,
        uint256 initialBaseRate_
    ) {
        if (
            address(stable_) == address(0) || branches_.length == 0 || branches_.length > MAX_BRANCHES_PER_SYSTEM
                || betaWad_ == 0 || initialBaseRate_ > WAD
        ) {
            revert InvalidConfig();
        }
        for (uint256 i = 0; i < branches_.length; i++) {
            if (address(branches_[i]) == address(0)) revert InvalidConfig();
            _branches.push(branches_[i]);
        }
        stable = stable_;
        betaWad = betaWad_;
        baseRate = initialBaseRate_;
        lastFeeOperationTime = block.timestamp;
    }

    function redeem(uint256 amount, uint256 maxIterationsPerBranch, uint256 maxFeeRate)
        external
        nonReentrant
        returns (uint256 redeemed)
    {
        uint256 supply = stable.totalSupply();
        if (amount == 0 || supply == 0) revert ZeroAmount();
        {
            uint256 balance = stable.balanceOf(msg.sender);
            if (amount > balance) revert RequestAboveBalance(amount, balance);
        }
        (RedemptionState[] memory st, uint256 weight, bool byUnbacked) = _states();
        // by uncovered debt; beyond the uncovered total the proportions would no longer say which branch lacks backing
        if (byUnbacked && amount > weight) amount = weight;
        (uint256 decayed, uint256 minutes_) = _decayedBaseRate();
        uint256 feeRate = _feeRate(decayed, amount, supply);
        if (feeRate > maxFeeRate) revert FeeRateAboveMax(feeRate, maxFeeRate);
        redeemed = _route(st, amount, weight, byUnbacked, feeRate, maxIterationsPerBranch);
        _updateBaseRate(decayed, minutes_, redeemed, supply);
        emit Redemption(msg.sender, amount, redeemed, feeRate, baseRate);
    }

    // --- views ----------------------------------------------------------------------------------------------------------

    function redemptionFeeRate(uint256 amount) external view returns (uint256) {
        (uint256 decayed,) = _decayedBaseRate();
        return _feeRate(decayed, amount, stable.totalSupply());
    }

    function branchCount() external view returns (uint256) {
        return _branches.length;
    }

    function branches(uint256 i) external view returns (IBranchRedemption) {
        return _branches[i];
    }

    // --- internals ------------------------------------------------------------------------------------------------------

    /// The stored rate follows what was actually redeemed, with the β and the supply the fee was computed with, so
    /// asking for more than can be redeemed raises nothing (R5). The clock moves only when a whole minute has passed.
    function _updateBaseRate(uint256 decayed, uint256 minutes_, uint256 redeemed, uint256 supply) internal {
        uint256 newRate = decayed + FixedPointMath.mulDivDown(redeemed, WAD * WAD, supply * betaWad);
        baseRate = newRate < WAD ? newRate : WAD;
        if (minutes_ > 0) lastFeeOperationTime = block.timestamp;
    }

    /// Every branch's state; the weights are the redeemable branches' uncovered debt, or their whole debt when no
    /// redeemable branch has any debt uncovered (R3).
    function _states() internal returns (RedemptionState[] memory st, uint256 weight, bool byUnbacked) {
        uint256 n = _branches.length;
        st = new RedemptionState[](n);
        uint256 sumDebt;
        bool any;
        for (uint256 i = 0; i < n; i++) {
            st[i] = _branches[i].redemptionState();
            if (st[i].redeemable) {
                any = true;
                weight += st[i].unbacked;
                sumDebt += st[i].aggDebt;
            }
        }
        if (!any) revert NoRedeemableBranch();
        byUnbacked = weight != 0;
        if (!byUnbacked) weight = sumDebt;
        if (weight == 0) revert NothingToRedeem();
    }

    /// Each redeemable branch's share of `amount`, computed with a running remainder so the shares add up to it exactly.
    function _route(
        RedemptionState[] memory st,
        uint256 amount,
        uint256 weight,
        bool byUnbacked,
        uint256 feeRate,
        uint256 maxIterations
    ) internal returns (uint256 redeemed) {
        for (uint256 i = 0; i < st.length; i++) {
            if (!st[i].redeemable) continue;
            uint256 w = byUnbacked ? st[i].unbacked : st[i].aggDebt;
            if (w == 0) continue;
            uint256 share = amount * w / weight;
            amount -= share;
            weight -= w;
            if (share == 0) continue;
            (uint256 r,) = _branches[i].redeemFromBranch(
                msg.sender, share, st[i].price, st[i].redemptionPrice, feeRate, maxIterations
            );
            redeemed += r;
        }
    }

    /// baseRate × decay^minutes, rounded down; the exponent is capped inside decPow (R5).
    function _decayedBaseRate() internal view returns (uint256 decayed, uint256 minutes_) {
        minutes_ = (block.timestamp - lastFeeOperationTime) / 60;
        decayed = baseRate * FixedPointMath.decPow(MINUTE_DECAY_FACTOR_6H, minutes_) / WAD;
    }

    /// min(WAD, floor + min(WAD, decayed + amount × WAD² / (supply × β))), from the REQUESTED amount (R5).
    function _feeRate(uint256 decayed, uint256 amount, uint256 supply) internal view returns (uint256) {
        uint256 bumped = decayed + FixedPointMath.mulDivDown(amount, WAD * WAD, supply * betaWad);
        if (bumped > WAD) bumped = WAD;
        uint256 rate = REDEMPTION_FEE_FLOOR + bumped;
        return rate < WAD ? rate : WAD;
    }
}
