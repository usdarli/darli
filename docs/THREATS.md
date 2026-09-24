# Threat model

What Darli trusts, what it holds, who can act on it, and for each way it can be attacked or fail: the rule that answers it
and the test that pins the rule. It is written for auditors and for anyone deciding whether to use the protocol. Rules are
cited by their `docs/SPEC.md` identifiers; measured numbers are in `docs/RESULTS.md` and are not repeated here.

The contracts cannot be changed after deployment. A finding in this list that is not answered before deployment is
answered never.

## 1. What the protocol trusts

| Dependency | What it could do | Where the protocol answers |
| --- | --- | --- |
| Ethereum | Everything: Base's safety and its forced-inclusion path rest on it | Nothing can; stated in the whitepaper |
| The Base sequencer | Stop or reorder Base transactions; refuse a given sender's | Oracle states during outages (O2, O3); any call can be sent through Ethereum and must be included within the sequencing window (`script/ForceInclude.s.sol`, Ethereum fork test) |
| The Chainlink ETH/USD feed and sequencer uptime feed | Report a wrong price, stop updating, be retired | The pool source cross-checks and replaces it (O7, O8); a dead feed no longer shuts the branch down; a lasting disagreement does |
| The pools of the pool source (Uniswap v3, Aerodrome Slipstream) and their stablecoins | Be manipulated, drained, frozen, lose their peg | Weighted median over time-weighted liquidity (O7); a pool left out when stale or failing; depth floor; the cross-check stops the system rather than follow a depegged dollar |
| USDC's and USDT's issuers | Freeze any address, including a pool's or the PoolManager's | The liquidity vault pays each token alone to a named recipient and never holds a pool token (V7); the core never holds either |
| WETH | Nothing: no owner, no freeze | - |
| The Uniswap v4 PoolManager | Its own rules for the canonical pool | The core never calls it (D3); only the deployer and the vault do |
| OpenZeppelin and Uniswap v4-core libraries, the compiler | Bugs | Pinned versions (submodules, `solc 0.8.26`), hashed in the manifest; only MIT files of v4-core are imported |

## 2. What it holds

