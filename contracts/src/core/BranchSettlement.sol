// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ISettlement, ISettlementHooks, IBranchManager} from "../interfaces/IBranchManager.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {WAD, L_PRECISION} from "../libraries/Constants.sol";
import {BranchLedger, NotAuthorized, BranchNotShutDown} from "../Types.sol";

/// @title BranchSettlement
/// @notice One branch's staged settlement after a shutdown (`docs/SPEC.md` §9). Phase 1: every open Trove is settled at
///         one reference price, fixed once (X1): it hands the common pot collateral worth its debt, or all it has, and its
///         owner keeps the rest (X2); after WRITE_OFF_DELAY a Trove nobody settles can be written off so that phase 1
///         ends (X5). When phase 1 ends, the healthy owners' surplus absorbs the shortfall of the under-water Troves, every
///         owner giving up the same fraction (X6, X11). Phase 2: every USDarli claims the same fraction of the pot, in any
///         order, and registers claim units that share whatever a written-off Trove hands over later (X7-X9).
/// @dev    A line-by-line port of the settlement code of `Branch` in `model/model.py`, replayed against it wei for wei
///         (`test_diff_settlementMatchesModel`). This contract keeps the settlement accounts; every move of the branch's
///         ledger, its Troves and its vault is one hook of the branch (ISettlementHooks), called in the model's order.
///         External calls: the branch only. Constant work per Trove: nothing here scans the set of Troves.
contract BranchSettlement is ISettlement, ReentrancyGuardTransient {
    uint256 public constant MAX_SETTLE_BATCH = 50;
    uint256 public constant WRITE_OFF_DELAY = 30 days;

    struct WrittenOff {
        uint256 debt;
        uint256 need;
        bool set;
    }

    ISettlementHooks public immutable branch;

    mapping(uint256 => WrittenOff) public writtenOff;
    uint256 public claimUnits; // total claims, fixed when phase 1 ends
    uint256 public take; // settlement surplus absorbed into the pot (current)
    uint256 public latePerUnit; // collateral per claim unit recovered after phase 1, L_PRECISION
    uint256 public latePool; // named account behind latePerUnit
    uint256 public parTotal; // collateral that would pay every claim at par
    uint256 public contribTotal; // collateral handed over by settled Troves
    uint256 public settleSurplusPool; // named account behind the owners' kept surplus
    uint256 public settleSurplusGross;
    uint256 public settleShortTotal;
    uint256 public surplusKeep; // fraction of gross surplus the owners keep, L_PRECISION; valid once keepFixed
    bool public keepFixed;
    mapping(address => uint256) public grossOf;
    mapping(address => uint256) public surplusPaid;
    mapping(address => uint256) public unitsOf;
    mapping(address => uint256) public latePaid;

    event TroveSettled(
        uint256 indexed troveId, address indexed owner, uint256 debt, uint256 contribution, uint256 surplus, bool late
    );
    event TroveWrittenOff(uint256 indexed troveId, uint256 debt, uint256 need);
    event PhaseOneComplete(uint256 take, uint256 surplusKeep, uint256 claimUnits);
    event Claimed(address indexed who, uint256 burned, uint256 collOut, uint256 lateOut);
    event SurplusClaimed(address indexed owner, uint256 amount);

    error BranchIsZero();
    error BatchSize();
    error WriteOffTooEarly();
    error AlreadyWrittenOff();
    error PotNotEmpty();
    error SurplusNotReleased();

    constructor(ISettlementHooks branch_) {
        if (address(branch_) == address(0)) revert BranchIsZero();
        branch = branch_;
    }

    // --- phase 1 ----------------------------------------------------------------------------------------------------

    function settleTrove(uint256 troveId)
        external
        nonReentrant
        returns (uint256 debt, uint256 contribution, uint256 surplus)
    {
        return _settle(troveId);
    }

    function settleTroves(uint256[] calldata troveIds) external nonReentrant {
        if (troveIds.length == 0 || troveIds.length > MAX_SETTLE_BATCH) revert BatchSize();
        for (uint256 i = 0; i < troveIds.length; i++) {
            _settle(troveIds[i]);
        }
    }

    function writeOff(uint256 troveId) external nonReentrant {
        uint256 shutdownAt = _ledger().shutdownAt;
        if (shutdownAt == 0 || block.timestamp < shutdownAt + WRITE_OFF_DELAY) revert WriteOffTooEarly();
        if (writtenOff[troveId].set) revert AlreadyWrittenOff();
        uint256 price = branch.fixSettlePrice();
        uint256 debt = branch.writeOffOut(troveId, msg.sender);
        uint256 need = FixedPointMath.ceilDiv(debt * WAD, price);
        parTotal += need;
        settleShortTotal += need; // worst case: it hands over nothing
        writtenOff[troveId] = WrittenOff(debt, need, true);
        emit TroveWrittenOff(troveId, debt, need);
        _endPhaseOneIfDone();
    }

    /// Phase 1 for one Trove. A written-off Trove settled before phase 1 ends is settled as if never written off; after
    /// it, as a late recovery that moves only the difference it makes to the totals (X5, X7).
    function _settle(uint256 troveId) internal returns (uint256 debt, uint256 contribution, uint256 gross) {
        if (_ledger().shutdownAt == 0) revert BranchNotShutDown();
        uint256 price = branch.fixSettlePrice();
        WrittenOff memory w = writtenOff[troveId];
        bool late = w.set;
        if (late && !keepFixed) {
            delete writtenOff[troveId];
            parTotal -= w.need;
            settleShortTotal -= w.need;
            branch.undoWriteOff(troveId, w.debt);
            late = false;
        }
        (uint256 d, uint256 coll, address owner) = branch.settleOut(troveId, msg.sender, !late);
        uint256 need;
        if (late) {
            delete writtenOff[troveId];
            (debt, need) = (w.debt, w.need);
        } else {
            debt = d;
            need = FixedPointMath.ceilDiv(debt * WAD, price); // rounded up, in favour of the holders' pot
        }
        contribution = coll < need ? coll : need;
        gross = coll - contribution;
        if (late) {
            _lateRecovery(owner, contribution, gross);
        } else {
            parTotal += need;
            contribTotal += contribution;
            grossOf[owner] += gross;
            settleSurplusPool += gross;
            settleSurplusGross += gross;
            settleShortTotal += need - contribution;
        }
        emit TroveSettled(troveId, owner, debt, contribution, gross, late);
        _endPhaseOneIfDone();
    }

    /// The totals are recomputed as if the Trove had been settled in time, and only the difference moves: to the holders
    /// the growth of the pot, shared by every claim unit alike; to the owners' pool the rest of this Trove's collateral
    /// (proof of conservation and of a non-negative difference in RESULTS.md).
    function _lateRecovery(address owner, uint256 contribution, uint256 gross) internal {
        uint256 coll = contribution + gross;
        uint256 potBefore = contribTotal + take;
        contribTotal += contribution;
        settleShortTotal -= contribution; // the write-off had assumed it hands over nothing
        settleSurplusGross += gross;
        grossOf[owner] += gross;
        uint256 g = settleSurplusGross;
        take = settleShortTotal < g ? settleShortTotal : g;
        surplusKeep = g == 0 ? L_PRECISION : (g - take) * L_PRECISION / g;
        uint256 toHolders = contribTotal + take - potBefore; // reverts if negative
        if (toHolders > 0 && claimUnits > 0) {
            latePerUnit += toHolders * L_PRECISION / claimUnits;
            latePool += toHolders;
        }
        settleSurplusPool += coll - toHolders; // reverts if more than the Trove's collateral
    }

    function _endPhaseOneIfDone() internal {
        if (IBranchManager(address(branch)).unsettled() == 0) {
            _endPhaseOne();
        }
    }

    /// @notice only the branch, from its shutdown, when no Trove is open.
    function onShutdownWithNoTroves() external {
        if (msg.sender != address(branch)) revert NotAuthorized();
        _endPhaseOne();
    }

    /// All Troves are settled or written off: the totals are final, so the pot and every owner's kept share are fixed once.
    function _endPhaseOne() internal {
        if (keepFixed) return;
        uint256 g = settleSurplusGross;
        uint256 t = settleShortTotal < g ? settleShortTotal : g;
        take = t;
        if (t > 0) {
            branch.addToPot(t);
        }
        settleSurplusPool -= t;
        surplusKeep = g == 0 ? L_PRECISION : (g - t) * L_PRECISION / g;
        keepFixed = true;
        claimUnits = _ledger().badDebt;
        emit PhaseOneComplete(t, surplusKeep, claimUnits);
    }

    // --- phase 2 ----------------------------------------------------------------------------------------------------

    function redeemBadDebtColl(uint256 amount, uint256 minCollOut) external nonReentrant returns (uint256) {
        return _redeem(amount, minCollOut);
    }

    function repayBadDebt(uint256 amount) external nonReentrant returns (uint256) {
        if (_ledger().badDebtColl != 0) revert PotNotEmpty();
        return _redeem(amount, 0);
    }

    /// Burns `amount` for a pro-rata share of the pot. The pot may be empty: the burn still registers claim units, which
    /// carry the right to every later recovery (X8, L5 3).
    function _redeem(uint256 amount, uint256 minCollOut) internal returns (uint256) {
        uint256 out = branch.burnClaim(msg.sender, amount, minCollOut);
        unitsOf[msg.sender] += amount;
        uint256 late = _claimLate(msg.sender);
        emit Claimed(msg.sender, amount, out, late);
        return out + late;
    }

    function claimLate() external nonReentrant returns (uint256) {
        return _claimLate(msg.sender);
    }

    /// Whatever written-off Troves hand over later belongs to every claim unit alike, exercised or not (X9).
    function _claimLate(address who) internal returns (uint256 due) {
        uint256 entitled = unitsOf[who] * latePerUnit / L_PRECISION;
        if (entitled <= latePaid[who]) return 0;
        due = entitled - latePaid[who];
        latePaid[who] = entitled;
        latePool -= due;
        branch.settlementCollOut(who, due);
    }

    /// entitlement = floor(gross x keep) - paid. Both factors only grow, so the time of claiming cannot change the total
    /// (X11). Needs no price.
    function claimSurplus() external nonReentrant returns (uint256 amount) {
        uint256 gross = grossOf[msg.sender];
        if (gross == 0) return 0;
        if (IBranchManager(address(branch)).unsettled() != 0 || !keepFixed) revert SurplusNotReleased();
        uint256 entitled = gross * surplusKeep / L_PRECISION;
        if (entitled > surplusPaid[msg.sender]) {
            amount = entitled - surplusPaid[msg.sender];
            surplusPaid[msg.sender] = entitled;
            settleSurplusPool -= amount;
        }
        branch.settlementCollOut(msg.sender, amount);
        emit SurplusClaimed(msg.sender, amount);
    }

    // --- views ------------------------------------------------------------------------------------------------------

    function phaseOneComplete() external view returns (bool) {
        return keepFixed && IBranchManager(address(branch)).unsettled() == 0;
    }

    function _ledger() internal view returns (BranchLedger memory) {
        return IBranchManager(address(branch)).ledger();
    }
}
