"""Checks every figure quoted in docs/RESULTS.md and docs/WHITEPAPER.md against the run that produced it.

`check_manifest.py` proves that a file is the one the results were taken from. It cannot prove that the sentence next to
the hash still quotes the right number, and that is exactly how `docs/RESULTS.md` came to record a pay-out shift of 40 wei
for a case the scenario prints as 50.

So figures are not typed. A figure appears in the document as

    <!-- fig:scenarios.claim_order_shift_wei -->50<!-- /fig -->

which renders as the bare value, and `model/results/figures.json` holds what the producers last recorded (see
`figures.py`). This script compares the two in BOTH directions: a marker naming a figure nobody records, and a recorded
figure neither document quotes, are both failures -- the second because an unquoted figure is a measurement the documents
silently stopped depending on. The whitepaper is held to the same rule: it once quoted a pay-out shift of 40 wei and a
mutant kill count of 10 after the runs said 50 and 13.

    python3 check_figures.py            verify
    python3 check_figures.py --write    rewrite both documents from figures.json (then read the diff)

Producers, each rewriting only its own group:
    python3 test_scenarios.py · python3 test_econ_sim.py · python3 fuzz.py 30 300 · python3 fuzz_oracle.py 200 150 · python3 mutants.py
    python3 ../contracts/script/export_vectors.py .   (vector counts and the number of declared Foundry tests)
    python3 study_figures.py                          (tables and figures from the committed pilot and beta studies)
"""
import os
import re
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
import figures  # noqa: E402

DOCUMENTS = ["../docs/RESULTS.md", "../docs/WHITEPAPER.md"]
MARKER = re.compile(r"<!-- fig:([A-Za-z0-9_.]+) -->(.*?)<!-- /fig -->", re.S)
PRODUCERS = {
    "scenarios": "python3 test_scenarios.py",
    "econ_sim": "python3 test_econ_sim.py",
    "fuzz": "python3 fuzz.py 30 300",
    "fuzz_oracle": "python3 fuzz_oracle.py 200 150",
    "mutants": "python3 mutants.py",
    "contracts": "python3 ../contracts/script/export_vectors.py .",
    "studies": "python3 study_figures.py",
}


def flatten(all_figs):
    return {f"{group}.{name}": text for group, figs in all_figs.items() for name, text in figs.items()}


def main(write=False):
    all_figs = figures.load()
    flat = flatten(all_figs)
    bad = []
    for group, cmd in PRODUCERS.items():
        if group not in all_figs:
            bad.append(f"group {group!r} has never been recorded: run `{cmd}`")

    cited, quoted = set(), 0
    for doc in DOCUMENTS:
        name = doc.split("/")[-1]
        text = open(doc, encoding="utf-8").read()
        if write:
            new = MARKER.sub(lambda m: f"<!-- fig:{m.group(1)} -->{flat.get(m.group(1), m.group(2))}<!-- /fig -->", text)
            if new != text:
                open(doc, "w", encoding="utf-8").write(new)
                print(f"rewrote {doc}")
            text = new
        found = MARKER.findall(text)
        if not found:
            bad.append(f"{name} contains no fig markers at all")
        # CommonMark lets an HTML comment interrupt a paragraph: a line that OPENS with an inline marker becomes a raw HTML
        # block, the sentence splits, and markdown inside it (backticks, bold) prints literally. Four lines of RESULTS.md
        # were broken that way. A figure whose value starts with a newline is a block (a table) and may open a line.
        for n, line in enumerate(text.splitlines(), 1):
            m = re.match(r"<!-- fig:([A-Za-z0-9_.]+) -->", line)
            if m and not flat.get(m.group(1), "").startswith("\n"):
                bad.append(f"{name}:{n}: an inline marker opens the line, which breaks the paragraph when rendered; "
                           "put a word in front of it")
        quoted += len(found)
        for key, shown in found:
            cited.add(key)
            if key not in flat:
                bad.append(f"{name}: {key} is quoted but no run records it")
            elif shown != flat[key]:
                bad.append(f"{name}: {key}: the document says {shown.strip()[:60]!r}, the run recorded {flat[key].strip()[:60]!r}")
    for key in sorted(flat):
        if key not in cited:
            bad.append(f"{key}: recorded but quoted in neither document")

    if bad:
        print("\n".join(bad))
        print("\nRe-run the producers above, then `python3 check_figures.py --write`, then read the diff.")
        return 1
    print(f"figures: {quoted} quoted in {len(DOCUMENTS)} documents, all {len(flat)} recorded figures cited, every value matches")
    return 0


if __name__ == "__main__":
    sys.exit(main(write="--write" in sys.argv[1:]))
