// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DarliToken
/// @notice DARLI (`docs/SPEC.md` V4): a fixed supply, minted once at construction, with no owner, no minting, no burning
///         and no vote. Its only use is to be staked for the protocol's share of revenue. The supply and whom it is minted
///         to are deployment parameters, open until decided (SPEC 13, item 6).
contract DarliToken is ERC20 {
    error NothingToMint();

    constructor(address recipient, uint256 supply) ERC20("Darli", "DARLI") {
        if (supply == 0) revert NothingToMint();
        _mint(recipient, supply);
    }
}
