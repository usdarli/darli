// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IDarliStaking} from "../interfaces/ICore.sol";
import {NotAuthorized, ZeroAmount} from "../Types.sol";

/// @title DarliStaking
/// @notice DARLI stakers receive the protocol's share of revenue, pro rata to stake (`docs/SPEC.md` V4, V5). Fixed weekly
///         epochs: whatever is handed over during epoch k waits and is streamed, second by second, over epoch k + 1 at a
///         rate fixed at the boundary. A later hand-over never touches an earlier schedule, so nothing -- not a one-wei
///         hand-over every hour -- can postpone a payout: everything handed over by time T is streamed by the end of the
///         following epoch. Time with no stake rolls into the next epoch. Stake and unstake move DARLI and call nothing
///         else; what was earned stays claimable after unstaking.
/// @dev    A line-by-line port of `StreamingStaking` and `EpochStream` in `model/model.py`, replayed against it wei for
///         wei (`test_diff_stakingMatchesModel`). Amounts in the stream are scaled by PREC. External calls: the two tokens.
///         `_accrue` walks one turn per epoch boundary crossed; while the stream has anything to pay that is one turn per
///         week elapsed, and none once it is empty.
contract DarliStaking is IDarliStaking, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant PERIOD = 7 days;
    uint256 public constant PREC = 1e36;

    IERC20 public immutable darli;
    IERC20 public immutable reward; // USDarli
    address public immutable router; // the only address that hands revenue over
    uint256 public immutable t0; // the first epoch starts at deployment

    // the stream (EpochStream)
    uint256 public last;
    uint256 public rate; // per second, scaled by PREC
    uint256 public queued; // waits for the next boundary
    uint256 public idle; // streamed while nobody staked: joins the next epoch

    // the stakers
    uint256 public totalStaked;
    uint256 public rewardPerToken; // scaled by PREC
    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public earned;

    event Staked(address indexed who, uint256 amount);
    event Unstaked(address indexed who, uint256 amount);
    event Claimed(address indexed who, uint256 amount);
    event RewardQueued(uint256 amount);

    error ZeroAddress();
    error UnstakeExceedsStake();

    struct Stream {
        uint256 last;
        uint256 rate;
        uint256 queued;
        uint256 idle;
    }

    constructor(IERC20 darli_, IERC20 reward_, address router_) {
        if (address(darli_) == address(0) || address(reward_) == address(0) || router_ == address(0)) {
            revert ZeroAddress();
        }
        darli = darli_;
        reward = reward_;
        router = router_;
        t0 = block.timestamp;
        last = block.timestamp;
    }

    // --- stakers ------------------------------------------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        stakeOf[msg.sender] += amount;
        totalStaked += amount;
        darli.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Never blocked by anything but the caller's own stake: no price, no permission, no call beyond DARLI.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _update(msg.sender);
        if (stakeOf[msg.sender] < amount) revert UnstakeExceedsStake();
        stakeOf[msg.sender] -= amount;
        totalStaked -= amount;
        darli.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _update(msg.sender);
        amount = earned[msg.sender];
        earned[msg.sender] = 0;
        reward.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // --- the router ---------------------------------------------------------------------------------------------------

    /// @notice only the RevenueRouter, after it has transferred `amount` here: queued for the next epoch.
    function notifyReward(uint256 amount) external nonReentrant {
        if (msg.sender != router) revert NotAuthorized();
        _update(address(0));
        queued += amount * PREC; // no earlier schedule is touched
        emit RewardQueued(amount);
    }

    // --- views --------------------------------------------------------------------------------------------------------

    /// @notice what `who` could claim now.
    function earnedOf(address who) external view returns (uint256) {
        (uint256 inc,) = _accrue();
        return earned[who] + stakeOf[who] * (rewardPerToken + inc - paid[who]) / PREC;
    }

    /// @notice scaled amount not yet streamed now: the rest of the running epoch and what waits for the next one.
    function unstreamed() external view returns (uint256) {
        (, Stream memory s) = _accrue();
        return s.rate * (s.rate != 0 ? _epochEnd(s.last) - s.last : 0) + s.queued + s.idle;
    }

    // --- internals ----------------------------------------------------------------------------------------------------

    function _update(address who) internal {
        (uint256 inc, Stream memory s) = _accrue();
        (last, rate, queued, idle) = (s.last, s.rate, s.queued, s.idle);
        rewardPerToken += inc;
        if (who != address(0)) {
            earned[who] += stakeOf[who] * (rewardPerToken - paid[who]) / PREC;
            paid[who] = rewardPerToken;
        }
    }

    function _epochEnd(uint256 t) internal view returns (uint256) {
        return t0 + ((t - t0) / PERIOD + 1) * PERIOD;
    }

    /// The stream advanced to now, and the reward per staked token it adds. `totalStaked` is constant over the interval:
    /// every change of stake runs `_update` first.
    function _accrue() internal view returns (uint256 inc, Stream memory s) {
        s = Stream(last, rate, queued, idle);
        uint256 total = totalStaked;
        while (s.last < block.timestamp) {
            uint256 end = _epochEnd(s.last);
            if (end > block.timestamp) end = block.timestamp;
            uint256 streamed = s.rate * (end - s.last);
            if (total != 0) {
                inc += streamed / total;
            } else {
                s.idle += streamed;
            }
            s.last = end;
            if ((end - t0) % PERIOD == 0) {
                // boundary: what waited, and what nobody was staked to receive, is the next epoch's
                uint256 tot = s.queued + s.idle;
                s.rate = tot / PERIOD;
                s.queued = tot - s.rate * PERIOD;
                s.idle = 0;
            }
            if (s.rate == 0 && s.queued == 0 && s.idle == 0) {
                s.last = block.timestamp;
            }
        }
    }
}
