// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EpochStream} from "../libraries/EpochStream.sol";

/// @title LPFeeAccounting
/// @notice The liquidity vault's books (`docs/SPEC.md` V6): three independent per-share accumulators -- swap fees in
///         token0, swap fees in token1, and reward tokens paid into the vault, the last streamed in fixed weekly epochs.
///         Every change of shares settles its holder first, so a newcomer gets no part of earlier fees and a leaver keeps
///         what he earned. What arrives while nobody holds shares is carried into the next accrual. No management or
///         performance fee.
/// @dev    A line-by-line port of `LPFeeVault` in `model/model.py` (its accounting; the pool is the vault's), replayed
///         against it wei for wei (`test_diff_lpAccountingMatchesModel`). Shares are liquidity units.
abstract contract LPFeeAccounting {
    uint256 public constant PREC = 1e36;
    uint256 public constant PERIOD = 7 days;

    uint256 public immutable t0;
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    uint256[3] public acc; // per share, PREC
    uint256[3] public unassigned; // arrived while totalShares == 0: rolled into the next accrual
    mapping(address => uint256[3]) internal _snap;
    mapping(address => uint256[3]) internal _owed;
    EpochStream.State public stream;

    error SharesExceeded();

    constructor() {
        t0 = block.timestamp;
        stream.last = block.timestamp;
    }

    function _accrue(uint256 k, uint256 amount) internal {
        amount += unassigned[k];
        if (totalShares == 0) {
            unassigned[k] = amount;
            return;
        }
        unassigned[k] = 0;
        acc[k] += amount * PREC / totalShares;
    }

    function _stream() internal {
        EpochStream.State memory s = stream;
        acc[2] += EpochStream.advance(s, t0, PERIOD, totalShares, block.timestamp);
        stream = s;
    }

    function _settle(address who) internal {
        _stream();
        for (uint256 k = 0; k < 3; k++) {
            _owed[who][k] += shares[who] * (acc[k] - _snap[who][k]) / PREC;
            _snap[who][k] = acc[k];
        }
    }

    function _collectFees(uint256 fee0, uint256 fee1) internal {
        _accrue(0, fee0);
        _accrue(1, fee1);
    }

    function _notifyIncentive(uint256 amount) internal {
        _stream();
        stream.queued += amount * PREC; // queued for the next epoch; no earlier schedule is touched
    }

    function _addShares(address who, uint256 liquidity) internal {
        _settle(who);
        shares[who] += liquidity;
        totalShares += liquidity;
    }

    function _removeShares(address who, uint256 liquidity) internal {
        if (shares[who] < liquidity) revert SharesExceeded();
        _settle(who);
        shares[who] -= liquidity;
        totalShares -= liquidity;
    }

    function _claimOwed(address who) internal returns (uint256[3] memory out) {
        _settle(who);
        out = _owed[who];
        delete _owed[who];
    }

    // --- views --------------------------------------------------------------------------------------------------------

    /// @notice what `who` could claim now: fees in token0, fees in token1, reward tokens.
    function pending(address who) public view returns (uint256[3] memory out) {
        EpochStream.State memory s = stream;
        uint256 inc = EpochStream.advance(s, t0, PERIOD, totalShares, block.timestamp);
        for (uint256 k = 0; k < 3; k++) {
            uint256 a = acc[k] + (k == 2 ? inc : 0);
            out[k] = _owed[who][k] + shares[who] * (a - _snap[who][k]) / PREC;
        }
    }

    function snapOf(address who) external view returns (uint256[3] memory) {
        return _snap[who];
    }

    function owedOf(address who) external view returns (uint256[3] memory) {
        return _owed[who];
    }
}
