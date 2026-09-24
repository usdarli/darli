// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IBranchManager, ILiquidations, IBranchRedemption} from "../interfaces/IBranchManager.sol";
import {IBorrowerGateway} from "../interfaces/IBorrowerGateway.sol";
import {IStableToken} from "../interfaces/IStableToken.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {IStabilityPool} from "../interfaces/IStabilityPool.sol";
import {ICollateralVault, IFrontendRegistry, ITroveNFT, IRateSortedList} from "../interfaces/ICore.sol";
import {FixedPointMath} from "../libraries/FixedPointMath.sol";
import {
    WAD,
    YEAR,
    L_PRECISION,
    MIN_SP_RESIDUAL,
    DUST_THRESHOLD,
    UPFRONT_FEE_PERIOD,
    RATE_ADJUST_COOLDOWN,
    DEBT_CAP_PERIOD
} from "../libraries/Constants.sol";
import "../Types.sol";

/// Everything a branch is fixed to at deployment. Nothing here can change afterwards.
struct BranchConfig {
    IStableToken stable;
    IERC20 collToken;
    IPriceFeed feed;
    ICollateralVault vault;
    ITroveNFT nft;
    IRateSortedList list;
    IStabilityPool stabilityPool;
    IFrontendRegistry frontends;
    address escrow;
    address collateralRegistry; // the system's redemption router: the only caller of redeemFromBranch
    uint256 mcr;
    uint256 ccr;
    uint256 scr;
    uint256 minDebt;
    uint256 minRate;
    uint256 maxRate;
    uint256 cap0;
    uint256 capCeiling;
    uint256 gasDeposit;
    uint256 spShare;
    uint256 penSp; // liquidation premium to the Stability Pool, a cap (SPEC 6.2)
    uint256 penRedist; // liquidation premium on redistribution, a cap
    uint256 liqBonus; // the liquidator's share of the collateral
    uint256 liqBonusCap; // ... and its cap, in collateral units
}

