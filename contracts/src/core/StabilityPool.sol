// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStabilityPool} from "../interfaces/IStabilityPool.sol";
import {IBranchManager} from "../interfaces/IBranchManager.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {
    P_PRECISION,
    SCALE_FACTOR,
    P_FLOOR,
    MAX_SCALE_DIFF,
    MIN_SP_RESIDUAL,
    MAX_SP_DEPOSITS
} from "../libraries/Constants.sol";
import {NotAuthorized, ZeroAmount, BranchShutDown} from "../Types.sol";

/// @title StabilityPool
/// @notice One branch's Stability Pool (`docs/SPEC.md` §6.1): depositors' USDarli absorbs liquidated debt, and they
///         receive the liquidated collateral and a share of the interest. Product/sum accounting: a deposit's value is
///         `amount × P / P_snapshot`, its gains are read from the sums `S` (collateral) and `B` (yield) accumulated per
///         scale. P never reaches zero because an offset always leaves MIN_SP_RESIDUAL in the pool; when it falls below
///         P_FLOOR it is rescaled by 1e9, in a loop, as often as needed (SP2). A deposit is read across MAX_SCALE_DIFF
///         rescalings and no further (SP4 a). The carried remainders `errColl` and `errYield` keep the per-unit sums from
///         losing the division remainder at every offset and credit.
/// @dev    A line-by-line port of `StabilityPool` in `model/model.py`, checked wei for wei against it
///         (`test_diff_stabilityPoolMatchesModel`). External calls: the stablecoin and the collateral token (the
///         deposits and the gains), and the branch (step A before every deposit, withdrawal and claim, and whether it is
///         shut down). The branch burns the absorbed USDarli from this pool after `offset`.
contract StabilityPool is IStabilityPool, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Snapshot {
        uint256 amount; // compounded value at the last interaction
        uint256 p;
        uint256 scale;
        uint256 s;
        uint256 b;
    }

    IERC20 public immutable stable;
    IERC20 public immutable collToken;
    IBranchManager public immutable manager;

    uint256 public totalDeposits;
    uint256 public P = P_PRECISION;
    uint256 public currentScale;
    mapping(uint256 => uint256) public scaleToS; // collateral per unit deposit, P_PRECISION, per scale
    mapping(uint256 => uint256) public scaleToB; // yield per unit deposit, P_PRECISION, per scale
    uint256 public errColl;
    uint256 public errYield;

    mapping(address => Snapshot) public deposits;
    mapping(address => uint256) public claimableColl;
    mapping(address => uint256) public claimableYield;

    event Deposited(address indexed depositor, uint256 amount, uint256 newDeposit);
    event Withdrawn(address indexed depositor, uint256 amount, uint256 newDeposit);
    event Claimed(address indexed depositor, uint256 coll, uint256 yield);
    event Offset(uint256 debt, uint256 coll, uint256 newP, uint256 newScale);

    error DepositDomainExceeded();
    error OffsetOutOfRange(uint256 debt, uint256 total);
    error ManagerIsZero();

    constructor(IERC20 stable_, IERC20 collToken_, IBranchManager manager_) {
        if (address(manager_) == address(0)) revert ManagerIsZero();
        stable = stable_;
        collToken = collToken_;
        manager = manager_;
    }

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotAuthorized();
        _;
    }

    // --- depositors ---------------------------------------------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (manager.ledger().shutdownAt != 0) revert BranchShutDown(); // the pool absorbs nothing after a shutdown
        if (totalDeposits + amount > MAX_SP_DEPOSITS) revert DepositDomainExceeded();
        manager.mintAggInterest(); // yield up to now goes to the existing depositors
        uint256 comp = _settle(msg.sender);
        stable.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposits += amount;
        _snapshot(msg.sender, comp + amount);
        emit Deposited(msg.sender, amount, comp + amount);
    }

    function withdraw(uint256 amount) external nonReentrant returns (uint256) {
        manager.mintAggInterest();
        uint256 comp = _settle(msg.sender);
        if (amount > comp) amount = comp;
        stable.safeTransfer(msg.sender, amount);
        totalDeposits -= amount;
        _snapshot(msg.sender, comp - amount);
        emit Withdrawn(msg.sender, amount, comp - amount);
        return amount;
    }

    function claim() external nonReentrant returns (uint256 coll, uint256 yield) {
        manager.mintAggInterest();
        uint256 comp = _settle(msg.sender);
        _snapshot(msg.sender, comp);
        coll = claimableColl[msg.sender];
        yield = claimableYield[msg.sender];
        claimableColl[msg.sender] = 0;
        claimableYield[msg.sender] = 0;
        collToken.safeTransfer(msg.sender, coll);
        stable.safeTransfer(msg.sender, yield);
        emit Claimed(msg.sender, coll, yield);
    }

    // --- the branch -----------------------------------------------------------------------------------------------------

    function creditYield(uint256 amount) external onlyManager {
        if (amount == 0) return;
        uint256 num = amount * P + errYield;
        uint256 per = num / totalDeposits; // the branch credits only while totalDeposits >= MIN_SP_RESIDUAL (SP3)
        errYield = num - per * totalDeposits;
        scaleToB[currentScale] += per;
    }

    function offset(uint256 debt, uint256 coll) external onlyManager {
        uint256 total = totalDeposits;
        if (debt == 0 || debt + MIN_SP_RESIDUAL > total) revert OffsetOutOfRange(debt, total);
        uint256 num = coll * P + errColl;
        uint256 per = num / total;
        errColl = num - per * total;
        scaleToS[currentScale] += per;
        // re-divide the scaled numerator on each rescale, so no precision is lost to the first floor
        uint256 numerator = P * (total - debt);
        uint256 newP = numerator / total;
        while (newP < P_FLOOR) {
            numerator *= SCALE_FACTOR;
            newP = numerator / total;
            currentScale++;
        }
        P = newP;
        totalDeposits = total - debt;
        emit Offset(debt, coll, newP, currentScale);
    }

    // --- views ----------------------------------------------------------------------------------------------------------

    function compoundedDeposit(address depositor) public view returns (uint256) {
        Snapshot storage d = deposits[depositor];
        if (d.amount == 0) return 0;
        uint256 diff = currentScale - d.scale;
        if (diff > MAX_SCALE_DIFF) return 0;
        return FixedPointMath.mulDivDown(d.amount, P, d.p) / SCALE_FACTOR ** diff;
    }

    function pendingColl(address depositor) public view returns (uint256) {
        Snapshot storage d = deposits[depositor];
        return d.amount == 0 ? 0 : _gain(scaleToS, d, d.s);
    }

    function pendingYield(address depositor) public view returns (uint256) {
        Snapshot storage d = deposits[depositor];
        return d.amount == 0 ? 0 : _gain(scaleToB, d, d.b);
    }

    // --- internals ------------------------------------------------------------------------------------------------------

    /// The gain of a deposit in `acc` since its snapshot: its own scale in full, and each of the next MAX_SCALE_DIFF
    /// scales divided by 1e9 once more per scale (SP2: gains are read over all of them, M-8).
    function _gain(mapping(uint256 => uint256) storage acc, Snapshot storage d, uint256 snap)
        internal
        view
        returns (uint256)
    {
        uint256 s = d.scale;
        uint256 total = acc[s] - snap;
        uint256 span = currentScale - s;
        if (span > MAX_SCALE_DIFF) span = MAX_SCALE_DIFF;
        for (uint256 i = 1; i <= span; i++) {
            total += acc[s + i] / SCALE_FACTOR ** i;
        }
        return FixedPointMath.mulDivDown(d.amount, total, d.p);
    }

    function _settle(address depositor) internal returns (uint256 comp) {
        comp = compoundedDeposit(depositor);
        claimableColl[depositor] += pendingColl(depositor);
        claimableYield[depositor] += pendingYield(depositor);
    }

    function _snapshot(address depositor, uint256 amount) internal {
        uint256 scale = currentScale;
        deposits[depositor] = Snapshot(amount, P, scale, scaleToS[scale], scaleToB[scale]);
    }
}
