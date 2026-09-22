# Reference model

Python 3, standard library only, exact integer arithmetic, full rollback on revert. `docs/SPEC.md` is the reference for the rules; this is their reference implementation; a discrepancy is an open issue.

| file | what it is |
| --- | --- |
| `model.py` | core: Troves, both debt ledgers, Stability Pool, liquidation, redistribution, bad debt, redemption, built-in debt cap, staged settlement, fixed-epoch reward streams, revenue hand-over, one-shot deployment, oracle feed |
| `test_scenarios.py` | 30 scenarios (`python3 test_scenarios.py`) |
| `fuzz.py`, `fuzz_oracle.py` | accounting fuzzer with invariants before and after every step; oracle-detection properties F1–F9 |
| `mutants.py` | 32 mutants, one at a time (`python3 mutants.py M30`) |
| `econ_sim.py`, `test_econ_sim.py` | agent-based simulator on top of the core, and its self-tests |
| `pilot_sweep.py`, `beta_pilot_compare.py` | the studies whose results are in `docs/RESULTS.md`; outputs in `results/` |
| `spec_check.py` | verifies the rule-to-test mapping of `docs/SPEC.md` |
| `COVERAGE.md` | what is checked where, and what is not modelled |
