# Contracts — Foundry (version 0.0.1: math libraries, stablecoin, oracle adapter, deployer, redemption queue, live branch borrowing)

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
| `src/core/RateSortedList.sol` | the redemption queue of `docs/SPEC.md` R2: Active Troves ordered by (rate, id), changed only by its branch; hints decide the gas of an insertion, never its place; removal is O(1) with no hint — **replayed against the model's queue** |
| `src/core/BranchManager.sol` | one branch on a live chain: both debt ledgers (B1–B3), every borrower entry point of `IBorrowerGateway` with the single risk gate (B4–B11), the revenue split (V1), the gas deposit, the shutdown triggers (6.5) — a line-by-line port of `Branch` in the model, **replayed against a model-driven trace wei for wei** |
| `src/core/CollateralVault.sol` | custody of a branch's collateral; `accountedColl` counts only what the protocol moved; no skim (B12) |
| `src/core/TroveNFT.sol` | one ERC-721 per branch; only the branch mints and burns; every transfer runs step B first (B1) |
| `src/core/FrontendRegistry.sol` | the interfaces' share (V1, V2): deposits rounded up, credits rounded down; a caller is a branch exactly when it is a sealed minter |
| `src/oracle/SingleSourcePriceFeed.sol` | `docs/SPEC.md` §7 for one source: sequencer first, temporary `PriceInvalid`, two paths to `Failed`, **fixed gas stipend proven up front**, low-level bounded `staticcall` |
| `src/oracle/ChainlinkAdapters.sol` | `ChainlinkSource`, `ChainlinkSequencerGuard` |
| `src/Types.sol`, `src/interfaces/*` | structs, enums, errors and the interfaces still to be implemented: liquidation (`ILiquidations`), redemption (`IBranchRedemption`, `ICollateralRegistry`), settlement (`ISettlement`), the Stability Pool, the router — **interfaces only** |

The branch's borrower entry points (`IBorrowerGateway`) are implemented by `BranchManager` itself, next to the ledger they
change, not in a separate gateway: every check then reads the state it guards directly. Borrowing alone already takes
much of the 24 KB contract size limit (`forge build --sizes`), so liquidation and settlement will not all fit beside it;
where the split falls is decided in stage 4, before that code is written. Until then the Stability Pool is a test mock
(`test/mocks/BranchMocks.sol`) carrying only what the split reads: the total deposited and the yield credited.

## What the tests established on a real EVM
- `test_e2`: a nested (proxy → aggregator), gas-hungry source **defeats the `gasleft() <= gasBefore/64` heuristic**: the proxy
  returns its own 1/64, the caller keeps ~2/64, the guard does not fire and a healthy feed gets a malformed marker
  (306 of 602 gas values in the sweep). A flat call is safe (0). The fixed stipend is safe in every case (`test_e`).
- `test_f`: a source that burns all gas can **never** be observed under the heuristic (20/20 observations revert → permanent limbo);
  under the fixed stipend it is observed and reaches `Failed`.
- `test_h`: `try/catch` would not have caught a short return (decode failure reverts in the caller) or a source without code.
  Hence the low-level `staticcall` that reads exactly 64 bytes (also removes the return-data gas bomb).
  These mocks are not real feeds: a fork test against the production feed of the target chain is still required.
- The exact 6-hour decay factor is `998076443575628738`; after 360 minutes it is 143 wei from one half
  (the float-rounded `...628800` is 11 054 wei off).
- `test_diff_redemptionOrderMatchesModel`: the model has no linked list, only a sort (`Branch.redemption_order()`), so
  `script/export_vectors.py` runs the model's branch (opens, rate changes, closes, redemptions that make Zombies, Zombies
  borrowing back, liquidations) and turns every change of its Active set into a list operation followed by the whole queue.
  The replay checks, at every insertion, that the list computes the very neighbours the rule names, then inserts with
  hints that rotate through exact, empty, reversed, stale and arbitrary; every queue must match. An invariant suite
  (`invariant_orderIsCanonical`, `fail_on_revert`) and a fuzz test on hints check the same property against a plain sort,
  and `test_exactHintsCostTheSameAtAnySize` shows by exact gas equality that exact hints are checked, not searched for.
- `test_diff_borrowerTraceMatchesModel`: `script/borrower_trace.py` drives the model's branch through a random sequence of
  every borrower operation, NFT transfers, time, price and oracle-status moves, Stability Pool deposits, frontend claims
  and, at the end, an oracle failure; guided price moves keep the branch below CCR for stretches, where the recovery-mode
  rules of B8 are tried on purpose. Each step records whether the model accepted the operation and the whole ledger after
  it; the replay must accept and refuse exactly the same operations and match every recorded number wei for wei.
  Hand mutants of `BranchManager` (the fee period, the dust rule of B4, the frontend credit, the gas refund, interest after
  shutdown in B3 and M-2, each recovery-mode rule of B8) all fail it.
- What a trace cannot show is in `BranchManager.t.sol`: `repay`, `addColl` and `closeTrove` succeed against a feed whose
  every read reverts (B9); repay burns from the caller, never the owner (10.5); rights and wiring; the exact boundary at
  which the Stability Pool starts receiving its share (V1); the debt cap schedule (B11); the dust rule of B5.
  `invariant_ledgersAgree` checks, after random operation sequences, that supply equals aggregate debt, that the
  aggregate never falls below the sum of the Troves, and that every per-Trove sum the branch keeps (weights, collateral,
  stakes, gas deposits, the queue) equals the sum over its Troves.
- Not yet reachable: Zombies arise only from redemption, so the Zombie paths (reactivation by `borrow` and
  `applyPendingDebt`) are ported but first tested with redemption in stage 5.

## Differential testing
The Python reference model is the oracle. `script/export_vectors.py` writes `test/vectors/math.json`,
`test/vectors/sorted_list.json` and `test/vectors/borrower_trace.json`; Foundry replays them. Each later stage adds its
operations to the trace: liquidation and the Stability Pool (4), redemption (5), settlement.

## Next stages
2. ~~`RateSortedList` (+ fuzz)~~ done  3. ~~`BranchManager` with the borrower entry points, `TroveNFT`, `CollateralVault`, `FrontendRegistry`~~ done
4. `StabilityPool`, liquidation, redistribution, bad debt  5. `CollateralRegistry`  … Each stage: scenario traces + invariant tests
(`check_invariants` of the model → Foundry invariant suite).
