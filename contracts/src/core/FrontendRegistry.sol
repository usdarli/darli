// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IFrontendRegistry} from "../interfaces/ICore.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {NotAuthorized, InvalidRecipient, UnknownFrontend} from "../Types.sol";
import {WAD} from "../libraries/Constants.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";

/// @title FrontendRegistry
/// @notice The interfaces' share of interest (`docs/SPEC.md` V1, V2), for every branch of one system. A branch mints the
///         share of each amount here at mint time, rounded UP (`recordDeposit`), and credits the Trove's frontend and
///         owner in step B, rounded DOWN (`credit`), so the balance always covers what is claimable. A caller is a branch
///         exactly when the stablecoin lists it as a minter: the minter set is sealed at deployment, so this registry
///         needs no list of its own and no one who could change it. A Trove opened without a frontend credits the
///         whole share to its owner.
contract FrontendRegistry is IFrontendRegistry {
    struct Frontend {
        address payout;
        uint96 kickback; // WAD; the part of each credit that goes to the Trove's owner; can only rise
    }

    IStableToken public immutable stableToken;
    /// @notice FRONTEND_SHARE of SPEC §2, WAD.
    uint256 public immutable share;

    uint32 public count = 1;
    mapping(uint32 => Frontend) public frontends;
    mapping(address => uint256) public claimable;
    uint256 public totalDeposited;
    uint256 public totalCredited;

    event Registered(uint32 indexed frontendId, address indexed payout, uint256 kickback);
    event KickbackIncreased(uint32 indexed frontendId, uint256 kickback);
    event Claimed(address indexed account, uint256 amount);

    error KickbackOutOfRange();

    constructor(IStableToken stable_, uint256 share_) {
        if (share_ > WAD) revert KickbackOutOfRange();
        stableToken = stable_;
        share = share_;
    }

    modifier onlyBranch() {
        if (!stableToken.isMinter(msg.sender)) revert NotAuthorized();
        _;
    }

    function register(address payout, uint256 kickbackRate) external returns (uint32 frontendId) {
        if (payout == address(0)) revert InvalidRecipient();
        if (kickbackRate > WAD) revert KickbackOutOfRange();
        frontendId = count++;
        frontends[frontendId] = Frontend(payout, uint96(kickbackRate));
        emit Registered(frontendId, payout, kickbackRate);
    }

    function increaseKickback(uint32 frontendId, uint256 newRate) external {
        Frontend storage fe = frontends[frontendId];
        if (msg.sender != fe.payout) revert NotAuthorized();
        if (newRate < fe.kickback || newRate > WAD) revert KickbackOutOfRange();
        fe.kickback = uint96(newRate);
        emit KickbackIncreased(frontendId, newRate);
    }

    function claim() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        claimable[msg.sender] = 0;
        if (amount > 0) {
            stableToken.transfer(msg.sender, amount);
        }
        emit Claimed(msg.sender, amount);
    }

    function recordDeposit(uint256 amount) external onlyBranch returns (uint256 part) {
        part = FixedPointMath.mulDivUp(amount, share, WAD);
        totalDeposited += part;
    }

    function credit(uint32 frontendId, address troveOwner, uint256 amount) external onlyBranch {
        uint256 reward = FixedPointMath.mulDivDown(amount, share, WAD);
        totalCredited += reward;
        if (frontendId == 0) {
            // no frontend brought this Trove (a command-line or self-written client): the whole share is its owner's,
            // exactly as a self-referral with full kickback would be (SPEC V2)
            claimable[troveOwner] += reward;
            return;
        }
        if (frontendId >= count) revert UnknownFrontend(frontendId);
        Frontend memory fe = frontends[frontendId];
        uint256 toOwner = FixedPointMath.mulDivDown(reward, fe.kickback, WAD);
        claimable[troveOwner] += toOwner;
        claimable[fe.payout] += reward - toOwner;
    }
}
