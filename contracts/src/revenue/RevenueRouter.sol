// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IInterestEscrow, IInterestRouter, IDarliStaking} from "../interfaces/ICore.sol";

/// @title RevenueRouter
/// @notice The protocol's share of interest and loan fees reaches DARLI stakers here (`docs/SPEC.md` V3): anyone may move
///         whatever sits in the interest escrow to the staking contract, which streams it over the next epoch. There is no
///         destination to choose, no list, no vote and no discretion: the escrow and the staking contract are fixed at
///         construction, and nothing here can change them.
/// @dev    `route_revenue` in `model/model.py`. External calls: the escrow (pull), the stablecoin (transfer) and the staking
///         contract (notify), all of this deployment.
contract RevenueRouter is IInterestRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public immutable stable;
    IInterestEscrow public immutable escrow;
    IDarliStaking public immutable staking;

    event RevenueRouted(uint256 amount);

    error ZeroAddress();

    constructor(IERC20 stable_, IInterestEscrow escrow_, IDarliStaking staking_) {
        if (address(stable_) == address(0) || address(escrow_) == address(0) || address(staking_) == address(0)) {
            revert ZeroAddress();
        }
        stable = stable_;
        escrow = escrow_;
        staking = staking_;
    }

    function routeRevenue() external nonReentrant returns (uint256 amount) {
        amount = stable.balanceOf(address(escrow));
        if (amount == 0) return 0;
        escrow.pull(amount);
        stable.safeTransfer(address(staking), amount);
        staking.notifyReward(amount);
        emit RevenueRouted(amount);
    }
}
