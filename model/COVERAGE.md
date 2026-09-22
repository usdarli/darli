# Coverage

## Checked before and after every fuzzer step (`check_invariants`)
supply = Σ aggDebt · debt identity with ε ≥ 0 · aggW = 0 after shutdown · vault accounting against every named account · Stability Pool solvency ·
escrow and frontend totals · no ownerless bad-debt collateral · every named pool ≥ 0 · gas pool = Σ per-Trove deposits · no Trove pays more reward than its deposit.

## Checked by the fuzzer loop
staking contract covers its liabilities · nobody paid during settlement phase 1 · late and surplus entitlements ≤ their pools · the deposit paths are exercised.

## Checked by dedicated scenarios
per-depositor Stability Pool exactness against a rational shadow (17) · settlement order independence, every permutation (22) · settlement path independence,
32 combinations against an independent computation (30) · completion of settlement with 1,500 Troves and a never-settled Trove (27) · late-recovery ownership (29) ·
oracle failure detection (20) and `fuzz_oracle.py` F1–F9 · one-shot deployment and the pool race (26) · fixed-epoch reward streams (04, 19, 24).

## Mutants
32 mutants, each killed by at least one scenario (`python3 mutants.py`: 32 run, 32 killed, 0 survived, 0 invalid on the release commit). Inside the harness (fuzz 12 x 250, fuzz_oracle 80 x 120) the accounting fuzzer kills M1, M2, M30 and M42 on its own and the oracle fuzzer kills M3, M11, M12, M13, M14 and M15 on its own; every other mutant is killed only by scenarios.

## Not modelled
sorted list and insertion hints · batch managers · LST pricing · real gas · Uniswap position maths and token amounts · zappers · a persistent revert inside the
parts shared by settlement and write-off · calibrated agent behaviour in the simulator.
