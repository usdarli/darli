# Contributing

Start with `AGENTS.md`: it applies to humans as much as to agents. Then `make help`.

Run `make smoke` before you change anything and `make check` before you open a pull request; CI runs the same targets,
so nothing passes here that would fail there.

- Every change to a rule starts in `docs/SPEC.md` and in `model/`, with a scenario that pins it and, where possible, a mutant that would be caught. `python3 model/spec_check.py` and `python3 model/check_manifest.py` must pass (they can be run from any directory).
- Every measured number in `docs/RESULTS.md` and `docs/WHITEPAPER.md` is recorded by the run that computes it: use `fig()` from `model/figures.py` at the line that produces it, then `make record`. Do not type a measured figure into a document, and never start a line with an inline marker (CommonMark then breaks the paragraph; `check_figures.py` refuses it).
- Solidity math must match the model bit-for-bit (`contracts/test/*Differential*`).
- Report security issues privately (see `SECURITY.md`); do not open public issues for them.
