# Contracts — Foundry skeleton (version 0.0.1: math libraries, stablecoin, oracle adapter, deployer)

    git submodule update --init --recursive      # forge-std v1.9.7, openzeppelin-contracts v5.1.0 (gitlinks in lib/)
    forge build && forge test -vv
    python3 script/export_vectors.py ../model      # regenerate differential vectors from the reference model

Solidity 0.8.26, no proxies, custom errors, OpenZeppelin v5.1 only. Test and vector counts are in `docs/RESULTS.md`, recorded by the run rather than typed here, and `make contracts` checks that forge ran exactly the declared number.

## What is real code
| File | Status |
| --- | --- |
| `src/libraries/Constants.sol` | code constants of `docs/SPEC.md` §2 |
| `src/libraries/FixedPointMath.sol` | `mulDivDown/Up`, `ceilDiv`, `decPow`, step-A (ceil) and step-B (floor) interest — **bit-for-bit equal to `model/model.py`** on the differential vectors, including step B over debts where `debt × rate` no longer fits in 256 bits |
| `src/core/StableToken.sol` | ERC-20 + permit; minter set is written once by the deployer and sealed for ever (immutable system); rejects transfers to itself / zero |
| `src/core/InterestEscrow.sol` | pull-only escrow: the core never calls out |
| `src/oracle/SingleSourcePriceFeed.sol` | `docs/SPEC.md` §7 for one source: sequencer first, temporary `PriceInvalid`, two paths to `Failed`, **fixed gas stipend proven up front**, low-level bounded `staticcall` |
| `src/oracle/ChainlinkAdapters.sol` | `ChainlinkSource`, `ChainlinkSequencerGuard` |
| `src/Types.sol`, `src/interfaces/*` | structs, enums, errors and every v1 interface of `docs/SPEC.md` §10.5 (BranchManager, BorrowerGateway, StabilityPool, CollateralRegistry, Vault, Router, FrontendRegistry, sorted list) — **interfaces only** |

## What the tests established on a real EVM
- `test_e2`: a nested (proxy → aggregator), gas-hungry source **defeats the `gasleft() <= gasBefore/64` heuristic**: the proxy
  returns its own 1/64, the caller keeps ~2/64, the guard does not fire and a healthy feed gets a malformed marker
  (306 of 602 gas values in the sweep). A flat call is safe (0). The fixed stipend is safe in every case (`test_e`).
- `test_f`: a source that burns all gas can **never** be observed under the heuristic (20/20 observations revert → permanent limbo);
  under the fixed stipend it is observed and reaches `Failed`.
- `test_h`: `try/catch` would not have caught a short return (decode failure reverts in the caller) or a source without code.
  Hence the low-level `staticcall` that reads exactly 64 bytes (also removes the return-data gas bomb).
- The exact 6-hour decay factor is `998076443575628738`; after 360 minutes it is 143 wei from one half
  (the float-rounded `...628800` is 11 054 wei off).
These mocks are not real feeds: a fork test against the production feed of the target chain is still required.

## Differential testing
The Python reference model is the oracle. `script/export_vectors.py` writes `test/vectors/math.json`; Foundry replays it.
Next step of the pipeline (needs `BranchManager`): export each scenario of `model/test_scenarios.py` as a trace
(operation, arguments, expected revert, ledger snapshot after) and replay it against the contracts, comparing every ledger wei for wei.

## Next stages
2. `RateSortedList` (+ fuzz)  3. `BranchManager`, `BorrowerGateway`, `TroveNFT`, `CollateralVault`, `FrontendRegistry`
4. `StabilityPool`, liquidation, redistribution, bad debt  5. `CollateralRegistry`  … Each stage: scenario traces + invariant tests
(`check_invariants` of the model → Foundry invariant suite).