/// @title BranchManager
/// @notice One branch of the system on a live chain: the aggregate ledger and the Trove ledger (`docs/SPEC.md` §4.2),
///         the borrower entry points and their single risk gate (§4.3–4.5), the revenue split (§8) and the shutdown
///         triggers (§6.5). It is a line-by-line port of `Branch` in `model/model.py`; the order of operations inside
///         each entry point follows the model, because the differential test compares every ledger wei for wei.
/// @dev    External calls, and why each is needed: the collateral token and the vault (custody), the stablecoin (mint and
///         burn), the price feed (risk-increasing operations and shutdown triggers only), the Stability Pool (yield it is
///         owed), the frontend registry (the interfaces' share), the Trove NFT (ownership) and the redemption list. All
///         are contracts of this deployment except the collateral token and the feed; none of them calls into user code.
///         Settlement after a shutdown (ISettlement) is a later stage.
contract BranchManager is IBranchManager, IBorrowerGateway, ILiquidations, IBranchRedemption, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // --- wiring (immutable) -------------------------------------------------------------------------------------------
    IStableToken public immutable stable;
    IERC20 public immutable collToken;
    IPriceFeed public immutable feed;
    ICollateralVault public immutable vault;
    ITroveNFT public immutable nft;
    IRateSortedList public immutable list;
    IStabilityPool public immutable stabilityPool;
    IFrontendRegistry public immutable frontends;
    address public immutable escrow;
    address public immutable collateralRegistry;

    // --- parameters (immutable; SPEC §2) ------------------------------------------------------------------------------
    uint256 public immutable mcr;
    uint256 public immutable ccr;
    uint256 public immutable scr;
    uint256 public immutable minDebt;
    uint256 public immutable minRate;
    uint256 public immutable maxRate;
    uint256 public immutable cap0;
    uint256 public immutable capCeiling;
    uint256 public immutable gasDeposit;
    uint256 public immutable spShare;
    uint256 public immutable penSp;
    uint256 public immutable penRedist;
    uint256 public immutable liqBonus;
    uint256 public immutable liqBonusCap;
    uint256 public immutable createdAt;

    // --- aggregate ledger ---------------------------------------------------------------------------------------------
    BranchLedger internal _ledger;
    uint256 public activeColl;
    uint256 public defaultColl;
    uint256 public gasPool;
    uint256 public settlePrice; // reference price of the settlement, fixed at shutdown (0 until the oracle is definite)
    uint256 public unsettled; // open Troves at shutdown still to be settled

    // --- redistribution (SPEC §6.3; written by liquidation, read by every step B) ---------------------------------------
    uint256 public totalStakes;
    uint256 public totalStakesSnapshot;
    uint256 public totalCollSnapshot;
    uint256 public lColl;
    uint256 public lDebt;
    uint256 public lCollError; // remainders carried from one redistribution to the next (SPEC L4)
    uint256 public lDebtError;

    // --- Troves -------------------------------------------------------------------------------------------------------
    mapping(uint256 => Trove) internal _troves;
    mapping(uint256 => uint256) public gasLeft;
    mapping(address => uint256) public surplus; // collateral left over from a liquidation, the owner's (SPEC L3)
    uint256 public nextTroveId = 1;
    uint256 public nOpen;
    uint256 internal _lastZombie;

    event TroveOpened(
        uint256 indexed troveId, address indexed owner, uint256 coll, uint256 debt, uint256 rate, uint32 frontendId
    );
    event TroveUpdated(uint256 indexed troveId, uint256 coll, uint256 debt, uint256 rate, TroveStatus status);
    event TroveClosed(uint256 indexed troveId, TroveStatus status);
    event InterestMinted(uint256 amount, uint256 toFrontends, uint256 toStabilityPool, uint256 toEscrow);
    event Shutdown(uint256 at, uint256 settlePrice);
    event Liquidated(uint256 indexed troveId, address indexed liquidator, LiquidationValues values);
    event SurplusClaimed(address indexed owner, uint256 amount);
    event Redeemed(address indexed redeemer, uint256 redeemed, uint256 collOut, uint256 feeRate);

    error InvalidConfig();

    constructor(BranchConfig memory c) {
        if (
            !(c.scr <= c.mcr && c.mcr < c.ccr) || c.minRate > c.maxRate || c.spShare > WAD || c.escrow == address(0)
                || c.collateralRegistry == address(0) || !(c.penSp <= c.penRedist && c.penRedist <= c.mcr - WAD)
                || c.liqBonus > WAD
        ) {
            revert InvalidConfig();
        }
        stable = c.stable;
        collToken = c.collToken;
        feed = c.feed;
        vault = c.vault;
        nft = c.nft;
        list = c.list;
        stabilityPool = c.stabilityPool;
        frontends = c.frontends;
        escrow = c.escrow;
        collateralRegistry = c.collateralRegistry;
        mcr = c.mcr;
        ccr = c.ccr;
        scr = c.scr;
        minDebt = c.minDebt;
        minRate = c.minRate;
        maxRate = c.maxRate;
        cap0 = c.cap0;
        capCeiling = c.capCeiling;
        gasDeposit = c.gasDeposit;
        spShare = c.spShare;
        penSp = c.penSp;
        penRedist = c.penRedist;
        liqBonus = c.liqBonus;
        liqBonusCap = c.liqBonusCap;
        createdAt = block.timestamp;
        _ledger.lastAggUpdate = uint64(block.timestamp);
    }

    // =================================================================================================================
    // Borrower entry points (IBorrowerGateway)
    // =================================================================================================================

    function openTrove(
        address owner,
        uint256 coll,
        uint256 debt,
        uint256 annualRate,
        uint32 frontendId,
        uint256 maxUpfrontFee,
        uint256 prevHint,
        uint256 nextHint
    ) external nonReentrant returns (uint256) {
        return _openTrove(OpenArgs(owner, coll, debt, annualRate, frontendId, maxUpfrontFee, prevHint, nextHint));
    }

    function borrow(uint256 troveId, uint256 amount, uint256 maxUpfrontFee) external nonReentrant {
        _requireOwnerOrApproved(troveId);
        _requireNonZero(amount);
        _borrow(troveId, amount, maxUpfrontFee);
    }

    function repay(uint256 troveId, uint256 amount) external nonReentrant {
        _requireNonZero(amount);
        _repay(troveId, amount);
    }

    function addColl(uint256 troveId, uint256 amount) external nonReentrant {
        _requireNonZero(amount);
        _addColl(troveId, amount);
    }

    function withdrawColl(uint256 troveId, uint256 amount) external nonReentrant {
        _requireOwnerOrApproved(troveId);
        _requireNonZero(amount);
        _requireOpen(troveId);
        _requireLive();
        uint256 price = _requireValidPrice();
        _stepA();
        _touch(troveId, 0, 0, _troves[troveId].annualRate, -SafeCast.toInt256(amount));
        _collOut(msg.sender, amount);
        _afterRiskOp(troveId, price);
    }

    /// @dev Below CCR a borrower may still repay and top up; new debt only if TCR >= CCR afterwards, and collateral out
    ///      only together with a repayment worth at least as much (SPEC B8).
    function adjustTrove(uint256 troveId, int256 collChange, int256 debtChange, uint256 maxUpfrontFee)
        external
        nonReentrant
    {
        _requireOwnerOrApproved(troveId);
        _requireOpen(troveId);
        if (collChange == 0 && debtChange == 0) revert ZeroAmount();
        if (collChange >= 0 && debtChange <= 0) {
            if (collChange > 0) {
                _addColl(troveId, uint256(collChange));
            }
            if (debtChange < 0) {
                _repay(troveId, uint256(-debtChange));
            }
            return;
        }
        _requireLive();
        uint256 price = _requireValidPrice();
        _stepA();
        bool below = _tcr(price) < ccr;
        Trove storage t = _troves[troveId];
        uint256 fee;
        if (debtChange > 0) {
            fee = _upfrontFee(uint256(debtChange), t.annualRate, troveId);
            if (fee > maxUpfrontFee) revert UpfrontFeeTooHigh(fee, maxUpfrontFee);
            if (_ledger.aggDebt + uint256(debtChange) + fee > debtCap()) revert DebtCapExceeded();
        }
        if (collChange > 0) {
            _collIn(msg.sender, uint256(collChange));
        }
        if (debtChange < 0) {
            stable.burn(msg.sender, uint256(-debtChange));
        }
        uint256 before = _debtNow(troveId);
        _touch(troveId, debtChange, fee, t.annualRate, collChange);
        if (debtChange > 0) {
            stable.mint(msg.sender, uint256(debtChange));
            _mintInterestSplit(fee);
            if (t.recordedDebt < minDebt) revert DebtBelowMinimum();
            if (t.status == TroveStatus.Zombie) {
                _reactivate(troveId); // back at the minimum: Active again and in the queue, as after `borrow` (SPEC B4)
            }
        } else if (before >= minDebt && t.recordedDebt < minDebt) {
            revert RepayWouldLeaveDust();
        }
        if (collChange < 0) {
            _collOut(msg.sender, uint256(-collChange));
        }
        if (_icr(troveId, price) < mcr) revert ICRBelowMCR();
        if (below) {
            if (debtChange > 0 && _tcr(price) < ccr) revert TCRBelowCCR();
            // repaid * WAD >= withdrawn * price; a withdrawal that comes with no repayment (or with new debt) never passes
            if (collChange < 0) {
                uint256 withdrawnValue = uint256(-collChange) * price;
                bool matched = debtChange < 0 ? uint256(-debtChange) * WAD >= withdrawnValue : false;
                if (!matched) revert WithdrawalNotMatchedByRepayment();
            }
        } else if (_tcr(price) < ccr) {
            revert TCRBelowCCR();
        }
    }

    function adjustRate(uint256 troveId, uint256 newRate, uint256 maxUpfrontFee, uint256 prevHint, uint256 nextHint)
        external
        nonReentrant
    {
        _requireOwnerOrApproved(troveId);
        _requireLive();
        Trove storage t = _troves[troveId];
        if (t.status != TroveStatus.Active) revert TroveNotActive();
        if (newRate == t.annualRate) revert RateNotNew();
        if (newRate < minRate || newRate > maxRate) revert RateOutOfRange();
        _stepA();
        uint256 fee;
        uint256 price;
        if (block.timestamp < t.lastRateAdjust + RATE_ADJUST_COOLDOWN) {
            price = _requireValidPrice(); // the fee raises the debt, so it needs a price
            uint256 debt = _debtNow(troveId);
            // the fee is on the whole debt, at the branch average rate AFTER the change
            uint256 aggDebt = _ledger.aggDebt;
            uint256 avg = aggDebt == 0
                ? 0
                : (_ledger.aggWeightedDebtSum - t.recordedDebt * t.annualRate + debt * newRate) / aggDebt;
            fee = debt * avg * UPFRONT_FEE_PERIOD / (YEAR * WAD);
            if (fee > maxUpfrontFee) revert UpfrontFeeTooHigh(fee, maxUpfrontFee);
        }
        _touch(troveId, 0, fee, newRate, 0);
        t.lastRateAdjust = uint64(block.timestamp);
        list.reinsert(troveId, newRate, prevHint, nextHint);
        if (fee > 0) {
            _mintInterestSplit(fee);
            if (_icr(troveId, price) < mcr) revert ICRBelowMCR();
            if (_tcr(price) < ccr) revert TCRBelowCCR();
        }
    }

    function closeTrove(uint256 troveId) external nonReentrant {
        _requireOwnerOrApproved(troveId);
        _requireLive(); // after a shutdown a Trove is settled, not closed
        _requireOpen(troveId);
        _stepA();
        uint256 debt = _debtNow(troveId);
        uint256 short;
        if (nOpen == 1) {
            // the last Trove of a branch may be short by rounding dust stuck in core contracts; it is parked in badDebt
            uint256 balance = stable.balanceOf(msg.sender);
            short = debt > balance ? debt - balance : 0;
            if (short > DUST_THRESHOLD) revert ShortfallAboveDust();
        }
        stable.burn(msg.sender, debt - short);
        Trove storage t = _troves[troveId];
        _touch(troveId, -SafeCast.toInt256(debt), 0, t.annualRate, 0);
        _ledger.aggDebt += short;
        _ledger.badDebt += short;
        uint256 coll = t.coll;
        _removeTrove(troveId, TroveStatus.ClosedByOwner);
        _payGasDeposit(troveId, msg.sender);
        _collOut(msg.sender, coll);
        _sweepDustIfEmpty();
    }

    // =================================================================================================================
    // Permissionless and wired entry points (IBranchManager)
    // =================================================================================================================

    function applyPendingDebt(uint256 troveId) external nonReentrant {
        _requireOpen(troveId);
        _stepA();
        Trove storage t = _troves[troveId];
        _touch(troveId, 0, 0, t.annualRate, 0);
        if (t.status == TroveStatus.Zombie && t.recordedDebt >= minDebt) {
            _reactivate(troveId); // accrued interest or redistribution lifted it back
        }
    }

    function mintAggInterest() external nonReentrant returns (uint256) {
        if (msg.sender != address(stabilityPool)) revert NotAuthorized();
        return _stepA();
    }

    function onTroveTransfer(uint256 troveId) external nonReentrant {
        if (msg.sender != address(nft)) revert NotAuthorized();
        _stepA();
        _touch(troveId, 0, 0, _troves[troveId].annualRate, 0);
    }

    function pokeOracle() external nonReentrant returns (PriceStatus status) {
        if (_ledger.oracleFailed) return PriceStatus.Failed;
        (, status) = feed.fetchPrice();
        if (status == PriceStatus.Failed) {
            _ledger.oracleFailed = true;
            _shutdown();
        }
    }

    function triggerShutdown() external nonReentrant {
        (uint256 price, PriceStatus status) = feed.fetchPrice();
        if (status == PriceStatus.Failed) {
            _ledger.oracleFailed = true;
            _shutdown();
        } else if (status == PriceStatus.Valid && _tcr(price) < scr) {
            _shutdown();
        } else if (_ledger.badDebt >= DUST_THRESHOLD) {
            _shutdown();
        }
    }

    // =================================================================================================================
    // Liquidation (ILiquidations, SPEC 6.2-6.4)
    // =================================================================================================================

    /// @notice Anyone may liquidate a Trove below MCR, with a Valid price, while the branch is live (L1). The waterfall
    ///         (L2): the Stability Pool absorbs what it can above its residual at <= penSp, the rest is redistributed to
    ///         the other Troves at <= penRedist, and with no Trove left to take it, it becomes bad debt and the branch
    ///         shuts down. The liquidator receives liqBonus of the collateral (capped) and the Trove's gas deposit; what
    ///         is left belongs to the owner (L3).
    function liquidate(uint256 troveId) external nonReentrant returns (LiquidationValues memory v) {
        _requireOpen(troveId);
        _requireLive(); // after a shutdown Troves are settled, not liquidated
        uint256 price = _requireValidPrice();
        _stepA();
        Trove storage t = _troves[troveId];
        _touch(troveId, 0, 0, t.annualRate, 0);
        uint256 debt = t.recordedDebt;
        uint256 coll = t.coll;
        if (debt == 0) revert TroveNotLiquidatable(); // a zero-debt Trove has infinite ICR
        if (coll * price / debt >= mcr) revert TroveNotLiquidatable();
        v = _waterfall(debt, coll, price);
        address owner = nft.ownerOf(troveId);
        _removeTrove(troveId, TroveStatus.ClosedByLiquidation);
        _payGasDeposit(troveId, msg.sender);
        _collOut(msg.sender, v.liquidatorBonus);
        if (v.debtOffset > 0) {
            _collOut(address(stabilityPool), v.collToSP);
            stabilityPool.offset(v.debtOffset, v.collToSP);
            stable.burn(address(stabilityPool), v.debtOffset); // the protocol's own account (SPEC 10.5)
            _ledger.aggDebt -= v.debtOffset;
        }
        if (v.debtRemainder > 0) {
            if (totalStakes > 0) {
                _redistribute(v.debtRemainder, v.collRemainder);
            } else {
                _ledger.badDebt += v.debtRemainder;
                _ledger.badDebtColl += v.collRemainder;
                v.becameBadDebt = true;
                _shutdown();
            }
        } else {
            v.collSurplus += v.collRemainder;
        }
        surplus[owner] += v.collSurplus;
        totalStakesSnapshot = totalStakes;
        totalCollSnapshot = activeColl + defaultColl;
        _sweepDustIfEmpty();
        if (_ledger.shutdownAt == 0 && _tcr(price) < scr) {
            _shutdown();
        }
        emit Liquidated(troveId, msg.sender, v);
    }

    /// The split of one liquidated Trove. Premiums are caps: an under-water Trove hands over everything it has.
    function _waterfall(uint256 debt, uint256 coll, uint256 price) internal view returns (LiquidationValues memory v) {
        uint256 bonus = coll * liqBonus / WAD;
        v.liquidatorBonus = bonus < liqBonusCap ? bonus : liqBonusCap;
        uint256 collAvail = coll - v.liquidatorBonus;
        uint256 spTotal = stabilityPool.totalDeposits();
        uint256 spAvail = spTotal > MIN_SP_RESIDUAL ? spTotal - MIN_SP_RESIDUAL : 0;
        v.debtOffset = debt < spAvail ? debt : spAvail;
        v.collToSP = _min(v.debtOffset * (WAD + penSp) / price, collAvail * v.debtOffset / debt);
        v.debtRemainder = debt - v.debtOffset;
        v.collRemainder = _min(v.debtRemainder * (WAD + penRedist) / price, collAvail - v.collToSP);
        v.collSurplus = collAvail - v.collToSP - v.collRemainder;
    }

    /// Redistribution (SPEC L4): per-stake accumulators at L_PRECISION, with the division remainders carried forward.
    function _redistribute(uint256 debt, uint256 coll) internal {
        uint256 stakes = totalStakes;
        uint256 nc = coll * L_PRECISION + lCollError;
        uint256 nd = debt * L_PRECISION + lDebtError;
        uint256 pc = nc / stakes;
        uint256 pd = nd / stakes;
        lCollError = nc - pc * stakes;
        lDebtError = nd - pd * stakes;
        lColl += pc;
        lDebt += pd;
        defaultColl += coll;
    }

    /// @notice The collateral a liquidation left over for the caller's Troves. Needs no price and no permission (L3).
    function claimSurplus() external nonReentrant returns (uint256 amount) {
        amount = surplus[msg.sender];
        surplus[msg.sender] = 0;
        _collOut(msg.sender, amount);
        emit SurplusClaimed(msg.sender, amount);
    }

    // =================================================================================================================
    // Redemption inside the branch (IBranchRedemption, SPEC 5)
    // =================================================================================================================

    /// @notice What the CollateralRegistry needs to route a redemption (R1, R3, R4). Reads the feed, records nothing:
    ///         a price that is not Valid only makes the branch unredeemable for this call; it never shuts it down.
    function redemptionState() external nonReentrant returns (RedemptionState memory s) {
        s.aggDebt = _ledger.aggDebt;
        uint256 spTotal = stabilityPool.totalDeposits();
        uint256 covered = spTotal > MIN_SP_RESIDUAL ? spTotal - MIN_SP_RESIDUAL : 0;
        s.unbacked = s.aggDebt > covered ? s.aggDebt - covered : 0;
        if (_ledger.shutdownAt != 0) return s; // after a shutdown: settlement, not redemption
        PriceStatus status;
        (s.price, status) = feed.fetchPrice();
        if (status != PriceStatus.Valid || _tcr(s.price) < scr) return s;
        (s.redemptionPrice, status) = feed.fetchRedemptionPrice();
        s.redeemable = status == PriceStatus.Valid && s.redemptionPrice != 0;
    }

    /// @notice Only the CollateralRegistry, with the prices it just read from `redemptionState` and one fee rate for the
    ///         whole redemption. Walks the tracked Zombie first, then the queue from its lowest (rate, id) (R2); skips a
    ///         Trove below 100 % ICR at `price` but counts it as an iteration; converts debt at the higher of
    ///         `redemptionPrice` and `price` (R4);
    ///         leaves the fee in the Trove as collateral (R7). A Trove left under the minimum becomes a Zombie and leaves
    ///         the queue; with debt left, it is the one redeemed first next time. Burns only from the redeemer.
    function redeemFromBranch(
        address redeemer,
        uint256 amount,
        uint256 price,
        uint256 redemptionPrice,
        uint256 feeRate,
        uint256 maxIterations
    ) external nonReentrant returns (uint256 redeemed, uint256 collOut) {
        if (msg.sender != collateralRegistry) revert NotAuthorized();
        _requireLive();
        // R4: never converted below `price`, whatever the feed returns, so a Trove at or above 100 % never gives up more
        // collateral per unit of debt than it holds, and its ICR never falls
        if (redemptionPrice < price) redemptionPrice = price;
        _stepA();
        uint256 remaining = amount;
        uint256 id = _lastZombie;
        bool zombieFirst = id != 0;
        if (!zombieFirst) id = list.last();
        for (uint256 it = 0; id != 0 && remaining != 0 && it < maxIterations; it++) {
            // the next Trove, read before this one can leave the queue; the tracked Zombie is not in it
            uint256 nextId = zombieFirst ? list.last() : list.prev(id);
            zombieFirst = false;
            if (_icr(id, price) >= WAD) {
                uint256 r = _min(remaining, _debtNow(id));
                uint256 out = r * WAD / redemptionPrice;
                out -= out * feeRate / WAD; // the fee stays in the Trove (R7)
                Trove storage t = _troves[id];
                _touch(id, -SafeCast.toInt256(r), 0, t.annualRate, -SafeCast.toInt256(out));
                remaining -= r;
                collOut += out;
                if (t.recordedDebt < minDebt) {
                    if (t.status == TroveStatus.Active) {
                        t.status = TroveStatus.Zombie; // includes a debt of zero
                        list.remove(id);
                        if (t.recordedDebt != 0) _lastZombie = id;
                    } else if (t.recordedDebt == 0 && _lastZombie == id) {
                        _lastZombie = 0;
                    }
                }
            }
            id = nextId;
        }
        redeemed = amount - remaining;
        stable.burn(redeemer, redeemed); // the account that initiated the redemption (SPEC 10.5)
        _collOut(redeemer, collOut);
        emit Redeemed(redeemer, redeemed, collOut, feeRate);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // =================================================================================================================
    // Views
    // =================================================================================================================

    function ledger() external view returns (BranchLedger memory) {
        return _ledger;
    }

    function getTrove(uint256 troveId) external view returns (Trove memory) {
        return _troves[troveId];
    }

    function troveDebt(uint256 troveId) external view returns (uint256) {
        return _debtNow(troveId);
    }

    function troveColl(uint256 troveId) external view returns (uint256) {
        return _troves[troveId].coll + _pendColl(troveId);
    }

    function pendingAggInterest() public view returns (uint256) {
        return FixedPointMath.aggregateInterest(_ledger.aggWeightedDebtSum, _tEff() - _ledger.lastAggUpdate);
    }

    function lastZombieTroveId() external view returns (uint256) {
        return _lastZombie;
    }

    /// @notice cap(t) = min(ceiling, cap0 * 2^floor((t - created) / DEBT_CAP_PERIOD)) (SPEC B11). Nobody can change it.
    function debtCap() public view returns (uint256) {
        uint256 steps = (block.timestamp - createdAt) / DEBT_CAP_PERIOD;
        if (steps > 64) steps = 64;
        if (cap0 > capCeiling >> steps) return capCeiling; // cap0 << steps would reach the ceiling (or overflow)
        return cap0 << steps;
    }

    // =================================================================================================================
    // Internals: the operations shared by several entry points
    // =================================================================================================================

    struct OpenArgs {
        address owner;
        uint256 coll;
        uint256 debt;
        uint256 rate;
        uint32 frontendId;
        uint256 maxUpfrontFee;
        uint256 prevHint;
        uint256 nextHint;
    }

    function _openTrove(OpenArgs memory a) internal returns (uint256 troveId) {
        _requireLive();
        uint256 price = _requireValidPrice();
        if (a.rate < minRate || a.rate > maxRate) revert RateOutOfRange();
        if (a.frontendId >= frontends.count()) revert UnknownFrontend(a.frontendId);
        _stepA();
        uint256 fee = _upfrontFee(a.debt, a.rate, 0);
        if (fee > a.maxUpfrontFee) revert UpfrontFeeTooHigh(fee, a.maxUpfrontFee);
        if (a.debt + fee < minDebt) revert DebtBelowMinimum();
        if (_ledger.aggDebt + a.debt + fee > debtCap()) revert DebtCapExceeded();

        troveId = nextTroveId++;
        Trove storage t = _troves[troveId];
        t.annualRate = a.rate;
        t.lastDebtUpdate = uint64(_tEff());
        t.lastRateAdjust = uint64(block.timestamp);
        t.status = TroveStatus.Active;
        t.frontendId = a.frontendId;
        t.snapshotLColl = lColl;
        t.snapshotLDebt = lDebt;
        nOpen++;
        nft.mint(a.owner, troveId);
        if (gasDeposit > 0) {
            _collIn(msg.sender, gasDeposit); // posted at opening; pays whoever closes the position out
            gasPool += gasDeposit;
            gasLeft[troveId] = gasDeposit;
        }
        _collIn(msg.sender, a.coll);
        _touch(troveId, SafeCast.toInt256(a.debt), fee, a.rate, SafeCast.toInt256(a.coll));
        list.insert(troveId, a.rate, a.prevHint, a.nextHint);
        stable.mint(msg.sender, a.debt);
        _mintInterestSplit(fee);
        _afterRiskOp(troveId, price);
        emit TroveOpened(troveId, a.owner, a.coll, a.debt, a.rate, a.frontendId);
    }

    function _borrow(uint256 troveId, uint256 amount, uint256 maxUpfrontFee) internal {
        _requireLive();
        uint256 price = _requireValidPrice();
        _requireOpen(troveId);
        _stepA();
        Trove storage t = _troves[troveId];
        uint256 fee = _upfrontFee(amount, t.annualRate, troveId);
        if (fee > maxUpfrontFee) revert UpfrontFeeTooHigh(fee, maxUpfrontFee);
        if (_ledger.aggDebt + amount + fee > debtCap()) revert DebtCapExceeded();
        _touch(troveId, SafeCast.toInt256(amount), fee, t.annualRate, 0);
        if (t.recordedDebt < minDebt) revert DebtBelowMinimum();
        if (t.status == TroveStatus.Zombie) {
            _reactivate(troveId);
        }
        stable.mint(msg.sender, amount);
        _mintInterestSplit(fee);
        _afterRiskOp(troveId, price);
    }

    /// @dev Needs no price and no permission (SPEC B9); burns only from the caller.
    function _repay(uint256 troveId, uint256 amount) internal {
        _requireLive(); // after a shutdown a Trove is settled, not repaid
        _requireOpen(troveId);
        _stepA();
        uint256 before = _debtNow(troveId);
        if (amount > before) amount = before;
        uint256 remaining = before - amount;
        if (before >= minDebt && remaining < minDebt && remaining != 0) revert RepayWouldLeaveDust();
        if (remaining == 0) revert RepayInFullWithClose();
        stable.burn(msg.sender, amount);
        _touch(troveId, -SafeCast.toInt256(amount), 0, _troves[troveId].annualRate, 0);
    }

    /// @dev Needs no price and no permission (SPEC B9); collateral comes from the caller.
    function _addColl(uint256 troveId, uint256 amount) internal {
        _requireLive();
        _requireOpen(troveId);
        _stepA();
        _collIn(msg.sender, amount);
        _touch(troveId, 0, 0, _troves[troveId].annualRate, SafeCast.toInt256(amount));
    }

    // =================================================================================================================
    // Internals: the two ledgers
    // =================================================================================================================

    function _tEff() internal view returns (uint256) {
        uint256 s = _ledger.shutdownAt;
        return s != 0 && s < block.timestamp ? s : block.timestamp;
    }

    /// Step A (SPEC B1): mint the aggregate interest since the last update, rounded UP, and split it.
    function _stepA() internal returns (uint256 p) {
        uint256 t = _tEff();
        p = FixedPointMath.aggregateInterest(_ledger.aggWeightedDebtSum, t - _ledger.lastAggUpdate);
        _ledger.aggDebt += p;
        _ledger.lastAggUpdate = uint64(t);
        _mintInterestSplit(p);
    }

    /// The same three-way split for aggregate interest and for upfront fees (SPEC V1).
    function _mintInterestSplit(uint256 amount) internal {
        if (amount == 0) return;
        uint256 fe = frontends.recordDeposit(amount); // rounded up
        uint256 sp = stabilityPool.totalDeposits() >= MIN_SP_RESIDUAL ? amount * spShare / WAD : 0;
        uint256 rest = amount - fe - sp;
        if (fe > 0) stable.mint(address(frontends), fe);
        if (sp > 0) {
            stable.mint(address(stabilityPool), sp);
            stabilityPool.creditYield(sp);
        }
        if (rest > 0) stable.mint(escrow, rest);
        emit InterestMinted(amount, fe, sp, rest);
    }

    function _accrued(uint256 troveId) internal view returns (uint256) {
        Trove storage t = _troves[troveId];
        return FixedPointMath.troveInterest(t.recordedDebt, t.annualRate, _tEff() - t.lastDebtUpdate);
    }

    function _pendDebt(uint256 troveId) internal view returns (uint256) {
        Trove storage t = _troves[troveId];
        return FixedPointMath.mulDivDown(t.stake, lDebt - t.snapshotLDebt, L_PRECISION); // floor, no 256-bit ceiling
    }

    function _pendColl(uint256 troveId) internal view returns (uint256) {
        Trove storage t = _troves[troveId];
        return FixedPointMath.mulDivDown(t.stake, lColl - t.snapshotLColl, L_PRECISION);
    }

    function _debtNow(uint256 troveId) internal view returns (uint256) {
        return _troves[troveId].recordedDebt + _accrued(troveId) + _pendDebt(troveId);
    }

    function _computeStake(uint256 coll) internal view returns (uint256) {
        return totalCollSnapshot == 0 ? coll : coll * totalStakesSnapshot / totalCollSnapshot;
    }

    /// Step B (SPEC B1): the Trove's own interest, rounded DOWN, and its pending redistribution join its recorded debt;
    /// nothing is minted here. `debtChange` and `fee` move the aggregate as well; `collChange` moves the Trove's
    /// collateral. The frontend is credited with (interest + fee).
    function _touch(uint256 troveId, int256 debtChange, uint256 fee, uint256 newRate, int256 collChange)
        internal
        returns (uint256 accrued, uint256 redistributed)
    {
        Trove storage t = _troves[troveId];
        accrued = _accrued(troveId);
        redistributed = _pendDebt(troveId);
        uint256 redistColl = _pendColl(troveId);
        uint256 oldWeight = t.recordedDebt * t.annualRate;
        uint256 newDebt = _addSigned(t.recordedDebt + accrued + redistributed + fee, debtChange);
        if (_ledger.shutdownAt == 0) {
            _ledger.aggWeightedDebtSum = _ledger.aggWeightedDebtSum - oldWeight + newDebt * newRate;
        }
        t.recordedDebt = newDebt;
        t.annualRate = newRate;
        _ledger.aggDebt = _addSigned(_ledger.aggDebt + fee, debtChange);
        t.lastDebtUpdate = uint64(_tEff());
        // collateral: pending redistribution moves from the default account to the active one
        defaultColl -= redistColl;
        activeColl = _addSigned(activeColl + redistColl, collChange);
        t.coll = _addSigned(t.coll + redistColl, collChange);
        t.snapshotLColl = lColl;
        t.snapshotLDebt = lDebt;
        totalStakes -= t.stake;
        t.stake = _computeStake(t.coll);
        totalStakes += t.stake;
        if (accrued + fee > 0) {
            frontends.credit(t.frontendId, nft.ownerOf(troveId), accrued + fee);
        }
        emit TroveUpdated(troveId, t.coll, newDebt, newRate, t.status);
    }

    function _addSigned(uint256 a, int256 b) internal pure returns (uint256) {
        return b >= 0 ? a + uint256(b) : a - uint256(-b); // reverts (checked arithmetic) if a change exceeds the balance
    }

    function _upfrontFee(uint256 increase, uint256 rate, uint256 troveId) internal view returns (uint256) {
        // avg = (aggW - oldWeight_i + newDebtBeforeFee_i * rate) / (aggDebt + increase)
        uint256 denom = _ledger.aggDebt + increase;
        if (denom == 0) return 0;
        uint256 oldWeight;
        uint256 newDebt = increase;
        if (troveId != 0) {
            Trove storage t = _troves[troveId];
            oldWeight = t.recordedDebt * t.annualRate;
            newDebt += _debtNow(troveId);
        }
        uint256 avg = (_ledger.aggWeightedDebtSum - oldWeight + newDebt * rate) / denom;
        return increase * avg * UPFRONT_FEE_PERIOD / (YEAR * WAD);
    }

    function _removeTrove(uint256 troveId, TroveStatus status) internal {
        Trove storage t = _troves[troveId];
        if (_lastZombie == troveId) _lastZombie = 0;
        if (t.status == TroveStatus.Active) list.remove(troveId); // a Zombie is not in the queue
        if (_ledger.shutdownAt == 0) {
            _ledger.aggWeightedDebtSum -= t.recordedDebt * t.annualRate;
        }
        totalStakes -= t.stake;
        activeColl -= t.coll;
        t.stake = 0;
        t.coll = 0;
        t.recordedDebt = 0;
        t.status = status;
        nOpen--;
        nft.burn(troveId);
        emit TroveClosed(troveId, status);
    }

    function _reactivate(uint256 troveId) internal {
        Trove storage t = _troves[troveId];
        t.status = TroveStatus.Active;
        if (_lastZombie == troveId) _lastZombie = 0;
        list.insert(troveId, t.annualRate, 0, 0);
    }

    /// Pays from THIS Trove's remaining deposit only; a Trove can never pay more than it posted (SPEC B13).
    function _payGasDeposit(uint256 troveId, address to) internal {
        uint256 amount = gasLeft[troveId];
        if (amount == 0) return;
        gasLeft[troveId] = 0;
        gasPool -= amount;
        _collOut(to, amount);
    }

    /// When the last Trove goes, the rounding remainder is parked in badDebt (SPEC 4.2). A counter, not a scan.
    function _sweepDustIfEmpty() internal {
        if (nOpen != 0) return;
        uint256 residual = _ledger.aggDebt - _ledger.badDebt;
        if (residual == 0) return;
        _ledger.badDebt += residual;
        if (residual >= DUST_THRESHOLD && _ledger.shutdownAt == 0) _shutdown();
    }

    // =================================================================================================================
    // Internals: shutdown (the settlement itself is ISettlement)
    // =================================================================================================================

    function _shutdown() internal {
        if (_ledger.shutdownAt != 0) return;
        _stepA();
        _ledger.shutdownAt = uint64(block.timestamp);
        _ledger.aggWeightedDebtSum = 0;
        unsettled = nOpen;
        settlePrice = _shutdownPrice();
        emit Shutdown(block.timestamp, settlePrice);
    }

    /// The reference price of the settlement: the last good price after an oracle failure, the current price when it is
    /// valid, and 0 (to be fixed by the first settlement) while the oracle is in a temporary state.
    function _shutdownPrice() internal returns (uint256) {
        if (_ledger.oracleFailed) return feed.lastGoodPrice();
        (uint256 price, PriceStatus status) = feed.fetchPrice();
        if (status == PriceStatus.Failed) {
            _ledger.oracleFailed = true;
            return feed.lastGoodPrice();
        }
        return status == PriceStatus.Valid ? price : 0;
    }

    // =================================================================================================================
    // Internals: checks and custody
    // =================================================================================================================

    function _requireLive() internal view {
        if (_ledger.shutdownAt != 0) revert BranchShutDown(); // the ONLY stop that exists, and only the rules trigger it
    }

    function _requireValidPrice() internal returns (uint256 price) {
        PriceStatus status;
        (price, status) = feed.fetchPrice();
        if (status != PriceStatus.Valid) revert PriceNotValid(status);
    }

    function _requireOpen(uint256 troveId) internal view {
        TroveStatus s = _troves[troveId].status;
        if (s != TroveStatus.Active && s != TroveStatus.Zombie) revert TroveNotOpen();
    }

    function _requireOwnerOrApproved(uint256 troveId) internal view {
        _requireOpen(troveId);
        if (!nft.isOwnerOrApproved(msg.sender, troveId)) revert NotAuthorized();
    }

    function _requireNonZero(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    function _icr(uint256 troveId, uint256 price) internal view returns (uint256) {
        uint256 d = _debtNow(troveId);
        return d == 0 ? type(uint256).max : (_troves[troveId].coll + _pendColl(troveId)) * price / d;
    }

    function _tcr(uint256 price) internal view returns (uint256) {
        uint256 d = _ledger.aggDebt + pendingAggInterest();
        return d == 0 ? type(uint256).max : (activeColl + defaultColl) * price / d;
    }

    function _afterRiskOp(uint256 troveId, uint256 price) internal view {
        if (_icr(troveId, price) < mcr) revert ICRBelowMCR();
        if (_tcr(price) < ccr) revert TCRBelowCCR();
    }

    function _collIn(address from, uint256 amount) internal {
        collToken.safeTransferFrom(from, address(vault), amount);
        vault.accountIn(amount);
    }

    function _collOut(address to, uint256 amount) internal {
        vault.send(to, amount);
    }
}
