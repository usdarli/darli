// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Every borrower entry point. Risk-increasing effects (debt up, collateral down) go through ONE shared
///         gate `_requireRiskIncreaseAllowed(debtUp, collDown)` whatever the entry point (whitepaper 10.4).
interface IBorrowerGateway {
    function openTrove(
        address owner,
        uint256 coll,
        uint256 debt,
        uint256 annualRate,
        uint32 frontendId,
        uint256 maxUpfrontFee,
        uint256 prevHint,
        uint256 nextHint
    ) external returns (uint256 troveId);
    function addColl(uint256 troveId, uint256 amount) external;
    function withdrawColl(uint256 troveId, uint256 amount) external;
    function borrow(uint256 troveId, uint256 amount, uint256 maxUpfrontFee) external;
    function repay(uint256 troveId, uint256 amount) external;
    /// @notice combined change, checked once at the end; the four single functions are special cases.
    function adjustTrove(uint256 troveId, int256 collChange, int256 debtChange, uint256 maxUpfrontFee) external;
    function adjustRate(uint256 troveId, uint256 newRate, uint256 maxUpfrontFee, uint256 prevHint, uint256 nextHint)
        external;
    /// @notice always allowed; the last open trove of a branch may be short by up to DUST_THRESHOLD.
    function closeTrove(uint256 troveId) external;
}
