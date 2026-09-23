// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Trove, BranchLedger, LiquidationValues, PriceStatus, RedemptionState} from "../Types.sol";
import {IStableToken} from "./IStableToken.sol";

/// @notice One branch: its two debt ledgers, its Troves and its shutdown triggers (SPEC §4, §6.5). The borrower entry
///         points of `IBorrowerGateway` are implemented by the same contract, so every ledger change and the checks that
///         guard it sit in one place.
interface IBranchManager {
    // --- permissionless ---
    /// @notice step A, then step B on one Trove; a Zombie whose debt is back at the minimum rejoins the queue (SPEC B4).
    function applyPendingDebt(uint256 troveId) external;
    /// @notice observation that may latch Failed and shut the branch down; never reverts because of the feed.
    function pokeOracle() external returns (PriceStatus);
    /// @notice records a shutdown if any trigger holds (SPEC L6); never reverts because of the feed.
    function triggerShutdown() external;

    // --- only this branch's Stability Pool: yield up to now belongs to the depositors of now ---
    function mintAggInterest() external returns (uint256 minted);

    // --- only this branch's TroveNFT: step B before ownership changes, so the old owner keeps what accrued (SPEC B1) ---
    function onTroveTransfer(uint256 troveId) external;

    // --- views ---
    /// @notice the stablecoin this branch mints; fixed at construction, and checked by the deployer before the minter
    ///         set is sealed (SPEC D1).
    function stable() external view returns (IStableToken);
    function ledger() external view returns (BranchLedger memory);
    function getTrove(uint256 troveId) external view returns (Trove memory);
    function troveDebt(uint256 troveId) external view returns (uint256);
    function troveColl(uint256 troveId) external view returns (uint256);
    function pendingAggInterest() external view returns (uint256);
    function lastZombieTroveId() external view returns (uint256);
    function debtCap() external view returns (uint256);
}

/// @notice SPEC §6.2–§6.4.
interface ILiquidations {
    function liquidate(uint256 troveId) external returns (LiquidationValues memory);
    function claimSurplus() external returns (uint256);
}

/// @notice SPEC §5, the part inside one branch. Routed by the CollateralRegistry.
interface IBranchRedemption {
    /// @notice the prices, the debt and the part of it the Stability Pool does not cover; `redeemable` is false after a
    ///         shutdown, without a Valid price or below SCR. Reads the feed and records nothing.
    function redemptionState() external returns (RedemptionState memory);
    /// @notice only the CollateralRegistry.
    function redeemFromBranch(
        address redeemer,
        uint256 amount,
        uint256 price,
        uint256 redemptionPrice,
        uint256 feeRate,
        uint256 maxIterations
    ) external returns (uint256 redeemed, uint256 collOut);
    function collateralRegistry() external view returns (address);
}

/// @notice SPEC §9: staged settlement after a shutdown; all permissionless.
interface ISettlement {
    /// @notice phase 1: settles one Trove at the reference price fixed at shutdown; pays the caller the Trove's remaining gas deposit (X2).
    function settleTrove(uint256 troveId) external returns (uint256 debt, uint256 contribution, uint256 surplus);
    /// @notice at most MAX_SETTLE_BATCH Troves per call (X3).
    function settleTroves(uint256[] calldata troveIds) external;
    /// @notice after WRITE_OFF_DELAY: counts an unsettled Trove as a claim with zero collateral for now, so phase 1 can end (X5).
    function writeOff(uint256 troveId) external;
    /// @notice phase 2: burns `amount`, registers claim units even when the pot is empty, pays the common rate plus any late share (X8).
    function redeemBadDebtColl(uint256 amount, uint256 minCollOut) external returns (uint256 collOut);
    /// @notice same with an empty pot (live-branch dust case, SPEC L5).
    function repayBadDebt(uint256 amount) external;
    /// @notice whatever written-off Troves handed over after phase 1, for the caller's exercised claim units (X9).
    function claimLate() external returns (uint256 collOut);
}
