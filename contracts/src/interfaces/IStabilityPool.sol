// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IStabilityPool {
    /// @notice allowed after shutdown too (liquidation capacity); runs step A of the branch first.
    function deposit(uint256 amount) external;
    /// @notice never blocked, never needs a price.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);
    function claim() external returns (uint256 coll, uint256 yield);

    // --- only the branch ---
    function offset(uint256 debt, uint256 coll) external;
    function creditYield(uint256 amount) external;

    function totalDeposits() external view returns (uint256);
    function compoundedDeposit(address depositor) external view returns (uint256);
    function pendingColl(address depositor) external view returns (uint256);
    function pendingYield(address depositor) external view returns (uint256);
}