Collateral (WETH in each branch's `CollateralVault`), the USDarli supply and what backs it, Stability Pool deposits and
their gains, borrowers' surpluses, the settlement pot after a shutdown, gas deposits, the stakers' revenue stream, and the
liquidity vault's position and fees. B12 and I-4 require every named account to be in the vault and nothing unnamed in
the ledger.

## 3. Who can act, and with what powers

| Actor | Powers |
| --- | --- |
| Deployer | None after the deployment transaction: minters sealed, destinations fixed, no owner, proxy, setter or pause anywhere (D1; `test_theDeploymentIsSealedAtThePredictedAddresses`) |
| Borrowers | Their own Troves; risk-reducing actions never need a price or a permission (B-rules) |
| Holders | Redeem while live (R-rules); claim the pot after a shutdown (X-rules) |
| Keepers | Liquidate, redeem, settle, write off, poke the oracle, route revenue: all permissionless, paid by the rules |
| DARLI stakers | Receive revenue; no vote, no power of any kind (V4) |
| Interfaces | Receive their share when a borrower names them (V2); cannot move anyone's funds |
| MEV searchers | Order transactions around public calls |

## 4. Threats

| # | Threat | Answer | Evidence |
| --- | --- | --- | --- |
| T1 | A key or a vote changes the rules or takes the funds | There is no such key or vote | D1; AGENTS.md section 2 forbids adding one |
| T2 | A wrong price: a bug, a hijacked feed, a manipulated pool | Two independent sources that must agree while both answer; a single pool with less than half the weight cannot move the second source | O7, O8; S-36; `test_diff_oracleMatchesModel`; `test_fork_thePoolSourceAgreesWithTheFeedAndThinPoolsWeighNothing` |
| T3 | The oracle provider as a kill switch | A dead primary hands over to the pools | O8; `test_fork_aDeadFeedFallsBackToThePoolsInsteadOfShuttingDown` |
| T4 | While the pools stand in alone, their price is moved with enough capital | Time-weighted over a window, median over deep pools; the cost grows with their liquidity and the window | O7; residual risk, sized in `docs/RESULTS.md` (oracle thresholds) |
| T5 | A caller's choice of gas makes a healthy feed look broken | Fixed stipends proven affordable before every read | O5; S-20 e, f; `test_e_stipendGuardCannotBeGriefed`, `test_f_gasBurningSource` |
| T6 | A sequencer outage causes a permanent shutdown | Network states are temporary; Failed needs the sequencer up a whole timeout | O2, O3; S-20 a; fuzz_oracle F1, F9 |
| T7 | The sequencer censors one user | Forced inclusion through Ethereum from the same address | `test_fork_aCensoredCallGoesThroughEthereumFromTheSameAddress`; the frontend offers it beside every action |
| T8 | A frozen stablecoin address locks other funds | Per-token payouts to a named recipient; the vault holds claims inside the PoolManager | V7; `test_fork_aFrozenAddressBlocksOnlyItsOwnPayoutOfThatToken` |
| T9 | A liquidation mis-allocates collateral or leaves bad debt unrecorded | Stability Pool, then redistribution, then an explicit bad-debt ledger | L-rules; branch trace replay; I-2, I-19 |
| T10 | Redemption against the wrong Troves, or at the wrong price | Lowest rate first; the redemption price never below the price | R-rules; S-33, S-34; routing trace replay |
| T11 | After a shutdown, early claimers take more than late ones | Staged settlement: one reference price, every Trove settled, then one rate | X-rules; S-23, S-28; settlement trace replays |
| T12 | Settlement blocked for ever by the feed | The reference price is fixed in the shutdown transaction and never read again | X1; S-37; `test_aShutdownInATemporaryOracleStateFixesTheLastGoodPriceAndNeverWaits`; `invariant_ledgersAgree` |
| T13 | Settlement blocked by Troves nobody processes | Gas deposit paid to the settler; write-off after the delay | X2, X5; the deposit amount is open (SPEC 13) |
| T14 | Reentrancy or a callback into user code | Every external entry point is non-reentrant; the core calls no user code; its tokens have no hooks | 10.5 |
| T15 | Rounding drains value over many operations | Round up when minting, down when paying; ε never negative | Section 1; I-2; X10 |
| T16 | The canonical pool is initialised first at a false price | Tolerated: the empty pool's price is corrected for free, the vault refuses deposits outside its range | D2, D4; `test_fork_aRacedPoolIsToleratedItsPriceCorrectedForFreeAndTheVaultGuardHolds` |
| T17 | Unbounded work locks a path after shutdown | No scan over Troves; batches of at most 50 | X3; AGENTS.md section 2 |
| T18 | Interfaces are taken down | A self-contained page for IPFS, and the command line | `frontend/`, `contracts/script/check_frontend.py` |
| T19 | A price read fails for lack of gas limit | The stipend guard needs the whole stipend available before a read: a transaction that reads the price needs a gas limit above its stipends, whatever it uses | O5; the deployment rehearsal (`make rehearse`) |

## 5. Invariants

`docs/SPEC.md` section 11 lists the invariants the reference model checks before and after every fuzzer step (I-1 to I-22),
and section 12 maps every rule to its scenario, mutant, fuzzer property and Foundry test. In Solidity,
`invariant_ledgersAgree` checks the branch ledgers under random operations, and every model-driven trace is replayed wei
for wei.

## 6. What remains open

The open items of `docs/SPEC.md` section 13, and these residual risks, which no rule removes:

- the powers of Ethereum, of the Base sequencer beyond the sequencing window, and of the stablecoin issuers;
- the cost of moving the pools while they stand in alone, which is fixed at deployment while the system's size is not;
- a bug in the contracts, which cannot be fixed after deployment.

## 7. Audit scope

In scope: every file under `contracts/src`, and the deployment scripts `contracts/script/DarliSystem.s.sol` and
`contracts/script/DeployFeed.s.sol`, whose output is what gets deployed. For reference: the reference model (`model/`),
the Foundry tests and traces (`contracts/test`, `contracts/fork`), the frontend (`frontend/`) and the forced-inclusion
script (`contracts/script/ForceInclude.s.sol`).
