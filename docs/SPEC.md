# Darli v1 — Consolidated Specification

**Version 0.0.1 (2026-09-22).**
Status of this text and of the model: **the rules in this document are the reference for what the protocol promises**; `model.py` is the reference
*implementation* of those rules, and the tests pin the two to each other. A discrepancy between this text and the model is an OPEN ISSUE that needs a
decision and a fix, not a definition of behaviour. 
Reference notation: `S-NN` = `scenario_NN_*` in `test_scenarios.py`; `F` = a property in `fuzz.py`; `M-n` = mutant n; `I-n` = `check_invariants`. The
script `spec_check.py` verifies that every `S-NN` named here exists and that every scenario's stated topic is cited at least once. Every rule below carries the identifier of the test that checks it. Rules marked **[open]** are decided in principle but have no binding value or test yet.


---

## 0. Decisions in force

| Decision | Value | Status |
| --- | --- | --- |
| Governance | **None.** No owner, proxy, pause, setter, timelock or guardian. Every parameter is a deployment constant. | decided |
| DARLI | **Revenue, no power.** Stakers receive the protocol share of interest and loan fees, pro rata, in fixed weekly epochs. No vote. | decided |
| Interest split | Stability Pool 72 %, DARLI stakers 25 %, interfaces 3 %. Liquidity providers 0 % (a 10 % share is a studied proposal, not a decision). | decided |
| Debt cap | **Built-in schedule**: opens at `cap0`, doubles at most every 30 days, stops at `cap_ceiling`. Limits new borrowing only. | decided |
| After a shutdown | **Staged settlement**: one reference price fixed at shutdown; every Trove settled; then one common rate for every USDarli. No urgent redemption, no repay/close/liquidate after shutdown. | decided |
| Loss sharing at settlement | **Healthy borrowers' surplus absorbs the shortfall of under-water Troves first**, each giving up the same fraction; holders take a haircut only when all surplus is used. | decided |
| Settlement completion | Constant work per Trove, batches ≤ 50, the settler is paid the Trove's gas deposit; after 30 days a Trove may be written off; late recoveries reach every claim unit alike. | decided |
| Deployment | One transaction: token, sealed minters, fixed revenue destination, canonical USDarli/USDC pool at par with no hook, vault bound to it. A pre-initialised pool is tolerated only if it demonstrably exists. | decided |
| Oracle | One external ETH/USD feed per branch, fixed; sequencer guard; temporary states before a permanent failure; fixed gas stipend. The pool is never a price source. | decided |
| β (redemption fee sensitivity) | **[open]**: 4 in the pilot simulations; two studies disagree. | decided |
| Minimum debt | 500 USDarli (proposed) | decided |
| Collateral | ETH in the protocol's own vault. Not in any pool. | decided |

---

## 1. Units and conventions

