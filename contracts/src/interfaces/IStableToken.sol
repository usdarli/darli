// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStableToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    /// @notice one shot, deployer only: fixes the minter set for ever (immutable system).
    function sealMinters(address[] calldata minters) external;
    function mintersSealed() external view returns (bool);
    function isMinter(address account) external view returns (bool);
}
