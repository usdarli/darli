// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ITroveNFT} from "../interfaces/ICore.sol";
import {IBranchManager} from "../interfaces/IBranchManager.sol";
import {NotAuthorized} from "../Types.sol";

/// @title TroveNFT
/// @notice Ownership of the Troves of one branch (`docs/SPEC.md` 4.1). Only the branch mints and burns. Every transfer
///         first lets the branch run step B on the Trove, so interest and the frontend kickback accrued up to the
///         transfer are credited to the owner who held it (SPEC B1).
contract TroveNFT is ERC721, ITroveNFT {
    address public immutable manager;

    error ManagerIsZero();

    constructor(address manager_, string memory name_, string memory symbol_) ERC721(name_, symbol_) {
        if (manager_ == address(0)) revert ManagerIsZero();
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotAuthorized();
        _;
    }

    function mint(address to, uint256 troveId) external onlyManager {
        _mint(to, troveId); // not _safeMint: the branch never calls into user code
    }

    function burn(uint256 troveId) external onlyManager {
        _burn(troveId);
    }

    function ownerOf(uint256 troveId) public view override(ERC721, ITroveNFT) returns (address) {
        return super.ownerOf(troveId);
    }

    function isOwnerOrApproved(address account, uint256 troveId) external view returns (bool) {
        return _isAuthorized(_requireOwned(troveId), account, troveId);
    }

    /// @dev A transfer between two holders (not a mint, not a burn) settles the Trove before the owner changes.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            IBranchManager(manager).onTroveTransfer(tokenId);
        }
        return super._update(to, tokenId, auth);
    }
}
