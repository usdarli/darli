// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICollateralVault} from "../interfaces/ICore.sol";
import {NotAuthorized} from "../Types.sol";

/// @title CollateralVault
/// @notice Holds one branch's collateral. Only its BranchManager moves it, and `accountedColl` counts exactly what the
///         protocol itself moved in and out (`docs/SPEC.md` B12): the manager's named accounts add up to it. Collateral
///         sent here directly raises the balance but not `accountedColl`; it belongs to nobody, and there is no function
///         that could hand it to anyone.
contract CollateralVault is ICollateralVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable collToken;
    address public immutable manager;
    uint256 public accountedColl;

    error ManagerIsZero();
    error InsufficientBalance(uint256 balance, uint256 accounted);

    constructor(IERC20 collToken_, address manager_) {
        if (manager_ == address(0)) revert ManagerIsZero();
        collToken = collToken_;
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotAuthorized();
        _;
    }

    /// @dev The balance check makes a short transfer in (a fee-on-transfer token, say) a revert rather than an
    ///      accounting hole: every accounted unit is always in the vault.
    function accountIn(uint256 amount) external onlyManager {
        uint256 accounted = accountedColl + amount;
        uint256 balance = collToken.balanceOf(address(this));
        if (balance < accounted) revert InsufficientBalance(balance, accounted);
        accountedColl = accounted;
    }

    function send(address to, uint256 amount) external onlyManager {
        accountedColl -= amount;
        collToken.safeTransfer(to, amount);
    }
}
