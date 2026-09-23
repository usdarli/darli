// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICollateralRegistry {
    function redeem(uint256 amount, uint256 maxIterationsPerBranch, uint256 maxFeeRate, uint256[] calldata minCollOut)
        external
        returns (uint256 redeemed);
    function getRedemptionFeeRate(uint256 amount) external view returns (uint256);
    function baseRate() external view returns (uint256);
}

interface ICollateralVault {
    /// @notice collateral moved by the protocol itself; INV-4: accountedColl == sum of named accounts.
    function accountedColl() external view returns (uint256);
    function claimSurplus() external returns (uint256);
    /// @dev There is no skim: collateral sent straight to the vault belongs to nobody and stays outside every ledger (SPEC B12).
}

interface IInterestEscrow {
    /// @notice only the InterestRouter.
    function pull(uint256 amount) external;
}

interface IInterestRouter {
    /// @notice permissionless: step A on every branch of the system, then split the escrow.
    function syncAndDistribute() external;
}

interface IFrontendRegistry {
    function register(address payout, uint256 kickbackRate) external returns (uint32 frontendId);
    function increaseKickback(uint32 frontendId, uint256 newRate) external;
    function claim() external returns (uint256);
    /// @notice only branches; called inside step B with (accrued interest + upfront fee).
    function credit(uint32 frontendId, address troveOwner, uint256 amount) external;
    function claimable(address account) external view returns (uint256);
}

interface IInitiative {
    /// @notice tokens are already transferred; called with a guaranteed gas stipend inside one atomic self-call.
    function notifyReward(uint256 amount) external;
}

interface IRateSortedList {
    function insert(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint) external;
    function remove(uint256 id) external;
    function reinsert(uint256 id, uint256 newRate, uint256 prevHint, uint256 nextHint) external;
    function findInsertPosition(uint256 annualRate, uint256 prevHint, uint256 nextHint)
        external
        view
        returns (uint256 prev, uint256 next);
    function last() external view returns (uint256);
    function prev(uint256 id) external view returns (uint256);
    function size() external view returns (uint256);
}