- `WAD = 1e18`. All ratios, rates and prices are WAD-scaled. Collateral amounts are normalised to 18 decimals.
- Rounding: whenever the protocol mints, it rounds **up** (in favour of the system's books); whenever it pays a user, it rounds **down**. Every deviation is
  listed at the rule that causes it.
- "Price" is the branch's reference-currency price of one unit of collateral, from the branch's feed (§7).
- A **system** is one stablecoin with its branches. A **branch** is one collateral inside one system. Version 1 deploys one system (USDarli) with one branch (WETH).

## 2. Constants (deployment; never changeable afterwards)

| Constant | Value | Rule |
| --- | --- | --- |
| `MCR` / `CCR` / `SCR` | 110 % / 150 % / 110 % | §4, §6 |
| Liquidation premium to the Stability Pool / on redistribution | 5 % / 10 % (caps, not guarantees) | §6.2 |
| Liquidator's share of collateral | 0.5 %, capped at 2 ETH | §6.2 |
| Interest rate range | 0.5 % – 250 % p.a. | §4.1 |
| Upfront fee | 7 days of interest at the branch average rate | §4.3 |
| Rate-change cooldown | 7 days | §4.3 |
| Minimum debt | 500 (proposed) | §4.2 |
| Redemption fee floor / half-life / β / initial base-rate component | 0.5 % / 6 h / **[open]** (4 in simulations) / 10 % for the pilot | §5.2 |
| Interest split (SP / stakers / interfaces) | 72 / 25 / 3 % | §8 |
| Reward epoch | 7 days | §8.2 |
| Debt cap schedule | `cap0` 125 000, ceiling 250 000 (pilot), period 30 days | §4.5 |
| `DUST_THRESHOLD` | 1e12 raw units | §4.6 |
| `L_PRECISION` (redistribution) / `P_PRECISION` (SP) | 1e36 / 1e36 | §6.3, §6.1 |
| `MAX_SCALE_DIFF` | 8 | §6.1 |
| `MAX_SETTLE_BATCH` / `WRITE_OFF_DELAY` | 50 / 30 days | §9 |
| Gas deposit per Trove | **[open]** (positive; amount to be fixed against measured gas on Base) | §9.3 |
| Oracle: staleness threshold / failure timeout / grace / gas stipend | 3 × heartbeat / 24 h / 1 h / fixed per feed **[open: measured on a fork]** | §7 |

## 3. Token

- **T1** USDarli is ERC-20 with permit. Minters are the branch contracts of the deployment, written once by the deployer and sealed; nothing can add or remove a minter afterwards. A minter burns from any holder without an allowance, so every holder's balance is exactly as safe as the branches: §10.5 binds them. (Foundry `test_minterSetIsSealedForEver`, `test_onlyMintersMintAndBurn`)
- **T2** Transfers to the token contract itself and to the zero address revert.
- **T3** `totalSupply == Σ aggDebt` over branches at every instant. (I-1, F, Foundry `invariant_ledgersAgree`)

## 4. Borrowing (live branch)

### 4.1 Trove
A Trove is an NFT with `coll`, `recordedDebt`, `annualRate`, `stake`, redistribution snapshots, `lastDebtUpdate`, `lastRateAdjust`, `frontendId`, status ∈ {Active, Zombie, ClosedByOwner, ClosedByLiquidation, ClosedBySettlement}.

### 4.2 Two ledgers
- **B1** Each branch keeps `aggDebt` and `aggWeightedDebtSum = Σ recordedDebt_i × rate_i`. Step A (every state change): mint `p = ceil(aggW × Δt / (YEAR × WAD))`, split as §8; then `aggDebt += p`. Step B (touched Trove): its own interest `floor(debt × rate × Δt / (YEAR × WAD))` is added to `recordedDebt`; no second mint; exact wherever the result fits in 256 bits, whatever the debt (Foundry `test_diff_stepB_roundsDown`, `testFuzz_troveInterest_equalsTheOldFactoringWhereItDidNotOverflow`, `test_diff_branchTraceMatchesModel`). A transfer of the Trove's NFT runs step B first, so what accrued before it is credited to the owner who held it (Foundry `test_transferCreditsTheOldOwnerFirst`). Time without any transaction changes nothing until the next step A. (S-01, S-05, S-11, M-1 step A rounds down)
- **B2** Identity at every instant: `aggDebt + pendingAggInterest == Σ troveDebt(now) + badDebt + ε`, `ε ≥ 0`, `ε` bounded empirically (max observed 28 wei over 30 × 300 fuzz steps). (I-2, F)
- **B3** Interest stops in both ledgers at `shutdownAt`: `t_eff = min(now, shutdownAt)` and `aggW = 0` after shutdown. (S-02, I-3, M-2)
- **B4** Minimum debt: a Trove is never opened, increased or reactivated below it; a repayment may not take a Trove from ≥ minimum to a non-zero amount below it; a Trove already below it accepts any repayment. Raising the minimum never traps a loan. A Zombie whose debt an operation raises back to the minimum or above (`borrow`, `adjustTrove`, `applyPendingDebt`) is Active again and back in the redemption queue, whichever operation raised it. (S-06 `min_debt_increase`, S-33, M-45 `adjustTrove` leaves a re-borrowed Zombie out of the queue, F `min_debt`, Foundry `test_zombieBorrowingBackThroughAdjustRejoinsTheQueue`)
- **B5** The last Trove of a branch may close while short by ≤ `DUST_THRESHOLD`; the shortfall is parked in `badDebt`. (S-10-dust, M, Foundry `test_lastTroveClosesShortByDustOnly`)

### 4.3 Rates and fees
- **B6** Opening or adding debt costs an upfront fee = 7 days of interest at the branch average rate, minted and split as §8, added to the debt. (S-05)
- **B7** `adjustRate` within 7 days of the last change costs the upfront fee on the whole debt and requires ICR ≥ MCR and TCR ≥ CCR afterwards; otherwise free. (S-13)

### 4.4 Risk gate
- **B8** One shared gate `_requireRiskIncreaseAllowed(debtUp, collDown)` is used by every entry point. It requires: branch not shut down; a `Valid` price; ICR ≥ MCR after the operation; and below CCR, new debt only if TCR ≥ CCR afterwards and collateral out only together with a repayment worth at least as much. (S-15b, S-16, F, Foundry `test_diff_branchTraceMatchesModel`)
- **B9** `repay`, `addColl`, `closeTrove`, Stability Pool withdrawal: given their own preconditions (open Trove, sufficient balance, no dust left, valid amount), they depend on no oracle price, no administrative permission and no optional callback into user code, and nothing in the protocol can switch them off while the branch is live. Authorisation of the caller over his own Trove and the transfers of the specified tokens are part of the operations themselves. (S-16 live part, F, Foundry `test_repayAddCollAndCloseNeverReadThePrice`, `test_riskReducingOperationsIgnoreEveryOracleStatus`; see §11 on what is and is not checked)
- **B10** No pause of any kind exists; the only stop is a shutdown by the rules of §6.5. (S-09, S-16)

### 4.5 Debt cap
- **B11** `cap(t) = min(ceiling, cap0 × 2^floor((t − t_created) / 30 days))`. Checked on `aggDebt` against voluntary debt increases including their upfront fee; interest, repayment and collateral top-ups are never blocked. (S-09, S-10, M-25, M-26, M-27, Foundry `test_debtCapDoublesEachPeriodUpToTheCeilingAndNeverBlocksInterest`)

### 4.6 Vault accounting
- **B12** `accountedColl == Σ coll_i + defaultColl + Σ surplus + badDebtColl + settleSurplusPool + gasPool + latePool`, exactly; vault balance ≥ accounted. Collateral sent straight to the vault belongs to nobody and stays outside every ledger; **there is no skim.** (I-4, S-18, F, Foundry `test_strayCollateralStaysOutsideEveryLedger`, `invariant_ledgersAgree`)
- **B13** Every named pool is ≥ 0; `gasPool == Σ gas_left[tid]`; no Trove ever pays more reward than its deposit. (I-20/21/22)

## 5. Redemption (live branch)

- **R1** Anyone may redeem USDarli for collateral worth one unit of reference currency per token, minus the fee, whenever the branch has a `Valid` price and `TCR ≥ SCR`. Nobody can switch it off; it stops by itself without a valid price and is replaced by settlement after a shutdown. (S-14 `redemption_routing`, S-16, Foundry `test_onlyALiveBranchWithAValidPriceAtOrAboveScrIsRedeemed`, `test_diff_routingMatchesModel`)
- **R2** Order: lowest `annualRate` first; among equal rates, the lower Trove id first. (rate, id) is a total order, so the queue is determined by the set of Active Troves alone: insertion hints change the gas of an insertion, never its place, and removal needs neither a hint nor a walk. A Trove left below the minimum becomes a Zombie and leaves the queue; one partially redeemed Zombie (`lastZombieTroveId`) is redeemed first next time; one redeemed to zero is not tracked. (S-15 (c) zombies, S-12 `end_of_life`, S-31, M-43 ties by the higher id, Foundry `test_aZombieLeftWithDebtIsRedeemedFirstAndForgottenAtZero`, `test_diff_branchTraceMatchesModel`, `test_diff_redemptionOrderMatchesModel`, `test_tiesAreBrokenByTroveId`, `testFuzz_hintsNeverChangeThePosition`, `invariant_orderIsCanonical`, `test_exactHintsCostTheSameAtAnySize`)
- **R3** Across branches: split in proportion to each branch's debt not covered by its Stability Pool, truncated to that uncovered total, shares computed with a running remainder; when no redeemable branch has uncovered debt, in proportion to their debt. The truncation binds only when a branch is excluded or a pool holds more than its branch's debt: otherwise the uncovered total is the supply outside the pools, the redeemer's balance included. (S-14 `redemption_routing`, Foundry `test_diff_routingMatchesModel`)
- **R4** Two prices: `price` decides redeemability (TCR ≥ SCR, and ICR ≥ 100 %; a Trove below is skipped and counts as an iteration); `redemptionPrice` converts debt to collateral. The branch converts at `max(price, redemptionPrice)`: a feed may make redemption dearer for the redeemer, never cheaper, so an ordinary redemption never lowers the ICR of a Trove at or above 100 % at `price`, and never draws more collateral than such a Trove holds, whatever the feed returns. (S-34, M-47 conversion below `price`, I-8, Foundry `test_aTroveUnder100PercentIsSkippedButCountsAsAnIteration`, `test_debtIsConvertedAtTheRedemptionPriceAndTheFeeStaysInTheTrove`, `test_aRedemptionPriceBelowThePriceIsRaisedToIt`, `testFuzz_aRedemptionNeverLowersTheIcrOfATroveAt100PercentOrMore`)

### 5.2 Fee
- **R5** `fee = min(WAD, floor + decayed_baseRate + requested × WAD² / (supply × β_wad))`, computed from the **requested** amount before redeeming; the **stored** `baseRate` is updated from the amount **actually** redeemed, with β sampled **once** per redemption. Decay: `baseRate × decay^minutes`, `decay = floor(0.5^(1/360) × 1e18) = 998076443575628738`, exponent capped at `MAX_DECAY_MINUTES`; the fee clock moves only when a whole minute has passed. The caller's `maxFeeRate` bounds the rate, inclusive. (S-14, S-15 (d), S-25, S-13 (b), M-6 base rate from the requested instead of the redeemed amount, Foundry differential vectors, `test_theFeeFollowsItsFormulaFromTheInitialBaseRateAndIsCapped`, `test_theBaseRateFollowsWhatWasRedeemedNotWhatWasAsked`, `test_theBaseRateDecaysWithASixHourHalfLifeCountedInWholeMinutes`, `test_diff_branchTraceMatchesModel`)
- **R6** `INITIAL_BASE_RATE` is a constant: 100 % for an uncapped system; 10 % for the pilot (the cap already limits a run). **β is open** (§0). (Foundry `test_theFeeFollowsItsFormulaFromTheInitialBaseRateAndIsCapped`, `test_registryConstructionRefusesInconsistentParameters`)
- **R7** The fee stays in the redeemed Trove as collateral. (I-8, Foundry `test_debtIsConvertedAtTheRedemptionPriceAndTheFeeStaysInTheTrove`, `test_diff_branchTraceMatchesModel`)

## 6. Solvency (live branch)

### 6.1 Stability Pool
- **SP1** Deposits accepted only while the branch is live; withdrawals never restricted, never need a price. (S-15a, S-16, F, Foundry `test_depositsCloseAtShutdownWithdrawalsAndClaimsNeverDo`)
- **SP2** Product/sum accounting with scale: an offset always leaves ≥ `MIN_SP_RESIDUAL` (1 token) in the pool, so `P > 0`; when `P < P_FLOOR` it is rescaled in a **loop**; a deposit is valid across `MAX_SCALE_DIFF = 8` rescalings and gains are read over all 8. (S-07, S-17, M-5 single `if` instead of a loop, M-8 gains read over two scales only, Foundry `test_diff_stabilityPoolMatchesModel`, `test_anOffsetAlwaysLeavesTheResidual`)
- **SP3** Interest is credited to the pool at the moment it is minted (step A) only if `deposits ≥ MIN_SP_RESIDUAL`; otherwise that share goes to the escrow. A deposit made after a mint earns nothing from it. (S-03, S-04)
- **SP4** Three separate bounds, not one. (a) *Truncation of scale history*: a deposit is read over at most `MAX_SCALE_DIFF = 8` rescalings of 1e9 each,
  so the gain it can no longer see is below `deposit × 1e-72`, negligible; this is a bound by construction. (b) *Rounding of the payout arithmetic*: payout
  ≤ exact + 1 wei (S-17 asserts exactly this tolerance, so "never over-pays" holds to one wei, not absolutely); underpayment ≤ 1 000 wei + exact × 1e-9
  on S-17's domain. (c) *Observed*: worst underpayment measured in S-17 is 3 wei. 

### 6.2 Liquidation
- **L1** Anyone may liquidate a Trove with ICR < MCR, given a `Valid` price, while the branch is live. A zero-debt Trove is not liquidatable. (F, Foundry `test_onlyATroveBelowMcrWithAValidPriceOnALiveBranchIsLiquidated`, `test_diff_branchTraceMatchesModel`)
- **L2** Waterfall: offset against the Stability Pool at ≤ 5 % premium; remainder redistributed to active Troves at ≤ 10 % premium; if no recipient exists, remainder → `badDebt` + `badDebtColl` and the branch shuts down. Premiums are caps: an under-water Trove hands over everything it has. (S-08, S-10, Foundry `test_poolAbsorbsFirstAndTheRestIsRedistributed`, `test_premiumsAreCapsAnUnderwaterTroveHandsOverEverything`, `test_theLastTroveWithAnEmptyPoolBecomesBadDebtAndShutsTheBranch`)
- **L3** Liquidator receives 0.5 % of collateral (cap 2 ETH) from the whole collateral, plus the Trove's gas deposit. Surplus after full settlement goes to the owner (`surplus`), claimable any time, without a price, and apart from any settlement surplus (X11): an owner who also has one waiting for phase 1 to end still claims this now. (S-10, S-27, S-35, M-48, Foundry `test_theLiquidationSurplusIsClaimableDuringPhaseOne`, Foundry `test_liquidatorReceivesTheCappedBonusAndTheGasDeposit`, `test_surplusBelongsToTheOwnerAndIsClaimedWithoutAPrice`)

### 6.3 Redistribution
- **L4** Accumulators `L_coll`, `L_debt` at `L_PRECISION = 1e36` with carried remainders; corrected stakes and system snapshots so that interaction order cannot shift shares. (S-10, Foundry `test_diff_branchTraceMatchesModel`, `invariant_ledgersAgree`; no model mutant yet targets the accumulators themselves)

### 6.4 Bad debt (live)
- **L5** Three distinct situations:
  1. *Live branch, bucket non-empty*: `badDebt` and `badDebtColl` fall together; claims are pro rata; the last claimant takes the remainder; no ownerless
     collateral remains (I-19). (S-08, M-4 payout capped at face value)
  2. *Live branch, dust bad debt with an empty bucket* (only from B5): a burn extinguishes debt and pays nothing; nothing can ever be recovered against it,
     so this — and only this — is a donation. (S-08)
  3. *After a shutdown*: an empty pot at the end of phase 1 is NOT final. A burn still registers claim units (`units_of`), and those units receive every
     later recovery alike (X7–X9). Calling such a burn a donation would re-create the earlier bug. (S-29, M-40)

### 6.5 Shutdown
- **L6** Triggers, and nothing else: `TCR < SCR` with a `Valid` price; a credible oracle failure (§7); recorded bad debt. Recorded only by non-reverting paths (`pokeOracle`, `triggerShutdown`, liquidation, redemption). Permanent. (S-02, S-15, S-20)
- **L7** Effects: no new risk (B8 fails); interest stops (B3); Stability Pool deposits close (M-9), withdrawals stay open; `repay`, `addColl`, `closeTrove`, `liquidate`, redemption against this branch all stop; the branch enters §9. (S-02, S-16, M-33)

## 7. Price oracle

- **O1** One `IPriceFeed` per branch, fixed at creation; the protocol cannot replace it. The branch's own pool is never read. (deployment, S-26)
- **O2** Status order: `NetworkUnstable` (sequencer down or within the grace period) → `PriceInvalid` (stale, non-positive, future-dated, unreadable, or composite parts too far apart) → `Failed` → `Valid`. (S-20 a–i, fuzz_oracle F1–F9, M-12, M-13, M-14)
- **O3** `Failed` only with the sequencer continuously up for the whole timeout, and either a readable answer older than the timeout or malformed answers observed a timeout apart with no healthy observation between. A flapping sequencer postpones `Failed`. (S-20, M-11, M-15)
- **O4** Price-dependent borrower operations revert on any status but `Valid` and never record a shutdown; the marker `invalidSince` survives only in non-reverting transactions. (S-20 d)
- **O5** Gas stipend: each feed has an immutable `FEED_GAS_LIMIT`; before the read the transaction proves `gasleft ≥ (stipend + overhead) × 64/63 + buffer`; the read is a low-level `staticcall` copying exactly 64 bytes. Assumptions: stipend above the feed's true cost (measured on a fork, **[open]**), adapter returns the 64-byte shape. A provider swapping in a costlier aggregator can turn the stipend into a detected failure; the only remedy is a new deployment. (S-20 e/f, Foundry `test_e_stipendGuardCannotBeGriefed`, `test_f_gasBurningSource`)
- **O6** After a `Failed` shutdown all later prices are `lastGoodPrice`. (S-15a)

## 8. Revenue

- **V1** Every minted interest amount `p` (step A) and every upfront fee is split: `fePart = ceil(p × 3 %)` → FrontendRegistry (credited at source per Trove, funding rounded up, credits rounded down, always solvent; M-3 rounds it down); `spPart = floor(p × 72 %)` → Stability Pool if its deposits are at least `MIN_SP_RESIDUAL`, else escrow; remainder → escrow. (S-03, S-04, S-05, Foundry `test_stabilityPoolShareStartsExactlyAtTheResidual`)
- **V2** Frontends: register with a payout address and a kickback rate that only that address can raise and nobody can lower; a Trove is tagged at opening, and its frontend's share stays with that frontend; self-referral is a 3 % rebate. A Trove opened without a frontend (a command-line or self-written client) credits the whole share to its owner, exactly as a self-referral with full kickback would. (S-05 `frontend_long_untouched`, S-13 `extra_checks`, S-32, M-44 untagged share to an ownerless account, Foundry `test_kickbackOnlyRisesAndOnlyByItsPayout`, `test_untaggedShareReturnsToTheBorrower`)
- **V3** The escrow makes no calls. `route_revenue(system)` is permissionless, takes no destination, and moves the escrow balance to the staking contract fixed once at deployment (`fix_staking_destination`, refuses a second call; in the contracts both addresses are immutable and no function sets them). Only the router pulls from the escrow and hands over to the staking contract. (S-21, M-28, Foundry `test_anyoneRoutesTheEscrowToTheFixedStakingContract`, `test_onlyTheRouterPullsTheEscrowAndHandsOver`, `test_diff_stakingMatchesModel`)

### 8.2 DARLI staking
- **V4** Fixed supply, no vote, no power. Stakers receive hand-overs pro rata to stake. Fixed weekly epochs: what is handed over in epoch k is streamed second by second over epoch k + 1 at a rate fixed at the boundary; a later hand-over never touches an earlier schedule; time with no stake rolls into the next epoch. Stake and unstake make no external call beyond the DARLI transfer itself; earned rewards stay claimable after unstaking. Once the stream is empty, idle time is skipped in one step. (S-04, S-24, M-28, M-29, Foundry `test_diff_stakingMatchesModel`, `test_aHandOverIsStreamedOverTheNextEpochAndOnlyThen`, `test_aLaterHandOverNeverPostponesAnEarlierOne`, `test_timeWithNoStakeRollsIntoTheNextEpoch`, `test_stakersShareProRataAndLeavingKeepsWhatWasEarned`, `test_anEmptyStreamSkipsIdleTimeInOneStep`, `test_stakeBoundsAndTheFixedSupply`)
- **V5** What is claimable is not what is withdrawn; rounding dust < 1e-6 token per epoch. The staking contract always holds what it owes: everything earned and everything not yet streamed. (S-24, F, Foundry `test_diff_stakingMatchesModel`)
- **V6** The liquidity vault (peripheral, outside the core) accounts swap fees per token and any reward tokens paid into it with the same fixed-epoch stream; a just-in-time entrant earns only its seconds; time with no shares rolls forward. (S-19)

## 9. Settlement after a shutdown

### 9.1 Reference price
- **X1** `settlePrice` is fixed once: the `Valid` price at shutdown, or `lastGoodPrice` after an oracle failure; if no definite status exists at shutdown, fixed at the first settlement. Later market moves change nothing; once it is fixed, settling reads no price. (S-02, S-15a, S-23, M-31, Foundry `test_theReferencePriceIsFixedOnceAndLaterMovesChangeNothing`, `test_settlingReadsNoPriceOnceTheReferencePriceIsFixed`)

### 9.2 Phase 1: settle every Trove
- **X2** `settleTrove(tid)` is permissionless and does constant work: touch the Trove (pending redistribution applied, interest already stopped), `need = ceil(debt × WAD / settlePrice)`, `contribution = min(coll, need)`, `gross = coll − contribution`. Then `badDebt += debt`, `badDebtColl += contribution`, `parTotal += need`, `contribTotal += contribution`; `gross_of[owner] += gross`, `settleSurplusPool += gross`, `settleSurplusGross += gross`, `settleShortTotal += need − contribution`; `unsettled −= 1`. The caller receives the Trove's remaining gas deposit (M-36). No step scans the set of Troves (an open-Trove counter `n_open` replaces every scan). (S-22, S-23, S-27a, M-37, Foundry `test_diff_settlementMatchesModel_oracleFailure`, `test_aTroveHandsThePotItsDebtAtTheReferencePriceAndTheCallerItsDeposit`)
- **X3** `settleTroves(tids)` settles ≤ 50 in one call. (S-27a, Foundry `test_aBatchSettlesAtMostFiftyTroves`)
- **X4** Nothing is paid to any holder while `unsettled > 0`. (S-22, F, M-30, Foundry `test_nothingIsPaidToAnyHolderWhileATroveIsUnsettled`)

### 9.3 Completion
- **X5** After `WRITE_OFF_DELAY` (30 days) anyone may `writeOff(tid)` an unsettled Trove, for half its gas deposit: `badDebt += debt`, `parTotal += need`, `settleShortTotal += need`, `unsettled −= 1`; the Trove's debt leaves the Trove ledger and `aggDebt` is unchanged. Settling it before phase 1 ends reverses the write-off. (S-27b, S-29-5, M-34, Foundry `test_aWriteOffWaitsThirtyDaysAndPaysHalfTheDeposit`, `test_diff_settlementMatchesModel_oracleFailure`)
- **X6** Phase 1 ends when `unsettled == 0`: `take = min(settleShortTotal, settleSurplusGross)`, `badDebtColl += take`, `settleSurplusPool −= take`, `keep = (G − take) / G` (`L_PRECISION`), `claimUnits = badDebt`. A shutdown with no open Trove completes phase 1 at once. (S-23, S-28, M-38 the rejected vault-parity rule, Foundry `test_aShutdownWithNoOpenTroveCompletesPhaseOneAtOnce`, `test_everyOwnerGivesUpTheSameFractionOfHisSurplus`)
- **X7** Late settlement of a written-off Trove recomputes `contribTotal`, `settleShortTotal`, `settleSurplusGross`, `take`, `keep`; holders receive `pot' − pot` through `latePerUnit` (every claim unit alike, exercised or not); the rest of the Trove's collateral goes to the surplus pool. Proof of exact conservation and of `pot' − pot ≥ 0` in `RESULTS.md`. (S-27b, S-29, S-30, M-35, M-39, Foundry `test_diff_settlementMatchesModel_oracleFailure`, `test_diff_settlementMatchesModel_emptyPot`)
- **[open]** Real gas of X2/X3 on Base; behaviour when the shared parts (`_touch`, `_settlePrice`) revert persistently; a written-off Trove that can never be settled keeps its own collateral stuck; the deposit amount.

### 9.4 Phase 2: claims
- **X8** `redeemBadDebtColl(R)` after phase 1: burns `R`, registers `units_of[who] += R` **even when the pot is empty**, pays `floor(badDebtColl × R / badDebt)` (or all if `R == badDebt`) plus any late share due. `repayBadDebt` is the same with an empty pot. (S-08, S-29-1/2, M-40, Foundry `test_aClaimOnAnEmptyPotRegistersUnitsThatShareTheLateRecovery`, `test_diff_settlementMatchesModel_emptyPot`)
- **X9** Late share: `floor(units_of × latePerUnit / L_PRECISION) − latePaid`. (S-27b, S-29, Foundry `test_aClaimOnAnEmptyPotRegistersUnitsThatShareTheLateRecovery`, `invariant_ledgersAgree`)
- **X10** Rounding: each claim leaves < 1 wei in the pot; a later pay-out moves by at most one wei per earlier claim; splitting a claim into k parts loses ≤ k wei. (S-27c, Foundry `test_claimsArePaidProRataRoundedDownAndLeaveAtMostAWei`)

### 9.5 Borrowers' surplus
- **X11** Claimable only after phase 1: `floor(gross_of × keep) − surplusPaidAmt`. Both factors are non-decreasing along every allowed path, so the time of claiming cannot change the total. Every healthy borrower gives up the same fraction of his surplus (`1 − keep`). The surplus of a liquidation is not part of it (L3). (S-23, S-28, S-30, S-35, M-32, M-41, Foundry `test_everyOwnerGivesUpTheSameFractionOfHisSurplus`, `test_diff_settlementMatchesModel_surplusAbsorbs`, `test_diff_settlementMatchesModel_holdersHaircut`, `invariant_ledgersAgree`)
- **X12** Path independence: 32 specified combinations (owners, deposits, recovery timing, claim timing, empty pot) end within 6 wei of an independent rational computation. Evidence over those combinations, not a proof over all paths. (S-30)

## 10. Deployment

- **D1** One transaction: create the token; require every branch to name exactly that token (`stable()`), or revert (Foundry `test_branchBuiltForThePredictedToken_isSealed`, `test_minterBuiltForAnotherToken_isRefused`, `test_minterThatCannotNameItsToken_isRefused`); `sealMinters(branches)`; `fix_staking_destination(staking)`; initialise the canonical USDarli/quote pool in Uniswap v4 at the representable `sqrtPrice` at or just below par (decimals handled: 6 or 18, either token ordering), `hooks = 0`; a quote without code is refused (Foundry `test_quoteWithoutCode_isRefused`); bind the fixed-range vault to that key; mark deployed. Cannot run twice. (S-26, Foundry `DarliDeployer.t.sol`, `test_theDeploymentIsSealedAtThePredictedAddresses`)
- **D2** The pool race: the token's address is predictable and v4 lets anyone initialise any key, so deployment must not depend on winning. If `initialize` succeeds, the pool must hold exactly the target price, or the deployment reverts: every uncontested deployment checks the storage layout on the real PoolManager. If `initialize` fails, the pool must demonstrably exist and hold a price v4 can hold; otherwise the deployment reverts. The layout matches v4-core source and is **to be confirmed against the deployed PoolManager on a fork [open]**. Target and observed prices are recorded separately. (S-26, Foundry `test_poolRace_realPredictedAddress`, `test_unrelatedInitialiseFailure_revertsInsteadOfFalseSuccess`, `test_uncontestedDeployment_readsBackItsOwnPrice_orRefuses`, `test_racedPool_priceNoPoolCanHold_isRefused`)
- **D3** The core never holds a reference to Uniswap, the pool or the vault. (S-26)
- **D4** The vault refuses deposits while the pool price is outside its fixed range, and each depositor states his own accepted price bounds. This is not protection against manipulation inside the band. Token amounts and real position maths are not modelled **[open]**. (S-26)

## 10.5 Preconditions and boundaries (implementation contract)

The Python model does not define contract boundaries; the following is the contract for the Solidity implementation and is **not yet tested anywhere** unless a bullet names its test.
- Trove mutation (`borrow`, `withdrawColl`, `adjust`, `adjustRate`, `close`, `transfer`) only by the NFT owner or an approved operator; `repay` and
  `addColl` by anyone; `liquidate`, `redeem`, `settleTrove`, `writeOff`, `routeRevenue`, `pokeOracle`, `triggerShutdown`, claims of surplus and late shares:
  permissionless. Collateral comes from, and USDarli and collateral go to, the caller (Foundry `test_onlyTheOwnerOrAnApprovedAddressChangesTheTrove`).
- Amount validation: zero amounts revert (Foundry `test_zeroAmountsAndUnknownFrontendsAreRefused`); collateral and debt inputs are 18-decimal normalised;
  a redemption request above the redeemer's balance reverts, even when less would be redeemed (S-13 (c), M-46, Foundry
  `test_aRequestAboveTheBalanceIsRefusedEvenWhenLessWouldBeRedeemed`).
- Burning: a branch burns USDarli only from the account that initiated the operation, or from the protocol's own accounts (the Stability Pool). `StableToken.burn` cannot check this (T1); the branches must, and their tests must show it (Foundry `test_repayBurnsFromTheCallerNeverFromTheOwner`; a liquidation burns the absorbed debt from the Stability Pool, and a redemption from the account that called the CollateralRegistry, `test_diff_branchTraceMatchesModel`, `test_diff_routingMatchesModel`).
- Wiring: step A on request only by the branch's Stability Pool, step B on transfer only by its TroveNFT, redemption
  inside a branch only by the system's CollateralRegistry (Foundry `test_onlyTheRegistryRedeemsFromTheBranch`), and the
  branch's settlement hooks only by its BranchSettlement (Foundry `test_onlyTheSettlementMovesTheBranchAfterAShutdown`); the vault, the NFT and the queue accept changes
  only from their branch, the frontend registry only from a minter of the stablecoin (Foundry `test_wiredEntryPointsRefuseEveryoneElse`).
- Building: every component is created before the deployment transaction, from one address, at the address its nonce
  predicts, holding its neighbours as immutables; nothing is wired afterwards. Every immutable link of the system is
  checked before the minter set is sealed, and a mismatch stops the deployment (`contracts/script/DarliSystem.s.sol`,
  Foundry `test_aComponentBuiltForAnotherAddressIsFoundBeforeSealing`, `test_aDeployedSystemLivesThroughEveryPartOfItsLife`).
- Internal functions (`_stepA`, `_touch`, `_redistribute`, `_endPhaseOne`, `_lateRecovery`, `_payGasDeposit`, `_sweepDustIfEmpty`) are never externally callable.
- The redemption queue (`RateSortedList`) is changed only by its branch, fixed at construction, and makes no external call (Foundry
  `test_onlyTheBranchCanChangeTheList`, `test_constructorRejectsZeroBranch`). That it holds exactly the branch's Active Troves is the branch's duty
  (Foundry `invariant_ledgersAgree`, `test_diff_branchTraceMatchesModel`).
- Every external entry point runs the reentrancy guard. A branch's own contracts (manager, vault, TroveNFT, queue, Stability Pool) call one another and
  the system's frontend registry; beyond them the core calls only the collateral token, the price feed (staticcall with a stipend) and the stablecoin;
  the revenue hand-over transfers to a fixed address and makes no call into it.

## 11. What is checked where

**Checked in `check_invariants`, before and after every fuzzer step:** I-1 supply = Σ aggDebt · I-2 debt identity with ε ≥ 0 · I-3 aggW = 0 after shutdown ·
I-4 vault accounting (B12) · I-5 Stability Pool solvency (balances cover compounded deposits and gains; NOT the per-depositor exactness) · I-17 escrow
and frontend registry totals · I-19 no ownerless `badDebtColl` · I-20 named pools ≥ 0 · I-21 gasPool = Σ per-Trove · I-22 reward ≤ deposit.

**Checked by the fuzzer loop itself, every step:** staking contract covers its liabilities; nobody paid during settlement phase 1 (pot and claims only grow
while Troves are unsettled); late and surplus entitlements ≤ their pools, by a bound of zero wei that is argued at the assertion, not measured.

**Checked once per fuzzer run:** a floor on how often each operation succeeds (`MIN_COVERAGE` in `fuzz.py`). An invariant that holds over a path never taken
proves nothing, so a path that stops being reachable fails the run.

**Checked inside the operation, not as a separate step:** I-8, an ordinary redemption never lowers the ICR of a Trove above 100 % (asserted by
cross-multiplication inside `redeem_from_branch`).

**Checked only by dedicated scenarios:** per-depositor Stability Pool exactness against a rational shadow (S-17); settlement path independence against an
independent computation (S-30); the oracle properties F1–F9 (`fuzz_oracle.py`).

**On B9.** `repay`, `addColl` and `closeTrove` do revert on their own preconditions (insufficient balance, a Trove that is not open, an amount that would leave dust, closing without enough USDarli). The rule that holds is: **given their preconditions, these operations depend on no oracle price, no administrative permission and no optional callback into user code, and nothing in the protocol can switch them off while the branch is live; caller authorisation and the specified token transfers are part of the operations.** The fuzzer checks it in the only form that is checkable: it never observes a revert of these operations
whose message is a price, status or permission message.

## 12. Conformance map

"Fuzzer: yes" below means the operation is executed under a coverage floor, **not** that the fuzzer would catch a wrong result: the fuzzers check invariants,
not behaviour. The honest measure is how many of the mutants a random tester kills with no scenario at all, and that number is recorded in `docs/RESULTS.md`
("What the random testers kill on their own") rather than asserted here.

| Area | Scenarios | Mutants (all killed) | Fuzzer |
| --- | --- | --- | --- |
| Interest ledgers, fees, gates, minimum debt | 01–06, 11, 13, 15, 16 | M1, M2, M3 | yes |
| Stability Pool | 03, 04, 07, 17 | M5, M8, M9 | yes |
| Liquidation, redistribution, bad debt | 08, 10, 18 | M4 | yes: `liq` and `bad_debt` carry coverage floors, reached through the guided `crash` operation |
| Redemption | 12, 13, 14, 15, 25, 31, 33 | M6, M43, M45, M46 | yes; the queue order also against `RateSortedList`, and redemption and routing against the contracts (Foundry) |
| Debt cap | 09, 10 | M25–M27 | partly |
| Oracle | 20 | M11–M15 | fuzz_oracle F1–F9 |
| Revenue, frontends, staking, vault streams | 03, 04, 05, 13, 19, 21, 24 | M23, M28, M29 | yes (route, stake, claim) |
| Settlement | 02, 15a, 16, 22, 23, 27–30, 35 | M30–M42, M48 | yes: `urgent` (settle/write-off), `late` and `claim_late` all carry coverage floors; four settlement traces against the contracts (Foundry) |
| Deployment | 26 | — | — (Foundry) |
| Not modelled | batch managers, LST pricing, ParameterStore, Uniswap position maths, zappers, real gas | | |

## 13. Open items before implementation

1. β. 2. Gas deposit amount. 3. Fixed values of `FEED_GAS_LIMIT` and oracle thresholds from a fork test. 4. PoolManager storage layout for the post-initialise check: matches v4-core source; to be confirmed against the deployed bytecode on a fork. The uncontested path already checks itself (D2). 5. Vault quote asset, range and position maths. 6. DARLI supply and distribution. 7. Persistent failure in shared settlement parts. 8. Legal review before any deployment.
