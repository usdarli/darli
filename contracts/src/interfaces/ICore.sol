// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// SPEC §5: one entry point for every branch of a system. No owner, no setter: the branches, β and the initial base
/// rate are fixed at construction.
interface ICollateralRegistry {
    /// @notice burns up to `amount` of the caller's USDarli, routed across the redeemable branches (R3), for their
    ///         collateral at the fee rate fixed before redeeming (R5). Reverts if that rate is above `maxFeeRate`, if no
    ///         branch is redeemable, or if `amount` exceeds the caller's balance (SPEC 10.5).
    function redeem(uint256 amount, uint256 maxIterationsPerBranch, uint256 maxFeeRate)
        external
        returns (uint256 redeemed);
    /// @notice the fee rate a redemption of `amount` would pay now.
    function redemptionFeeRate(uint256 amount) external view returns (uint256);
    /// @notice the stored base rate, before decay.
    function baseRate() external view returns (uint256);
    function lastFeeOperationTime() external view returns (uint256);
    function branchCount() external view returns (uint256);
}

/// Custody of one branch's collateral. Only its BranchManager moves it, and every movement is accounted.
interface ICollateralVault {
    /// @notice collateral moved in or out by the protocol itself; INV-4: accountedColl == sum of named accounts.
    function accountedColl() external view returns (uint256);
    /// @notice only the manager, after it has transferred `amount` in.
    function accountIn(uint256 amount) external;
    /// @notice only the manager.
    function send(address to, uint256 amount) external;
    /// @dev There is no skim: collateral sent straight to the vault belongs to nobody and stays outside every ledger (SPEC B12).
}

interface IInterestEscrow {
    /// @notice only the InterestRouter.
    function pull(uint256 amount) external;
}

/// SPEC V3: the escrow's balance to the staking contract fixed at construction; permissionless, no destination.
interface IInterestRouter {
    function routeRevenue() external returns (uint256 amount);
}

/// SPEC V4, V5.
interface IDarliStaking {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claim() external returns (uint256);
    /// @notice only the router, after transferring `amount`: queued for the next epoch.
    function notifyReward(uint256 amount) external;
    function earnedOf(address who) external view returns (uint256);
}

/// SPEC V1, V2. Shared by every branch of a system; a caller counts as a branch exactly when it is a minter of the stablecoin.
interface IFrontendRegistry {
    function register(address payout, uint256 kickbackRate) external returns (uint32 frontendId);
    /// @notice only the frontend's payout address; the kickback can only rise.
    function increaseKickback(uint32 frontendId, uint256 newRate) external;
    function claim() external returns (uint256);
    /// @notice only branches, at mint time: the registry's part of `amount`, rounded UP so deposits always cover credits.
    function recordDeposit(uint256 amount) external returns (uint256 part);
    /// @notice only branches; called in step B with (accrued interest + upfront fee). Rounds DOWN.
    function credit(uint32 frontendId, address troveOwner, uint256 amount) external;
    function claimable(address account) external view returns (uint256);
    /// @notice ids 1 .. count() - 1 are registered; 0 is "untagged": the share goes to the Trove's owner.
    function count() external view returns (uint32);
}

/// One ERC-721 per branch. Minted and burned only by the branch; every transfer runs step B first.
interface ITroveNFT {
    function mint(address to, uint256 troveId) external;
    function burn(uint256 troveId) external;
    function ownerOf(uint256 troveId) external view returns (address);
    /// @notice the owner, or an address the owner approved for this Trove or for all of its Troves.
    function isOwnerOrApproved(address account, uint256 troveId) external view returns (bool);
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
