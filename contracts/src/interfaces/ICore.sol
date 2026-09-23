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

/// The redemption queue of one branch (SPEC R2): Active Troves in a doubly linked list, head = highest (rate, id), tail =
/// lowest. Redemption walks `last()` then `prev()`, i.e. lowest rate first and, among equal rates, the lower id first.
/// (rate, id) is a total order, so the list has exactly one valid state for a given set: hints decide only the gas.
interface IRateSortedList {
    /// @notice only the branch. Reverts if `id` is 0 or already listed. Any hints are accepted; exact ones cost O(1).
    function insert(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint) external;
    /// @notice only the branch. O(1): no walk, no hint.
    function remove(uint256 id) external;
    /// @notice only the branch. `remove` then `insert`.
    function reinsert(uint256 id, uint256 newRate, uint256 prevHint, uint256 nextHint) external;
    /// @notice the neighbours `id` would have at `annualRate`: prevId nearer the head (ranks higher), nextId nearer the
    ///         tail. For a listed `id`, the answer describes the list as it stands, `id` included.
    function findInsertPosition(uint256 id, uint256 annualRate, uint256 prevHint, uint256 nextHint)
        external
        view
        returns (uint256 prevId, uint256 nextId);
    function first() external view returns (uint256);
    function last() external view returns (uint256);
    function next(uint256 id) external view returns (uint256);
    function prev(uint256 id) external view returns (uint256);
    function size() external view returns (uint256);
    function contains(uint256 id) external view returns (bool);
    function rateOf(uint256 id) external view returns (uint256);
}
