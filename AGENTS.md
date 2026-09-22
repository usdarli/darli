# AGENTS.md

Instructions for AI coding agents (and humans using them) working in this repository. Read this before touching anything. Where this file and `docs/SPEC.md` disagree, `docs/SPEC.md` wins for protocol rules; this file wins for process.

## 1. What this repository is

Darli is an immutable, ETH-backed stablecoin protocol. **Immutable means that a bug shipped in the contracts can never be patched.** Every rule therefore exists three times, and the three must agree:

1. `docs/SPEC.md` — the normative rules (what the protocol promises), each with the identifier of the test that pins it.
2. `model/` — the executable reference model in Python (exact integer arithmetic, standard library only) and its tests.
3. `contracts/` — the Solidity implementation (Foundry), checked bit-for-bit against the model where it exists.

A disagreement between any two of them is an open issue, never something to resolve by silently changing one of them.

## 2. Ground rules

- **Never weaken a test to make it pass.** If a scenario, invariant, fuzzer property or mutant fails after your change, either your change is wrong or the rule is wrong; say which, and if it is the rule, change `docs/SPEC.md` first and explain why.
- **Never widen a tolerance** (`<= 2`, `<= 6 wei`, `assertApproxEqRel`) without an argued bound written next to it. Tolerances in this repository are bounds, not fudge.
- **Never change a deployment constant** (`docs/SPEC.md` §2) as a side effect of another task. Constants are frozen for ever at deployment; changing one is a decision for the maintainers, not a fix.
- **Never add a governance, owner, pause, upgrade or admin path**, however small, however convenient. No `onlyOwner`, no proxy, no setter, no "emergency" function. If a task seems to require one, stop and report.
- **Never read a price from the protocol's own pool**, and never make the core depend on Uniswap, the vault or any hook. The core's only external calls are the collateral token, the price feed and the stablecoin.
- **Never make a risk-reducing action depend on a price, an administrative permission or a callback into user code**: `repay`, `addColl`, `closeTrove`, Stability Pool withdrawal, `claimSurplus`, `settleTrove`. Ownership checks on the caller's own Trove and the token transfers themselves are of course required; what is forbidden is any dependency on a price feed, a governance switch, or a call whose failure a third party can cause.
- **Never add a scan over all Troves** in any path reachable after a shutdown. Settlement is constant work per Trove by design (`n_open` counter, batches of 50).
- **Do not invent numbers.** Every figure quoted in a document must come from `docs/RESULTS.md`, which lists the hash of every file it depends on. If you change a file in that manifest, regenerate the affected results or mark the table stale.
- **Rounding direction is a rule**: the protocol rounds up when it mints and down when it pays. Every deviation must be documented at the rule that causes it.

## 3. Before you change anything

    cd model
    python3 test_scenarios.py          # must print 30/30 (or more)
    python3 test_econ_sim.py
    python3 fuzz.py 10 200
    python3 fuzz_oracle.py 50 100
    python3 spec_check.py              # every scenario cited in SPEC.md exists and every scenario is cited
    python3 check_manifest.py          # docs/RESULTS.md manifest matches the files
    python3 mutants.py                 # all mutants killed, none invalid (slow; CI runs it)
    cd ../contracts && forge test

If any of these fails before your change, stop and report; do not start from a broken baseline.

## 4. How to make a change

**A rule change (economics, rights, settlement, oracle, revenue):**
1. Edit `docs/SPEC.md`: the rule, its constant if any, and the test identifier it will carry.
2. Change `model/model.py`.
3. Add or update a scenario in `model/test_scenarios.py` that fails without your change and passes with it. Prefer an *independent* expectation (rational arithmetic from first principles) over asserting what the code returns.
4. Add a mutant to `model/mutants.py` that restores the old behaviour, and check it is killed: `python3 mutants.py M<n>`. A mutant whose target string no longer matches is reported INVALID and fails CI; update it when you refactor the line it targets.
5. If the change touches settlement, staking, the vault or bad debt, extend the fuzzer's operations and properties in `fuzz.py`; the fuzzer has found real bugs that the scenarios missed.
6. Run everything in §3. Regenerate `docs/RESULTS.md` sections that depend on changed files and update the manifest.
7. Update `docs/WHITEPAPER.md` only if a reader-facing promise changed.
8. `python3 spec_check.py` must pass.

**A Solidity change:**
- Math libraries must stay bit-for-bit equal to the model. Regenerate vectors with `python3 script/export_vectors.py ../model` and run the differential tests.
- Reproduce the scenario in Foundry when the scenario's subject exists in Solidity. Test with the real predicted addresses (`vm.computeCreateAddress`), not placeholders.
- Every external call needs a stated reason; `staticcall` with a gas stipend for the feed; no callbacks into user code from the core.
- Anything not yet confirmed on a fork (PoolManager storage layout, feed gas cost, `tickSpacing`) stays marked `TO BE CONFIRMED` in the code comment. Do not remove such a marker without a fork test.

**A documentation change:**
- `docs/SPEC.md` is terse and rule-numbered; do not add narrative to it. Narrative belongs in the whitepaper.
- Do not put review history, round numbers or "was previously" language in the shipped documents. The repository records decisions, not their history.
- Do not add references to other protocols outside the comparison section of the whitepaper.

## 5. Things that look like bugs but are not

- `repay`/`closeTrove` revert with insufficient balance or dust: their own preconditions (SPEC B4, B9).
- Holders recover slightly less than 1.00 after a shutdown with no shortfall: market movement between the reference price and the claim (SPEC X1).
- A claim against an empty pot pays zero but succeeds: it registers claim units that receive later recoveries (SPEC X8). Do not "fix" it into a revert.
- A written-off Trove settled before phase 1 ends reverses the write-off (SPEC X5).
- Payouts differ by a few wei between claim orders: bounded rounding, at most one wei per earlier claim (SPEC X10).
- `gas_deposit` defaults to 0 in the model: the deployment value is an open item, not a bug.

## 6. Things that are genuinely open (do not silently decide them)

See `docs/SPEC.md` §13: β, the gas deposit amount, oracle stipend and thresholds from a fork test, the PoolManager storage layout used after a failed pool initialisation, the vault's quote asset and position maths, DARLI supply and distribution, persistent failure in the shared settlement path, and legal review. A task that needs one of these decided should propose, with evidence, and stop.

## 7. Style

- Python: standard library only; integers only in protocol arithmetic (no floats anywhere in `model.py`); `require()` for reverts; every state-changing function reachable from the fuzzer.
- Solidity: `^0.8.26`, custom errors, no assembly except where a comment justifies it, `forge fmt`.
- Tests are named for the property they check, and the assertion message says which rule failed.
- Commit messages name the SPEC rule identifiers touched (e.g. `X7, X11: recompute late recovery totals`).

## 8. Security

If you find a way to take, lock or mis-allocate user funds, do not open a public issue and do not write it into a test that ships in a public commit before it is fixed. See `SECURITY.md`.

## 9. What good work looks like here

The strongest contributions in this project's history were not features. They were a test that failed for a real reason, a bound that was argued rather than measured, and a sentence in a document that was made narrower and truer. Prefer those.
