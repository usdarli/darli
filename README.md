# Darli

An immutable, ETH-backed stablecoin protocol for Base: borrowers set their own interest rate, a Stability Pool settles liquidations without market sales, a revenue-sharing token with no vote, and a staged, order-free settlement after shutdown.

**Status: research pre-release 0.0.1 — specification, reference model and Solidity skeleton. Nothing is deployed or audited; the core contracts are not written. This repository is not an offer of any token or financial product.**

| | |
| --- | --- |
| `docs/SPEC.md` | The normative specification: decisions in force, deployment constants, every rule with the test that pins it, open items |
| `docs/WHITEPAPER.md` | The public whitepaper |
| `docs/RESULTS.md` | Results of record: a hash manifest and the figures themselves, each recorded by the run that computes it and checked by `check_figures.py`. Every number in the documents comes from here, and none of them is typed in |
| `model/` | Executable reference model (Python, standard library only, exact integer arithmetic): 30 scenarios, two fuzzers with asserted coverage floors, 32 mutants, an agent-based simulator |
| `RELEASING.md` | Release checklist: what must be green, enabled and decided before a version is announced |
| `AGENTS.md` | Operating rules for AI coding agents and contributors: what must never change, how a rule change is made, what looks like a bug but is not |
| `contracts/` | Solidity (Foundry): math libraries checked bit-for-bit against the model, the stablecoin, the oracle adapter, the one-shot deployer. The core branch contracts are not written yet |

## What Darli is

- Borrow USDarli against ETH at an interest rate you choose; the lowest rates are redeemed first.
- Debt is settled by a Stability Pool, then by redistribution, then by an explicit bad-debt ledger. Liquidation never depends on selling collateral in a market.
- One external ETH/USD feed per branch, with sequencer and staleness guards and a fixed gas stipend. The protocol's own pool is never a price source.
- **Immutable**: no owner, proxy, pause, setter or vote. The debt cap raises itself on a schedule. New collateral means a new, independent deployment.
- **DARLI** has no vote; stakers receive 25% of interest and loan fees in fixed weekly epochs.
- **After a shutdown**, one reference price is fixed, every Trove is settled, and every USDarli then claims the same fraction of the pot, in any order.

## What this costs — read before the benefits

- **A shutdown is not an instant withdrawal.** No holder is paid until every Trove has been processed; a Trove nobody processes can be written off only after 30 days.
- **A healthy borrower's surplus can cover other borrowers' losses.** At settlement, the surplus collateral of healthy Troves absorbs the shortfall of under-water Troves first, every healthy borrower giving up the same fraction; holders take a haircut only after that.
- **The pilot's liquidity and keepers are not funded by the protocol.** No share of revenue goes to liquidity providers; the market depth and the keepers that hold the peg in the simulations were assumed to be provided by the team.
- **Nothing can be patched.** A bug in a deployed contract is permanent; the only remedy is to leave and redeploy.

## Reproduce the evidence

`make check` runs all of it and is what CI runs; `make help` lists the targets. Individually:

    cd model
    python3 test_scenarios.py          # 30 scenarios
    python3 fuzz.py 30 300             # accounting fuzzer: invariants before and after every step, plus a floor on how often each operation must succeed
    python3 fuzz_oracle.py 200 150     # oracle failure detection
    python3 test_econ_sim.py           # simulator self-tests
    python3 mutants.py M39             # one mutant at a time
    python3 spec_check.py              # every scenario cited in SPEC.md exists and every scenario is cited (it does not check assertions)

    python3 mutants.py                 # all 32 mutants; exit code 1 on a survivor or an invalid mutant
    python3 check_manifest.py          # every file behind docs/RESULTS.md has the recorded hash, contracts and submodule pins included
    python3 check_figures.py           # every number quoted in docs/RESULTS.md equals what the run above recorded

    cd ../contracts                    # submodules: forge-std v1.9.7, openzeppelin-contracts v5.1.0 (clone with --recurse-submodules)
    forge test

## Open items before implementation

See `docs/SPEC.md` §13: β, the gas deposit amount, oracle thresholds from a fork test, the PoolManager storage layout used after a failed pool initialisation, the vault's quote asset and position maths, DARLI supply and distribution, persistent failure in the shared settlement path, how each branch learns the stablecoin's address, and legal review before any deployment.

## Comparison with similar protocols

See `docs/WHITEPAPER.md`, Section 7, for a comparison with Liquity v1 and v2, Maker/Sky and crvUSD: what is shared, what differs, and what Darli lacks.

## License

MIT, Copyright (c) 2026 USDarli. See `LICENSE`. This covers the whole repository: the documents, the reference model and the contracts; every Solidity file carries `SPDX-License-Identifier: MIT`. The submodules keep their own licenses (forge-std: MIT/Apache-2.0; OpenZeppelin: MIT).

A permissive license is not permission to deploy this code. Nothing here is audited, the core contracts are not written, and the legal review named in `docs/SPEC.md` §13 has not been done.
