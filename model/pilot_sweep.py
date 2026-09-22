"""
The PROPOSED PILOT, exactly as the whitepaper states it, with finite budgets. Per-seed results are written out;
the table shows mean / median / worst.       python3 pilot_sweep.py <first> <last> <seeds>
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
_os.makedirs("results/generated", exist_ok=True)
import json, statistics, sys
from dataclasses import replace
from econ_sim import Params, run

PILOT = dict(pool_model="range", range_width=0.01, pool_usd=30_000, beta=4, initial_base_rate=0.10,
             min_debt=500, avg_trove=2_000, launch_debt=60_000,            # users' first-week borrowing
             team_collateral_usd=90_000, sp_seed=20_000,                   # team trove mints pool side + SP seed (~35k)
             cap_initial=125_000, cap_ceiling=250_000,              # built-in schedule: doubles by itself on day 30
             upper_keeper_budget_usd=40_000, topup_reserve_frac=0.3)
import os
VARIANT = dict(settlement_surplus_absorbs=(os.environ.get("VAULT_PARITY") != "1"))   # VAULT_PARITY=1 -> borrowers' surplus protected
CASES = {
    "pilot, calm + 10% dump": {},
    "ETH -40% in 24h, network up": dict(crash_day=90),
    "ETH -40%, feed dead 12h, network up": dict(crash_day=90, feed_outage_hours=12),
    "ETH -40% during 12h sequencer outage": dict(crash_day=90, outage_hours=12),
    "ETH -60% in 24h, network up": dict(crash_day=90, crash_size=0.60),
    "ETH -60% during 24h sequencer outage": dict(crash_day=90, crash_size=0.60, outage_hours=24),
}
KEYS = ["shutdown", "shutdown_day", "min_tcr", "holder_recovery", "worst_holder_recovery", "sp_liq_pnl", "redistributed",
        "uncovered_bad_debt", "lp_pnl_nominal_pct", "lp_pnl_market_pct", "lp_pnl_settlement_pct", "unfilled_sell_pct",
        "final_supply", "exits", "liquidations", "upper_keeper_collateral", "upper_blocked_hours", "min_econ_backing", "share_losing", "share_zero", "best_holder_recovery", "borrowers_surplus_value", "total_backing_at_settlement", "reference_vs_market", "keeper_pnl_usd",
        "redeemed_pct_supply", "self_redeemed"]
def main():
    lo, hi, seeds = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    for name, over in list(CASES.items())[lo:hi]:
        rows = []
        for sd in range(seeds):
            r = run(replace(Params(), seed=sd, **{**PILOT, **VARIANT, **over}))
            rows.append(r)
            open("results/generated/pilot_seeds" + ("_parity" if os.environ.get("VAULT_PARITY") == "1" else "") + ".jsonl", "a").write(json.dumps(dict(case=name, seed=sd, **{k: r[k] for k in KEYS})) + "\n")
        def col(k):
            v = [float(r[k]) for r in rows]
            return v
        n_shut = sum(1 for r in rows if r["shutdown"])
        rec, sp, tcr, lp = col("holder_recovery"), col("sp_liq_pnl"), col("min_econ_backing"), col("lp_pnl_settlement_pct")
        worst_acct, losing, zero, best, kp = col("worst_holder_recovery"), col("share_losing"), col("share_zero"), col("best_holder_recovery"), col("keeper_pnl_usd")
        days = [r["shutdown_day"] for r in rows if r["shutdown"]]
        summary = dict(case=name, seeds=seeds, shutdowns=n_shut, shutdown_days=days,
                       min_tcr=dict(mean=statistics.mean(tcr), median=statistics.median(tcr), worst=min(tcr)),
                       holder_recovery=dict(mean=statistics.mean(rec), median=statistics.median(rec), worst=min(rec)),
                       sp_liq_pnl=dict(mean=statistics.mean(sp), median=statistics.median(sp), worst=min(sp)),
                       lp_settlement_pct=dict(mean=statistics.mean(lp), median=statistics.median(lp), worst=min(lp)),
                       lp_nominal_pct_mean=statistics.mean(col("lp_pnl_nominal_pct")),
                       redistributed_mean=statistics.mean(col("redistributed")), uncovered_worst=max(col("uncovered_bad_debt")),
                       worst_account_recovery=min(worst_acct), share_losing_mean=statistics.mean(losing), share_losing_worst=max(losing),
                       share_zero_worst=max(zero), max_spread_between_accounts=max(b_ - w_ for b_, w_ in zip(best, worst_acct)),
                   borrowers_surplus_mean=statistics.mean(col("borrowers_surplus_value")),
                       keeper_pnl=dict(mean=statistics.mean(kp), worst=min(kp)),
                       upper_blocked_hours_mean=statistics.mean(col("upper_blocked_hours")),
                       final_supply_mean=statistics.mean(col("final_supply")))
        open("results/generated/pilot_summary" + ("_parity" if os.environ.get("VAULT_PARITY") == "1" else "") + ".jsonl", "a").write(json.dumps(summary) + "\n")
        print(f"{name:40s} shut={n_shut}/{seeds} econBacking mean/worst={summary['min_tcr']['mean']:.2f}/{summary['min_tcr']['worst']:.2f} "
              f"recovery mean/worst={summary['holder_recovery']['mean']:.3f}/{summary['holder_recovery']['worst']:.3f} "
              f"SP mean/worst={summary['sp_liq_pnl']['mean']:+.0f}/{summary['sp_liq_pnl']['worst']:+.0f} "
              f"LPsettle mean/worst={summary['lp_settlement_pct']['mean']:+.1f}/{summary['lp_settlement_pct']['worst']:+.1f}% "
              f"worstAcct={summary['worst_account_recovery']:.2f} losing mean/worst={summary['share_losing_mean']:.0%}/{summary['share_losing_worst']:.0%} "
              f"spread={summary['max_spread_between_accounts']:.4f} borrowersKeep={summary['borrowers_surplus_mean']:,.0f} "
          f"keeperPnL mean/worst={summary['keeper_pnl']['mean']:+.0f}/{summary['keeper_pnl']['worst']:+.0f} "
              f"blockedH={summary['upper_blocked_hours_mean']:.0f} supply={summary['final_supply_mean']:.0f}", flush=True)



if __name__ == "__main__":
    main()
