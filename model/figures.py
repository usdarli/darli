"""
Figures of record.

`docs/RESULTS.md` is the only place a document may take a number from, and until now those numbers were typed into it by
hand. A hand-typed number goes stale silently: `check_manifest.py` hashes the files a figure depends on, so it catches a
changed file, but it cannot see that the sentence next to the hash still quotes the old value.

So no figure is typed any more. The test that computes a number records it here with `fig()`, the run writes
`results/figures.json`, and `check_figures.py` compares every `<!-- fig:NAME -->value<!-- /fig -->` marker in
`docs/RESULTS.md` against that file, in both directions: a marker with no figure and a figure with no marker are both
failures. Regenerate the document with `python3 check_figures.py --write`.

Figures are grouped by producer, because producers run separately and each rewrites only its own group:

    scenarios     python3 test_scenarios.py
    econ_sim      python3 test_econ_sim.py
    fuzz          python3 fuzz.py 30 300          (the recorded configuration; other sizes record nothing)
    fuzz_oracle   python3 fuzz_oracle.py 200 150  (likewise)
    mutants       python3 mutants.py              (the whole set)
    contracts     python3 contracts/script/export_vectors.py model   (vector counts, declared Foundry tests)
    studies       python3 study_figures.py        (tables and figures from the committed pilot and beta studies)
"""
import json
import os

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "figures.json")

_recorded = {}


def fig(name, value, spec=""):
    """Record `value` under `name` and return it unchanged, so the call can wrap the expression that produces it.

    `spec` is a `format()` specification, so the figure is stored exactly as the document prints it (`.4f`, `,`, ...).
    Recording the same name twice with different text is an error: two tests that disagree about a figure must not
    both quietly write to the document."""
    text = format(value, spec) if spec else str(value)
    if name in _recorded and _recorded[name] != text:
        raise AssertionError(f"figure {name!r} recorded twice and disagreed: {_recorded[name]!r} then {text!r}")
    _recorded[name] = text
    return value


def load():
    try:
        with open(PATH, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def dump(group):
    """Merge everything recorded in this process into `group`, replacing that group entirely.

    Replacing rather than updating is deliberate: a figure that a test stops producing must disappear from the file, so
    that `check_figures.py` reports its now-orphaned marker in the document."""
    all_figs = load()
    all_figs[group] = dict(sorted(_recorded.items()))
    os.makedirs(os.path.dirname(PATH), exist_ok=True)
    with open(PATH, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(all_figs.items())), f, indent=2, sort_keys=True)
        f.write("\n")
    return len(_recorded)
