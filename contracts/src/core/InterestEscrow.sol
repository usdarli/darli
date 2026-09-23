// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInterestEscrow} from "../interfaces/ICore.sol";
import {NotAuthorized} from "../Types.sol";

/// @title InterestEscrow
/// @notice Branches mint the incentive/staker part of interest here. The core never calls out: the router PULLS.
///         No logic on purpose (`docs/SPEC.md` 8).
contract InterestEscrow is IInterestEscrow {
    using SafeERC20 for IERC20;

    IERC20 public immutable stable;
    address public immutable router;

    constructor(IERC20 stable_, address router_) {
        stable = stable_;
        router = router_;
    }

    function pull(uint256 amount) external {
        if (msg.sender != router) revert NotAuthorized();
        stable.safeTransfer(router, amount);
    }
}
