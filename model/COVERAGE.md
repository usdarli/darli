# Coverage

## Checked before and after every fuzzer step (`check_invariants`)
supply = Σ aggDebt · debt identity with ε ≥ 0 · aggW = 0 after shutdown · vault accounting against every named account · Stability Pool solvency ·
escrow and frontend totals · no ownerless bad-debt collateral · every named pool ≥ 0 · gas pool = Σ per-Trove deposits · no Trove pays more reward than its deposit.

## Checked by the fuzzer loop
staking contract covers its liabilities · nobody paid during settlement phase 1 · late and surplus entitlements ≤ their pools · the deposit paths are exercised.
The three pool bounds are **argued, not measured**: the late and surplus entitlements may not exceed their pools by a single wei (every division floors in the
pool's favour), and the staking bound is one wei, which is `liabilities()`'s own deliberate round-up. Derivations sit next to the assertions in `fuzz.py`.

## Coverage floors (`MIN_COVERAGE` in `fuzz.py`)
An invariant that holds over a path never taken proves nothing. The fuzzer therefore asserts a minimum number of **successful** executions per operation,
scaled to the budget, and fails when one is not met. Without it, `claim_late` sat at zero executions and liquidation at 17 in 9,000 steps while the
conformance map claimed fuzzer coverage of both. Floors are enforced only at or above the release budget (30 × 300); a smaller run says in its output that
it is a smoke run. Never lower a floor to make a run pass: a fallen count means a path became unreachable, and that is the finding.

## Mutants
Every mutant is killed and none is invalid; the counts are recorded figures in `docs/RESULTS.md`. The split between what the scenarios pin and what the random testers find on their own is a **recorded figure**, not a
claim: see "What the random testers kill on their own" in `docs/RESULTS.md`. `python3 mutants.py` prints the attribution per mutant.

## Checked by dedicated scenarios
per-depositor Stability Pool exactness against a rational shadow (17) · settlement order independence, every permutation (22) · settlement path independence,
32 combinations against an independent computation (30) · completion of settlement with 1,500 Troves and a never-settled Trove (27) · late-recovery ownership (29) ·
oracle failure detection (20) and `fuzz_oracle.py` F1–F9 · redemption order with tied rates, expected queues written by hand (31) · one-shot deployment and the pool race (26) · fixed-epoch reward streams (04, 19, 24).

## Not modelled
batch managers · LST pricing · real gas · Uniswap position maths and token amounts · zappers · a persistent revert inside the
parts shared by settlement and write-off · calibrated agent behaviour in the simulator.
