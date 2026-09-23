// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Trove, BranchLedger, LiquidationValues, PriceStatus} from "../Types.sol";

/// @notice Branch + trove ledgers, liquidation, in-branch redemption, bad debt, shutdown and staged settlement (SPEC §4, §5, §6, §9).
interface IBranchManager {
    // --- permissionless ---
    function liquidate(uint256 troveId) external returns (LiquidationValues memory);
    function batchLiquidate(uint256[] calldata troveIds) external;
    function applyPendingDebt(uint256 troveId) external;
    // --- staged settlement after a shutdown (SPEC §9); all permissionless ---
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
    /// @notice observation that may latch Failed; never reverts because of the feed.
    function pokeOracle() external returns (PriceStatus);
    /// @notice records a shutdown if any trigger holds; never reverts.
    function triggerShutdown() external;

    // --- only CollateralRegistry ---
    function redeemFromBranch(
        address redeemer,
        uint256 amount,
        uint256 price,
        uint256 redemptionPrice,
        uint256 feeRate,
        uint256 maxIterations
    ) external returns (uint256 redeemed, uint256 collOut);

    // --- only BorrowerGateway: step A + step B of whitepaper 4.2 ---
    function mintAggInterest() external returns (uint256 minted);
    function touchTrove(uint256 troveId, int256 debtChange, uint256 fee, uint256 newRate, int256 collChange)
        external
        returns (uint256 accrued, uint256 redistributed);

    // --- views ---
    function ledger() external view returns (BranchLedger memory);
    function getTrove(uint256 troveId) external view returns (Trove memory);
    function troveDebt(uint256 troveId) external view returns (uint256);
    function troveColl(uint256 troveId) external view returns (uint256);
    function pendingAggInterest() external view returns (uint256);
    function lastZombieTroveId() external view returns (uint256);
    function unbackedSupply() external view returns (uint256);
}
