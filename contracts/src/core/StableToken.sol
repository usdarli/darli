// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {NotAuthorized, InvalidRecipient} from "../Types.sol";

/// @title StableToken
/// @notice ERC-20 + permit for an IMMUTABLE system. The set of addresses that may mint and burn is written ONCE, by the
///         deployer, in `sealMinters`, and can never be extended, reduced or re-opened afterwards: there is no owner, no
///         factory with standing powers, no proxy and no pause. After sealing, the deployer has no rights at all.
contract StableToken is ERC20Permit, IStableToken {
    address public immutable deployer;
    bool public mintersSealed;
    mapping(address => bool) public isMinter;

    event MintersSealed(address[] minters);

    error AlreadySealed();
    error NoMinters();

    constructor(string memory name_, string memory symbol_, address deployer_) ERC20(name_, symbol_) ERC20Permit(name_) {
        deployer = deployer_;
    }

    /// @notice One shot. Wires the branch contracts of this deployment and closes the door for ever.
    function sealMinters(address[] calldata minters) external {
        if (msg.sender != deployer) revert NotAuthorized();
        if (mintersSealed) revert AlreadySealed();
        if (minters.length == 0) revert NoMinters();
        for (uint256 i = 0; i < minters.length; i++) {
            isMinter[minters[i]] = true;
        }
        mintersSealed = true;
        emit MintersSealed(minters);
    }

    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotAuthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotAuthorized();
        _burn(from, amount);
    }

    /// @dev tokens sent to the token contract itself would be lost for ever.
    function _update(address from, address to, uint256 value) internal override {
        if (to == address(this)) revert InvalidRecipient();
        super._update(from, to, value);
    }
}
