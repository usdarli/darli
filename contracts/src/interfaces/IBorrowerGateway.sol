// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Every borrower entry point of a branch (implemented by its BranchManager). Risk-increasing effects (debt up,
///         collateral down) go through ONE shared gate whatever the entry point (SPEC B8).
///         The caller is the initiator: collateral comes from the caller, USDarli is burned from the caller only (SPEC
///         10.5), and borrowed USDarli and released collateral go to the caller. `borrow`, `withdrawColl`, `adjustTrove`,
///         `adjustRate` and `closeTrove` need the Trove's owner or an address the owner approved on the TroveNFT; `repay`
///         and `addColl` are open to anyone. Collateral is pulled with `transferFrom`: approve the BranchManager.
interface IBorrowerGateway {
    /// @notice the Trove NFT goes to `owner`; collateral (plus the gas deposit) comes from the caller, the debt goes to
    ///         the caller. `frontendId` 0 means untagged.
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
    /// @notice combined change, checked once at the end; a change that only adds collateral and repays is `addColl`
    ///         followed by `repay`.
    function adjustTrove(uint256 troveId, int256 collChange, int256 debtChange, uint256 maxUpfrontFee) external;
    function adjustRate(uint256 troveId, uint256 newRate, uint256 maxUpfrontFee, uint256 prevHint, uint256 nextHint)
        external;
    /// @notice always allowed while the branch is live; the last open trove of a branch may be short by up to DUST_THRESHOLD.
    function closeTrove(uint256 troveId) external;
}
