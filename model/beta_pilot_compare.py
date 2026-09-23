"""beta on the SAME footing as the pilot: the real fixed-range pool, finite budgets, identical ETH path per seed (own random stream),
beta sampled once per redemption. In this pool the price cannot leave 0.99-1.01, so peg-deviation statistics are NOT a quality measure;
what differs between policies is how much selling the pool could not serve, how much had to be redeemed, and who left.
    python3 beta_pilot_compare.py <first> <last> <seeds>"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
_os.makedirs("results/generated", exist_ok=True)
import json, statistics, sys
from dataclasses import replace
from econ_sim import Params, run
from pilot_sweep import PILOT
POL = {"beta = 1": dict(beta=1), "beta = 2": dict(beta=2), "beta = 4": dict(beta=4),
       "pressure formula": dict(beta_policy="pressure"), "size formula": dict(beta_policy="size")}
SHOCK = {"calm + 10% dump": {}, "ETH -40% / 24h": dict(crash_day=90)}
jobs = [(sn, pn) for sn in SHOCK for pn in POL]
lo, hi, seeds = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
for sn, pn in jobs[lo:hi]:
    cfg = {**PILOT, **SHOCK[sn], **POL[pn]}
    rows = [run(replace(Params(), seed=sd, **cfg)) for sd in range(seeds)]
    col = lambda k: [float(r[k]) for r in rows]
    out = dict(shock=sn, policy=pn, seeds=seeds, unfilled=statistics.mean(col("unfilled_sell_pct")), edge=statistics.mean(col("pct_time_at_range_edge")),
               mean_dev=statistics.mean(col("mean_dev_pct")), redeemed=statistics.mean(col("redeemed_pct_supply")), self_redeemed=statistics.mean(col("self_redeemed")),
               exits=statistics.mean(col("exits")), opened=statistics.mean(col("opened")), supply=statistics.mean(col("final_supply")),
               keeper=statistics.mean(col("arb_profit")), lp=statistics.mean(col("lp_pnl_settlement_pct")))
    open("results/generated/beta_pilot_compare.jsonl", "a").write(json.dumps(out) + "\n")
    print(f"{sn:16s} {pn:20s} unfilled={out['unfilled']:.1f}% edge={out['edge']:.1f}% dev={out['mean_dev']:.3f}% redeemed={out['redeemed']:.0f}% "
          f"self={out['self_redeemed']:,.0f} exits={out['exits']:.1f}/{out['opened']:.0f} supply={out['supply']:,.0f} LP={out['lp']:+.1f}%", flush=True)
