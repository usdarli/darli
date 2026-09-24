// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title EpochStream
/// @notice Fixed epochs (`docs/SPEC.md` V4, V6): whatever is handed over during epoch k waits in `queued` and is streamed,
///         second by second, over epoch k + 1 at a rate fixed at the boundary. A later hand-over never touches an earlier
///         schedule, so nothing can postpone a payout. What streams while nobody holds shares waits in `idle` and joins the
///         next epoch. Amounts are scaled by the owner's precision.
/// @dev    `EpochStream` in `model/model.py`, shared by DARLI staking and the liquidity vault. `advance` walks one turn per
///         epoch boundary crossed while the stream has anything to pay, and skips the rest of the time in one step once it
///         is empty.
library EpochStream {
    struct State {
        uint256 last;
        uint256 rate; // per second, scaled
        uint256 queued; // waits for the next boundary
        uint256 idle; // streamed while nobody held shares
    }

    function epochEnd(uint256 t0, uint256 period, uint256 t) internal pure returns (uint256) {
        return t0 + ((t - t0) / period + 1) * period;
    }

    /// Advances `s` to `nowTs` and returns the per-share increment. `total` is constant over the interval: the owner
    /// advances the stream before every change of shares.
    function advance(State memory s, uint256 t0, uint256 period, uint256 total, uint256 nowTs)
        internal
        pure
        returns (uint256 inc)
    {
        while (s.last < nowTs) {
            uint256 end = epochEnd(t0, period, s.last);
            if (end > nowTs) end = nowTs;
            uint256 streamed = s.rate * (end - s.last);
            if (total != 0) {
                inc += streamed / total;
            } else {
                s.idle += streamed;
            }
            s.last = end;
            if ((end - t0) % period == 0) {
                // boundary: what waited, and what nobody held shares to receive, is the next epoch's
                uint256 tot = s.queued + s.idle;
                s.rate = tot / period;
                s.queued = tot - s.rate * period;
                s.idle = 0;
            }
            if (s.rate == 0 && s.queued == 0 && s.idle == 0) {
                s.last = nowTs;
            }
        }
    }

    /// Scaled amount not yet streamed: the rest of the running epoch and what waits for the next one.
    function unstreamed(State memory s, uint256 t0, uint256 period) internal pure returns (uint256) {
        return s.rate * (s.rate != 0 ? epochEnd(t0, period, s.last) - s.last : 0) + s.queued + s.idle;
    }
}
