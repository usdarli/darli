"""
Figures and tables from the committed study results, for docs/RESULTS.md and docs/WHITEPAPER.md.

The pilot and beta studies are slow (pilot_sweep.py runs 120 simulations), so CI does not re-run them. Their output is
committed under results/ and hashed in the manifest. This producer turns that committed data into every figure and table
the two documents quote from it. Before it existed both documents carried hand-copied tables and sentences, and several
had drifted from the data: the worst recovery "in the 40% cases" was quoted as 0.97 where the data says 0.96; a keeper
"range" paired the worst single run with the best case average and understated the upside about sevenfold; "five times
fewer borrower exits" was 6.0 in the data.

    python3 study_figures.py

Note on names: the summary key `min_tcr` holds ECONOMIC BACKING (all collateral at the market price over all debt), not
the contract-visible TCR; pilot_sweep.py fills it from `min_econ_backing`. The documents label it correctly. Renaming the
key would mean regenerating the committed study, so the name stays and this note records what it holds.
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import json  # noqa: E402

from econ_sim import Params  # noqa: E402
from figures import dump, fig  # noqa: E402
from pilot_sweep import PILOT  # noqa: E402


def load(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


summary = load("results/pilot_summary.jsonl")
seeds = load("results/pilot_seeds.jsonl")
beta = load("results/beta_pilot_compare.jsonl")

calm = summary[0]
assert calm["case"].startswith("pilot, calm"), "the first pilot case must be the calm reference run"
crashes = summary[1:]
runs = {s["seeds"] for s in summary}
assert len(runs) == 1, f"pilot cases were run with different numbers of seeds: {runs}"
(n_runs,) = runs
assert "days" not in PILOT, "the pilot overrides the run length; read it from PILOT, not Params()"

# --- the pilot table, as docs/RESULTS.md shows it (every column the study records) ---------------------------------------
head = (f"| case | shutdowns / {n_runs} | min economic backing mean / median / worst | holders' recovery mean / median / worst run "
        "| worst account | best minus worst account (max over runs) | balances losing >=1%: mean / worst run "
        "| borrowers' surplus kept (mean, USD) | SP result mean / worst | LP settlement % mean / worst |\n"
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
rows = []
for s in summary:
    b, r, sp, lp = s["min_tcr"], s["holder_recovery"], s["sp_liq_pnl"], s["lp_settlement_pct"]
    rows.append(f"| {s['case']} | {s['shutdowns']} | {b['mean']:.2f} / {b['median']:.2f} / {b['worst']:.2f} "
                f"| {r['mean']:.3f} / {r['median']:.3f} / {r['worst']:.3f} | {s['worst_account_recovery']:.2f} "
                f"| {s['max_spread_between_accounts']:.6f} | {s['share_losing_mean']:.0%} / {s['share_losing_worst']:.0%} "
                f"| {s['borrowers_surplus_mean']:,.0f} | {sp['mean']:+.0f} / {sp['worst']:+.0f} | {lp['mean']:+.1f} / {lp['worst']:+.1f} |")
fig("pilot_table_results", "\n\n" + head + "\n" + "\n".join(rows) + "\n\n")

# --- the same study, as docs/WHITEPAPER.md shows it (fewer columns, reader-facing labels) ----------------------------------
LABEL = {
    "pilot, calm + 10% dump": "none (calm, one 10% sale)",
    "ETH -40% in 24h, network up": "−40% in a day, network up",
    "ETH -40%, feed dead 12h, network up": "−40%, price feed dead for 12 hours",
    "ETH -40% during 12h sequencer outage": "−40% during a 12-hour sequencer outage",
    "ETH -60% in 24h, network up": "−60% in a day, network up",
    "ETH -60% during 24h sequencer outage": "**−60% during a 24-hour sequencer outage**",
}
assert set(LABEL) == {s["case"] for s in summary}, "a pilot case has no whitepaper label, or a label has no case"
head = ("| ETH shock on day 90 | Runs that shut down | Lowest economic backing over the whole path, mean / median / worst "
        "| System-wide recovery per USDarli, mean / worst run | Worst single account (100 USDarli or more) "
        "| Share of holders' balances that lost 1% or more, mean / worst run | Stability Pool result, mean / worst "
        "| LP at settlement value, mean / worst |\n| --- | --- | --- | --- | --- | --- | --- | --- |")
rows = []
for s in summary:
    b, r, sp, lp = s["min_tcr"], s["holder_recovery"], s["sp_liq_pnl"], s["lp_settlement_pct"]
    rows.append(f"| {LABEL[s['case']]} | {s['shutdowns']} of {s['seeds']} | {b['mean']:.0%} / {b['median']:.0%} / {b['worst']:.0%} "
                f"| {r['mean']:.3f} / {r['worst']:.2f} | {s['worst_account_recovery']:.2f} "
                f"| {s['share_losing_mean']:.0%} / {s['share_losing_worst']:.0%} | {sp['mean']:+,.0f} / {sp['worst']:+,.0f} "
                f"| {lp['mean']:+.1f}% / {lp['worst']:+.1f}% |")
fig("pilot_table_whitepaper", "\n\n" + head + "\n" + "\n".join(rows) + "\n\n")

# --- scalars the prose quotes ------------------------------------------------------------------------------------------------
fig("pilot_runs_per_case", n_runs)
fig("pilot_days", Params().days)
# "zero in every run" was the claim; the data holds 4.4e-16, the simulator's floating-point rounding of a recovery ratio
# (econ_sim works in floats; model.py does not). Quoted as what it is, so the sentence cannot overstate exactness.
spread = max(s["max_spread_between_accounts"] for s in summary)
assert spread < 1e-12, f"accounts were paid differently by {spread}: that is a finding, not rounding"
fig("pilot_max_spread_between_accounts", spread, ".0e")
fig("pilot_worst_recovery_40pct_cases", min(s["holder_recovery"]["worst"] for s in summary if "-40%" in s["case"]), ".2f")
fig("pilot_lp_calm_settlement_return_pct", calm["lp_settlement_pct"]["mean"], "+.1f")
fig("pilot_lp_worst_settlement_loss_pct", -min(s["lp_settlement_pct"]["worst"] for s in summary), ".1f")
worst_lp = min(seeds, key=lambda r: r["lp_pnl_settlement_pct"])            # the same run, valued at a nominal one dollar
assert abs(worst_lp["lp_pnl_settlement_pct"] - min(s["lp_settlement_pct"]["worst"] for s in summary)) < 1e-9
fig("pilot_lp_worst_run_nominal_pct", worst_lp["lp_pnl_nominal_pct"], "+.1f")
# "holders recovered at least ... in every run" is claimed for the cases in which the network stayed up, so keepers could
# act every hour. The sequencer-outage cases are excluded by name, not by value, so the figure means what the sentence says.
fig("pilot_worst_recovery_network_up",
    min(s["holder_recovery"]["worst"] for s in summary if "sequencer outage" not in s["case"]), ".2f")

# the upper-side keeper treasury: two different statistics, kept apart
fig("keeper_budget_usd", PILOT["upper_keeper_budget_usd"], ",")
fig("keeper_blocked_hours_calm_mean", calm["upper_blocked_hours_mean"], ".0f")
fig("keeper_blocked_hours_crash_mean_min", min(s["upper_blocked_hours_mean"] for s in crashes), ".0f")
fig("keeper_blocked_hours_crash_mean_max", max(s["upper_blocked_hours_mean"] for s in crashes), ".0f")
fig("keeper_pnl_calm_mean_usd", calm["keeper_pnl"]["mean"], ",.0f")     # quoted as "earned N dollars": unsigned
fig("keeper_pnl_case_mean_min_usd", min(s["keeper_pnl"]["mean"] for s in summary), "+,.0f")
fig("keeper_pnl_case_mean_max_usd", max(s["keeper_pnl"]["mean"] for s in summary), "+,.0f")
fig("keeper_pnl_single_run_min_usd", min(r["keeper_pnl_usd"] for r in seeds), "+,.0f")
fig("keeper_pnl_single_run_max_usd", max(r["keeper_pnl_usd"] for r in seeds), "+,.0f")

# --- the beta study ----------------------------------------------------------------------------------------------------------
head = ("| shock | policy | sell volume the pool could not fill | redeemed (% of supply) | of which by stuck sellers themselves "
        "| borrower exits / opened | final supply | LP at settlement value |\n| --- | --- | --- | --- | --- | --- | --- | --- |")
rows = [f"| {b['shock']} | {b['policy']} | {b['unfilled']:.1f}% | {b['redeemed']:.0f}% | {b['self_redeemed']:,.0f} "
        f"| {b['exits']:.1f} / {b['opened']:.0f} | {b['supply']:,.0f} | {b['lp']:+.1f}% |" for b in beta]
fig("beta_table_results", "\n\n" + head + "\n" + "\n".join(rows) + "\n\n")
by = {(b["shock"].split()[0], b["policy"]): b for b in beta}
b1, b4 = by[("calm", "beta = 1")], by[("calm", "beta = 4")]
c1, c4 = by[("ETH", "beta = 1")], by[("ETH", "beta = 4")]
fig("beta_redeemed_pct_beta1_calm", b1["redeemed"], ".0f")
fig("beta_redeemed_pct_beta4_calm", b4["redeemed"], ".0f")
fig("beta_exit_ratio_calm", b4["exits"] / b1["exits"], ".1f")
fig("beta_exit_ratio_crash40", c4["exits"] / c1["exits"], ".1f")

print(f"figures: {dump('studies')} recorded from the committed study results")
