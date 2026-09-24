// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Shared enums, structs and errors. Names follow `docs/SPEC.md` 10.5.

enum PriceStatus {
    Valid,
    NetworkUnstable, // sequencer down or inside the grace period (temporary)
    PriceInvalid, // stale / malformed / skewed answer (temporary)
    Failed // credible oracle failure: the only status that leads to shutdown
}

enum TroveStatus {
    None,
    Active,
    Zombie,
    ClosedByOwner,
    ClosedByLiquidation,
    ClosedBySettlement
}

struct Trove {
    uint256 coll; // normalised to 18 decimals
    uint256 recordedDebt;
    uint256 annualRate; // WAD
    uint256 stake;
    uint256 snapshotLColl; // L_PRECISION
    uint256 snapshotLDebt; // L_PRECISION
    uint64 lastDebtUpdate;
    uint64 lastRateAdjust;
    uint32 frontendId;
    TroveStatus status;
}

struct BranchLedger {
    uint256 aggDebt; // == this branch's share of the token supply (INV-1)
    uint256 aggWeightedDebtSum; // sum(recordedDebt_i * annualRate_i); zero for ever after shutdown
    uint256 badDebt; // part of aggDebt
    uint256 badDebtColl;
    uint64 lastAggUpdate;
    uint64 shutdownAt; // 0 = live
    bool oracleFailed; // latched: the feed is never read again
}

struct LiquidationValues {
    uint256 debtOffset; // X
    uint256 collToSP; // collX
    uint256 debtRemainder; // Y
    uint256 collRemainder; // collY
    uint256 collSurplus;
    uint256 liquidatorBonus;
    bool becameBadDebt;
}

/// What one branch reports to the CollateralRegistry before a redemption (SPEC R1, R3, R4).
struct RedemptionState {
    bool redeemable; // live, both prices Valid, TCR >= SCR
    uint256 price; // decides redeemability: ICR >= 100 %
    uint256 redemptionPrice; // converts debt to collateral
    uint256 unbacked; // aggDebt not covered by the Stability Pool above its residual
    uint256 aggDebt;
}

error NotAuthorized();
error ZeroAmount();
error BranchShutDown();
error PriceNotValid(PriceStatus status);
error InsufficientGasForOracleCall();
error ICRBelowMCR();
error TCRBelowCCR();
error DebtBelowMinimum();
error RepayWouldLeaveDust();
error DebtCapExceeded();
error UpfrontFeeTooHigh(uint256 fee, uint256 maxFee);
error RateOutOfRange();
error RateNotNew();
error TroveNotOpen();
error TroveNotActive();
error RepayInFullWithClose();
error UnknownFrontend(uint32 frontendId);
error WithdrawalNotMatchedByRepayment();
error ShortfallAboveDust();
error TroveNotLiquidatable();
error InvalidRecipient();
error BranchNotShutDown();
error SettlementPhaseOneOpen();
error ClaimOutOfRange();
error CollOutBelowMinimum(uint256 collOut, uint256 minCollOut);
