"""Checks every figure quoted in docs/RESULTS.md against the run that produced it.

`check_manifest.py` proves that a file is the one the results were taken from. It cannot prove that the sentence next to
the hash still quotes the right number, and that is exactly how `docs/RESULTS.md` came to record a pay-out shift of 40 wei
for a case the scenario prints as 50.

So figures are not typed. A figure appears in the document as

    <!-- fig:scenarios.claim_order_shift_wei -->50<!-- /fig -->

which renders as the bare value, and `model/results/figures.json` holds what the producers last recorded (see
`figures.py`). This script compares the two in BOTH directions: a marker naming a figure nobody records, and a recorded
figure the document never quotes, are both failures -- the second because an unquoted figure is a measurement the
document silently stopped depending on.

    python3 check_figures.py            verify
    python3 check_figures.py --write    rewrite docs/RESULTS.md from figures.json (then read the diff)

Producers, each rewriting only its own group:
    python3 test_scenarios.py · python3 test_econ_sim.py · python3 fuzz.py 30 300 · python3 fuzz_oracle.py 200 150 · python3 mutants.py
    python3 ../contracts/script/export_vectors.py .   (vector counts and the number of declared Foundry tests)
"""
import os
import re
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
import figures  # noqa: E402

RESULTS = "../docs/RESULTS.md"
MARKER = re.compile(r"<!-- fig:([A-Za-z0-9_.]+) -->(.*?)<!-- /fig -->", re.S)
PRODUCERS = {
    "scenarios": "python3 test_scenarios.py",
    "econ_sim": "python3 test_econ_sim.py",
    "fuzz": "python3 fuzz.py 30 300",
    "fuzz_oracle": "python3 fuzz_oracle.py 200 150",
    "mutants": "python3 mutants.py",
    "contracts": "python3 ../contracts/script/export_vectors.py .",
}


def flatten(all_figs):
    return {f"{group}.{name}": text for group, figs in all_figs.items() for name, text in figs.items()}


def main(write=False):
    all_figs = figures.load()
    flat = flatten(all_figs)
    text = open(RESULTS, encoding="utf-8").read()
    found = MARKER.findall(text)

    bad = []
    for group, cmd in PRODUCERS.items():
        if group not in all_figs:
            bad.append(f"group {group!r} has never been recorded: run `{cmd}`")
    if not found:
        bad.append(f"{RESULTS} contains no fig markers at all")

    if write:
        def fill(m):
            key = m.group(1)
            return f"<!-- fig:{key} -->{flat.get(key, m.group(2))}<!-- /fig -->"
        new = MARKER.sub(fill, text)
        if new != text:
            open(RESULTS, "w", encoding="utf-8").write(new)
            print(f"rewrote {RESULTS}")
        else:
            print(f"{RESULTS} was already current")
        text, found = new, MARKER.findall(new)

    cited = set()
    for key, shown in found:
        cited.add(key)
        if key not in flat:
            bad.append(f"{key}: quoted in the document but no run records it")
        elif shown != flat[key]:
            bad.append(f"{key}: document says {shown!r}, the run recorded {flat[key]!r}")
    for key in sorted(flat):
        if key not in cited:
            bad.append(f"{key}: recorded but never quoted in the document")

    if bad:
        print("\n".join(bad))
        print("\nRe-run the producers above, then `python3 check_figures.py --write`, then read the diff.")
        return 1
    print(f"figures: {len(found)} quoted in docs/RESULTS.md, all {len(flat)} recorded figures cited, every value matches")
    return 0


if __name__ == "__main__":
    sys.exit(main(write="--write" in sys.argv[1:]))
