# Contributing

Start with `AGENTS.md`: it applies to humans as much as to agents. Then `make help`.

Run `make smoke` before you change anything and `make check` before you open a pull request; CI runs the same targets,
so nothing passes here that would fail there.

- Every change to a rule starts in `docs/SPEC.md` and in `model/`, with a scenario that pins it and, where possible, a mutant that would be caught. `python3 model/spec_check.py` and `python3 model/check_manifest.py` must pass (they can be run from any directory).
- Every number in the documents comes from `docs/RESULTS.md`, and every number there is recorded by the run that computes it: use `fig()` from `model/figures.py` at the line that produces it, then `python3 model/check_figures.py --write`. Do not type a figure into a document.
- Solidity math must match the model bit-for-bit (`contracts/test/*Differential*`).
- Report security issues privately (see `SECURITY.md`); do not open public issues for them.
