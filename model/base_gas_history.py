"""
Base gas prices over a year, for the gas deposit of SPEC 2.   python3 base_gas_history.py

Every hour of the year before the fork tests' pinned block, `eth_feeHistory`: the base fee of each of the 1,024 blocks
before it (about 34 minutes), and the 50th and 90th percentile priority fee of the last 20. Output: per hour the median and
maximum base fee and the largest 90th-percentile priority fee, committed under results/ and hashed in the manifest;
study_figures.py turns it into the deposit's figures. Needs an archive RPC endpoint; CI does not re-run it.
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import json  # noqa: E402
import sys  # noqa: E402

from oracle_history import END, DAYS, HOUR_BLOCKS, run_calls  # noqa: E402

OUT = "results/base_gas_history.jsonl"


def main():
    hours = [END - k * HOUR_BLOCKS for k in range(DAYS * 24, -1, -1)]
    # base fees of 1,024 blocks per hour; tips (which need every transaction of a block) of the last 20 of them only
    res = run_calls([("eth_feeHistory", [hex(1024), hex(b), []]) for b in hours], chunk=5)
    tip = run_calls([("eth_feeHistory", [hex(20), hex(b), [50, 90]]) for b in hours], chunk=10)
    rows = []
    for b, r, t in zip(hours, res, tip):
        base = [int(x, 16) for x in r["baseFeePerGas"]]
        tips = [int(x[1], 16) for x in t["reward"]]
        rows.append({"block": b, "base_median": sorted(base)[len(base) // 2], "base_max": max(base),
                     "tip90_max": max(tips), "tip50_median": sorted(int(x[0], 16) for x in t["reward"])[len(tips) // 2]})
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(json.dumps({"meta": {"end": END, "days": DAYS, "blocks_per_sample": 1024}}) + "\n")
        for row in rows:
            f.write(json.dumps(row) + "\n")
    print(f"wrote {OUT}: {len(rows)} hourly samples of {len(hours)}", file=sys.stderr)


if __name__ == "__main__":
    main()
