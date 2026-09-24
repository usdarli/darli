// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// SPEC §6.1. One pool per branch.
interface IStabilityPool {
    /// @notice only while the branch is live (SP1); runs step A of the branch first, so yield minted before the
    ///         deposit goes to the depositors of before.
    function deposit(uint256 amount) external;
    /// @notice never blocked, never needs a price (SP1, B9); withdraws at most the compounded deposit.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);
    /// @notice pays the collateral gains and the yield settled so far.
    function claim() external returns (uint256 coll, uint256 yield);

    // --- only the branch ---
    /// @notice the pool absorbs `debt` and receives `coll`; the branch transfers the collateral first and burns the
    ///         absorbed USDarli from the pool afterwards.
    function offset(uint256 debt, uint256 coll) external;
    /// @notice the branch has minted `amount` to the pool.
    function creditYield(uint256 amount) external;

    function totalDeposits() external view returns (uint256);
    function compoundedDeposit(address depositor) external view returns (uint256);
    /// @notice gains not yet settled into the claimable balances.
    function pendingColl(address depositor) external view returns (uint256);
    function pendingYield(address depositor) external view returns (uint256);
    /// @notice gains settled at the depositor's last interaction and not yet claimed.
    function claimableColl(address depositor) external view returns (uint256);
    function claimableYield(address depositor) external view returns (uint256);
}
