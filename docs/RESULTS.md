# Results of record (version 0.0.1)

Every figure quoted in the documents comes from this file. Reproduce with the commands in `model/README.md`; the manifest lists the sha256 (first 16 hex) of every file the figures depend on.

> **Caveats.** Behaviour in every economic run is uncalibrated. The pilot tables use the fixed-range pool, finite keeper budgets and identical market paths per seed. The "vault parity" tables (rejected loss-sharing rule) are not shipped; regenerate with `VAULT_PARITY=1 python3 pilot_sweep.py 4 6 20`.

## Manifest — the only list of hashes in this file (sha256, first 16 hex)

It covers `model/`, `docs/SPEC.md` and `contracts/`, because the run record makes claims about all three: the vector count
and the forge result mean nothing without knowing which Solidity sources and which version of OpenZeppelin produced them. Regenerate with `python3 model/check_manifest.py --write`.

| file | hash |
| --- | --- |
| contracts/foundry.toml | `f7e31bb8013021b6` |
| contracts/remappings.txt | `79f11452d3ebfaa9` |
| contracts/script/branch_trace.py | `d95106de8ba564cb` |
| contracts/script/check_test_count.py | `fce577ae0f91f146` |
| contracts/script/export_vectors.py | `2c5d3c7c51684c2b` |
| contracts/script/routing_trace.py | `ff1ba8ff3a0eae34` |
| contracts/script/sp_trace.py | `0ba08268a534e3d9` |
| contracts/src/Types.sol | `c3f68711b3bd2e24` |
| contracts/src/core/BranchManager.sol | `607fee8cc847ee90` |
| contracts/src/core/CollateralRegistry.sol | `9c7cc90cd7b12ad0` |
| contracts/src/core/CollateralVault.sol | `6f391a45db4f4c9f` |
| contracts/src/core/FrontendRegistry.sol | `94541ccdee09f702` |
| contracts/src/core/InterestEscrow.sol | `01ec1eaffa0acde7` |
| contracts/src/core/RateSortedList.sol | `9f71240f01bc507d` |
| contracts/src/core/StabilityPool.sol | `6029b9716642bfd0` |
| contracts/src/core/StableToken.sol | `8cf26fe81cb2b6f8` |
| contracts/src/core/TroveNFT.sol | `dcc0a15f051eda3d` |
| contracts/src/deploy/DarliDeployer.sol | `b875525cb54ec50f` |
| contracts/src/interfaces/IBorrowerGateway.sol | `b287f9326f196a1f` |
| contracts/src/interfaces/IBranchManager.sol | `5ed1b21e8bd86829` |
| contracts/src/interfaces/ICore.sol | `c70236dc0343f6ff` |
| contracts/src/interfaces/IPriceFeed.sol | `f2034a6189063139` |
| contracts/src/interfaces/IStabilityPool.sol | `e31e002e2b1d94ea` |
| contracts/src/interfaces/IStableToken.sol | `32c3ee6d5eebfec1` |
| contracts/src/libraries/Constants.sol | `b9a2d11babb14180` |
| contracts/src/libraries/FixedPointMath.sol | `ceda93baa0ece807` |
| contracts/src/oracle/ChainlinkAdapters.sol | `7dbadd9f5f79d2d7` |
| contracts/src/oracle/SingleSourcePriceFeed.sol | `41aa13e9ad6b65cc` |
| contracts/test/BranchFixture.sol | `d1bafcd4aa2afb9c` |
| contracts/test/BranchManager.invariant.t.sol | `26a00b54c0dcffac` |
| contracts/test/BranchManager.t.sol | `d976b7dbbb093a44` |
| contracts/test/BranchManager.trace.t.sol | `9e3687fa61ebd1e9` |
| contracts/test/CollateralRegistry.trace.t.sol | `78728613a4a4a005` |
| contracts/test/DarliDeployer.t.sol | `1bc28478e3a97f8c` |
| contracts/test/FixedPointMath.t.sol | `8727fe555bb91e53` |
| contracts/test/Liquidation.t.sol | `98c49a26b1b94709` |
| contracts/test/OracleFeed.t.sol | `50d9e9cabb388194` |
| contracts/test/RateSortedList.invariant.t.sol | `8fa8e6a375e4ed7d` |
| contracts/test/RateSortedList.t.sol | `85ae503e09a92cf0` |
| contracts/test/Redemption.t.sol | `148b3be0d7adf45f` |
| contracts/test/StabilityPool.t.sol | `c7530b42b466d6c5` |
| contracts/test/StableToken.t.sol | `049ab75f2a809d16` |
| contracts/test/mocks/BranchMocks.sol | `dcc3313ca6048a53` |
| contracts/test/mocks/OracleMocks.sol | `1edf7f875d9e124d` |
| contracts/test/vectors/branch_trace.json | `ec1cd8f258370056` |
| contracts/test/vectors/math.json | `ee94c997bb9c3d9e` |
| contracts/test/vectors/routing_trace.json | `2c764725c5720116` |
| contracts/test/vectors/sorted_list.json | `aee5b22cb952dcd8` |
| contracts/test/vectors/stability_pool.json | `10988275992dda22` |
| docs/SPEC.md | `242ddf6f83ba771d` |
| model/beta_pilot_compare.py | `64251462b830a798` |
| model/check_figures.py | `a020fc9d36346070` |
| model/check_manifest.py | `14c03d6c403bcf14` |
| model/econ_sim.py | `879485b31c7fc5a0` |
| model/figures.py | `369609e969c9154a` |
| model/fuzz.py | `4f1e47e68c2212d3` |
| model/fuzz_oracle.py | `4d286d579088865a` |
| model/model.py | `38e376306f913e30` |
| model/mutants.py | `7f0180084e5a773a` |
| model/pilot_sweep.py | `fedbe2706b9613eb` |
| model/results/beta_pilot_compare.jsonl | `fa07685fba612226` |
| model/results/figures.json | `2d610c8ab1995f69` |
| model/results/pilot_seeds.jsonl | `93d76cc221a27b03` |
| model/results/pilot_summary.jsonl | `3490a40155f0a8b5` |
| model/spec_check.py | `35cc0cb81d8679d8` |
| model/study_figures.py | `b48e908d52ad4f07` |
| model/test_econ_sim.py | `4e0aa5314c0d81a3` |
| model/test_scenarios.py | `6c1a5189368b4670` |

### Submodules, at the commit this release pins

| submodule | commit | tag |
| --- | --- | --- |
| contracts/lib/forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | v1.9.7 |
| contracts/lib/openzeppelin-contracts | `69c8def5f222ff96f2b5beff05dfba996368aa79` | v5.1.0 |

## Run record for version 0.0.1

| group | command | tool | result |
| --- | --- | --- | --- |
| scenarios | `python3 test_scenarios.py` | Python 3.12 | <!-- fig:scenarios.scenarios_passed -->34<!-- /fig -->/<!-- fig:scenarios.scenarios_total -->34<!-- /fig --> passed |
| simulator self-tests | `python3 test_econ_sim.py` | Python 3.12 | <!-- fig:econ_sim.econ_sim_passed -->8<!-- /fig -->/<!-- fig:econ_sim.econ_sim_total -->8<!-- /fig --> passed |
| accounting fuzzer | `python3 fuzz.py 30 300` | Python 3.12 | no property violated (max eps <!-- fig:fuzz.fuzz_max_eps_wei -->17<!-- /fig --> wei); <!-- fig:fuzz.fuzz_troves_rewarded -->51<!-- /fig --> Troves rewarded; every operation met its coverage floor |
| oracle fuzzer | `python3 fuzz_oracle.py 200 150` | Python 3.12 | no property violated |
| mutants | `python3 mutants.py` | Python 3.12 | <!-- fig:mutants.mutants_total -->37<!-- /fig --> run, <!-- fig:mutants.mutants_killed -->37<!-- /fig --> killed, <!-- fig:mutants.mutants_survived -->0<!-- /fig --> survived, <!-- fig:mutants.mutants_invalid -->0<!-- /fig --> invalid |
| spec mapping | `python3 spec_check.py` | Python 3.12 | every scenario, every mutant and every Foundry test that `docs/SPEC.md` cites exists, and every scenario and mutant is cited |
| manifest | `python3 check_manifest.py` | Python 3.12 | all hashes match, all required files listed |
| figures | `python3 check_figures.py` | Python 3.12 | every figure quoted below matches the run that produced it |
| differential vectors | `python3 contracts/script/export_vectors.py model` | Python 3.12 | <!-- fig:contracts.vectors_total -->1,292<!-- /fig --> vectors, identical to the shipped file; <!-- fig:contracts.vectors_stepB_beyond_256_bit_product -->64<!-- /fig --> of them exercise step B where `debt × rate` exceeds 256 bits |
| redemption queue vectors | the same command | Python 3.12 | <!-- fig:contracts.list_vector_operations -->561<!-- /fig --> list operations (insertions, removals, rate changes) taken from a run of the model's branch, and <!-- fig:contracts.list_vector_queues_checked -->485<!-- /fig --> whole queues in the model's order, <!-- fig:contracts.list_vector_queues_with_ties -->449<!-- /fig --> of them holding tied rates, up to <!-- fig:contracts.list_vector_max_size -->80<!-- /fig --> Troves; `RateSortedList` reproduces every queue whether its hints are exact, empty, reversed, stale or arbitrary |
| branch trace | the same command | Python 3.12 | <!-- fig:contracts.branch_trace_steps -->700<!-- /fig --> steps of the model's branch, <!-- fig:contracts.branch_trace_accepted -->411<!-- /fig --> accepted and <!-- fig:contracts.branch_trace_refused -->289<!-- /fig --> refused, over <!-- fig:contracts.branch_trace_troves -->31<!-- /fig --> Troves, with <!-- fig:contracts.branch_trace_liquidations -->22<!-- /fig --> liquidations (<!-- fig:contracts.branch_trace_liquidations_offset -->14<!-- /fig --> against the Stability Pool, <!-- fig:contracts.branch_trace_liquidations_redistributed -->15<!-- /fig --> redistributed, some both) and <!-- fig:contracts.branch_trace_redemptions -->27<!-- /fig --> redemptions (<!-- fig:contracts.branch_trace_redeemed_to_zero -->13<!-- /fig --> Troves redeemed to zero, <!-- fig:contracts.branch_trace_tracked_zombies -->5<!-- /fig --> left under the minimum as the tracked Zombie, <!-- fig:contracts.branch_trace_zombies_back_through_adjust -->4<!-- /fig --> Zombies back in the queue through `adjustTrove`), ending shut down; every Trove and the queue compared in full <!-- fig:contracts.branch_trace_full_checks -->28<!-- /fig --> times; `BranchManager` and `CollateralRegistry` accept and refuse the same operations and match every recorded number, the base rate and the tracked Zombie included |
| routing trace | the same command | Python 3.12 | <!-- fig:contracts.routing_trace_steps -->400<!-- /fig --> steps of a model system with three branches, <!-- fig:contracts.routing_trace_redemptions -->54<!-- /fig --> redemptions, <!-- fig:contracts.routing_trace_truncated -->4<!-- /fig --> of them truncated to the uncovered debt and <!-- fig:contracts.routing_trace_by_debt -->3<!-- /fig --> split by debt because no redeemable branch had any uncovered; branches excluded for a price that is not Valid, for TCR under SCR and after a shutdown; `CollateralRegistry` and the three branches match every recorded number |
| Stability Pool vectors | the same command | Python 3.12 | <!-- fig:contracts.sp_trace_steps -->400<!-- /fig --> operations on the model's pool; <!-- fig:contracts.sp_trace_rescaling_offsets -->32<!-- /fig --> offsets rescaled P, <!-- fig:contracts.sp_trace_multi_rescale_offsets -->4<!-- /fig --> of them more than once, up to scale <!-- fig:contracts.sp_trace_max_scale -->36<!-- /fig -->; `StabilityPool` matches every value of the pool and of every depositor |
| Solidity | `forge test` | forge 1.5.1-stable, solc 0.8.26 | <!-- fig:contracts.declared_tests -->91<!-- /fig --> passed, 0 failed; `check_test_count.py` confirms forge ran exactly the declared number |
| pilot tables | `python3 pilot_sweep.py 0 6 20` | Python 3.12 | shipped in `results/`; hardest case rerun identical |

All on the release commit, 2026-09-22, Linux x86-64. A hash match proves a file is the one recorded; this table records that the results were produced by running these files.

## Current results on exactly these files, byte-code caching disabled

Every number below is recorded by the run that computes it and checked by `python3 check_figures.py`; none is typed in by hand.

- `test_scenarios.py`: **<!-- fig:scenarios.scenarios_passed -->34<!-- /fig -->/<!-- fig:scenarios.scenarios_total -->34<!-- /fig --> scenarios passed** (scenario 27(c) tests the rounding bound with a <!-- fig:scenarios.claim_order_earlier_claims -->100<!-- /fig -->-claim case)
- `fuzz.py 30 300`: <!-- fig:fuzz.fuzz_stats -->{'ok': 4253, 'reverted': 904, 'max_eps': 17, 'max_ratio': 0.4444444444444444, 'shutdowns': 33, 'with_bad_debt': 18, 'troves_rewarded': 51, 'gas_paid_total': 51000000000000000}<!-- /fig -->
  The first branch posts a deposit, so the run asserts both that a deposit exists and that rewards were actually paid.
- `fuzz_oracle.py 200 150`: <!-- fig:fuzz_oracle.fuzz_oracle_stats -->{'Valid': 1243, 'PriceInvalid': 1016, 'NetworkUnstable': 3104, 'Failed': 2814, 'revert': 2364}<!-- /fig -->
- `test_econ_sim.py`: **<!-- fig:econ_sim.econ_sim_passed -->8<!-- /fig -->/<!-- fig:econ_sim.econ_sim_total -->8<!-- /fig --> simulator self-tests passed**

### Fuzzer coverage
An invariant that holds over a path never taken proves nothing, so the accounting fuzzer asserts a floor on how often each
operation must actually succeed (`MIN_COVERAGE` in `fuzz.py`), scaled to the budget; a path that stops being reachable
fails the run instead of silently leaving the histogram. Successful executions at `30 300`: liquidation <!-- fig:fuzz.fuzz_ops_liq -->58<!-- /fig -->, bad-debt claims <!-- fig:fuzz.fuzz_ops_bad_debt -->23<!-- /fig -->, redemptions <!-- fig:fuzz.fuzz_ops_redeem -->52<!-- /fig -->,
Stability Pool deposits <!-- fig:fuzz.fuzz_ops_sp_dep -->61<!-- /fig -->, settlement and write-off <!-- fig:fuzz.fuzz_ops_urgent -->37<!-- /fig -->, late
settlement of a written-off Trove <!-- fig:fuzz.fuzz_ops_late -->8<!-- /fig -->, late-recovery claims <!-- fig:fuzz.fuzz_ops_claim_late -->11<!-- /fig -->; <!-- fig:fuzz.fuzz_shutdowns -->33<!-- /fig --> branches shut down over the run.

### What the random testers kill on their own
Of <!-- fig:mutants.mutants_total -->37<!-- /fig --> mutants, all <!-- fig:mutants.mutants_killed -->37<!-- /fig --> are killed, but only <!-- fig:mutants.mutants_killed_by_a_fuzzer -->13<!-- /fig --> are killed by a random tester with no scenario at all
(<!-- fig:mutants.mutants_killed_by_fuzz -->7<!-- /fig --> by the accounting fuzzer, <!-- fig:mutants.mutants_killed_by_fuzz_oracle -->6<!-- /fig --> by the
oracle fuzzer). The fuzzers are invariant checkers, not behavioural oracles: the scenarios carry the rest, and the
conformance map in `docs/SPEC.md` 12 is written against these counts rather than against the mere existence of a fuzzer.

### Stability Pool exactness
`scenario_17` compares every depositor against a rational shadow: the pool never over-pays by more than one wei, the
worst under-payment observed is <!-- fig:scenarios.sp_worst_underpayment_wei -->3<!-- /fig --> wei, and the deepest scale reached is <!-- fig:scenarios.sp_deepest_scale -->8<!-- /fig --> (`MAX_SCALE_DIFF`).

### Rounding bound 
Each claim of R units receives floor(pot * R / claims) and leaves < 1 wei in the pot; a later claim receives at most R / claims <= 1 wei of each earlier
claim's dust. So a pay-out moves by at most (number of earlier claims) wei, and splitting a claim into k parts loses at most k wei.
Measured: <!-- fig:scenarios.claim_order_shift_wei -->50<!-- /fig --> wei after <!-- fig:scenarios.claim_order_earlier_claims -->100<!-- /fig --> earlier claims, within the bound of <!-- fig:scenarios.claim_order_earlier_claims -->100<!-- /fig -->; splitting one claim into <!-- fig:scenarios.claim_split_parts -->10<!-- /fig --> parts lost <!-- fig:scenarios.claim_split_loss_wei -->4<!-- /fig --> wei, within the bound of <!-- fig:scenarios.claim_split_parts -->10<!-- /fig -->.

### Ownership accounting 
Surplus: entitlement_i = floor(gross_i * keep) - paid_i, with gross_i and keep both non-decreasing along every allowed path (a late Trove of the same owner only adds to
gross_i; a late recovery only lowers the absorbed shortfall), so the entitlement never falls and the time of claiming cannot change the total (6 / 20 ETH single-owner case: <!-- fig:scenarios.late_recovery_single_owner_eth -->20.9952<!-- /fig --> on both paths). Gas: each Trove has its own remaining deposit; write-off pays half of it, the settlement pays the rest, and
no path can pay more than the deposit (three-Trove case: <!-- fig:scenarios.path_gas_paid_eth -->0.030<!-- /fig --> paid for <!-- fig:scenarios.path_gas_posted_eth -->0.030<!-- /fig --> posted).

### Late recovery: the end state equals a timely settlement
Let C = collateral handed over by settled Troves, S = shortfalls (a written-off Trove counts its whole par need), G = healthy borrowers' gross surplus,
take = min(S, G), pot = C + take, keep = (G - take) / G. When a written-off Trove pays after all, C, S and G are RECOMPUTED, holders receive pot' - pot
(shared per claim unit), and every owner's entitlement becomes gross_i * keep'. Since pot' - pot = c + take' - take and keep' * G' - keep * G = g - take' + take,
the two together equal c + g, the Trove's whole collateral: exact conservation. pot' - pot >= 0 because pot = C + min(S, G) never exceeds par and rises to par
first. `scenario_29` checks the 6 / 20 ETH case (A <!-- fig:scenarios.late_recovery_a_eth -->3.4976<!-- /fig -->, B <!-- fig:scenarios.late_recovery_b_eth -->17.4976<!-- /fig --> on both paths), the empty-pot case (the early burner
receives the same late share as the late claimant), a real-shortfall case under both variants, and the fuzzer's find (a written-off Trove settled while phase 1 is
still open reverses the write-off).

### Completion of settlement 
`scenario_27`: (a) <!-- fig:scenarios.settle_troves -->1,500<!-- /fig --> Troves settled in <!-- fig:scenarios.settle_batches -->30<!-- /fig --> batches of <!-- fig:scenarios.settle_batch_size -->50<!-- /fig --> with `open_troves()` replaced by a function that fails the test: constant work per Trove, no scan;
the settler receives every gas deposit; a batch one over `MAX_SETTLE_BATCH` is refused. (b) one Trove is never settled: claims and write-off are refused for 30 days; then anyone writes it off,
phase 1 ends, holder A is paid; the Trove is settled later after all; A's late share + B's later claim are equal to within 3 wei, under both variants; under
"borrowers absorb" the borrower whose surplus had covered for it is refunded; all collateral is conserved to the wei. (c) rounding: the one-wei example reproduced;
order moves a pay-out by at most 1 wei per earlier claim, splitting a claim into <!-- fig:scenarios.claim_split_parts -->10<!-- /fig --> parts loses at most <!-- fig:scenarios.claim_split_parts -->10<!-- /fig --> wei.
NOT modelled: real gas; a Trove whose settlement reverts because of a contract bug (the write-off path assumes its debt can at least be read).

### Order independence
`scenario_22`: three shutdown states, EVERY permutation of settling Troves x EVERY permutation of claiming, both variants: identical payout per holder (<= 2 wei).
`scenario_30`: <!-- fig:scenarios.path_combinations -->32<!-- /fig --> path combinations end within <!-- fig:scenarios.path_tolerance_wei -->6<!-- /fig --> wei of an independent rational computation.
`scenario_23`: payouts equal an independent rational-arithmetic computation; conservation of all collateral; surplus withheld until phase 1 ends; fully backed state pays exactly par;
zero-debt Trove, pending redistribution, last-Trove dust, market price different from the reference price.
Rates in the two-Trove example (Troves ~120% and ~60%): **<!-- fig:scenarios.holders_rate_absorb -->0.8991<!-- /fig --> for both holders** with borrowers absorbing, **<!-- fig:scenarios.holders_rate_parity -->0.7997<!-- /fig --> for both** with vault parity.

### `python3 pilot_sweep.py <first> <last> 20` — the proposed pilot, staged settlement, healthy borrowers absorb first
<!-- fig:studies.pilot_table_results -->

| case | shutdowns / 20 | min economic backing mean / median / worst | holders' recovery mean / median / worst run | worst account | best minus worst account (max over runs) | balances losing >=1%: mean / worst run | borrowers' surplus kept (mean, USD) | SP result mean / worst | LP settlement % mean / worst |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pilot, calm + 10% dump | 0 | 1.77 / 1.82 / 1.23 | 1.000 / 1.000 / 1.000 | 1.00 | 0.000000 | 0% / 0% | 0 | +360 / +0 | +0.8 / +0.5 |
| ETH -40% in 24h, network up | 3 | 1.38 / 1.35 / 1.04 | 0.997 / 1.000 / 0.972 | 0.97 | 0.000000 | 15% / 100% | 575 | +1306 / +0 | +0.6 / -0.8 |
| ETH -40%, feed dead 12h, network up | 3 | 1.38 / 1.35 / 1.04 | 0.996 / 1.000 / 0.965 | 0.96 | 0.000000 | 15% / 100% | 560 | +1281 / +0 | +0.6 / -1.6 |
| ETH -40% during 12h sequencer outage | 3 | 1.39 / 1.34 / 1.04 | 0.996 / 1.000 / 0.965 | 0.96 | 0.000000 | 15% / 100% | 538 | +1218 / +0 | +0.6 / -1.6 |
| ETH -60% in 24h, network up | 13 | 1.12 / 1.09 / 1.03 | 1.000 / 1.000 / 0.951 | 0.95 | 0.000000 | 40% / 100% | 2,085 | +2079 / +175 | +0.2 / -2.6 |
| ETH -60% during 24h sequencer outage | 13 | 0.99 / 1.03 / 0.57 | 0.922 / 0.999 / 0.566 | 0.57 | 0.000000 | 35% / 100% | 1,299 | -2404 / -14012 | -4.3 / -23.2 |

<!-- /fig -->


Reading: the largest spread between accounts in any run of any case is <!-- fig:studies.pilot_max_spread_between_accounts -->4e-16<!-- /fig --> of a token's recovery, the simulator's floating-point
rounding (econ_sim works in floats; the reference model does not). Recovery below 1.00 in the milder cases is the fall of the collateral's MARKET price between the
shutdown and the claim (settlement is at the reference price); it is not a shortfall. The tables in this section, and every figure the whitepaper quotes from the
pilot, are generated from the committed `results/*.jsonl` by `study_figures.py`; the summary key `min_tcr` holds economic backing (see that script).

### `python3 beta_pilot_compare.py <first> <last> 20` — beta on the pilot's REAL fixed-range pool, identical market paths, beta sampled once
<!-- fig:studies.beta_table_results -->

| shock | policy | sell volume the pool could not fill | redeemed (% of supply) | of which by stuck sellers themselves | borrower exits / opened | final supply | LP at settlement value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| calm + 10% dump | beta = 1 | 4.7% | 4% | 4,259 | 1.8 / 50 | 124,760 | +1.2% |
| calm + 10% dump | beta = 2 | 6.1% | 12% | 11,422 | 5.6 / 44 | 103,948 | +0.9% |
| calm + 10% dump | beta = 4 | 8.3% | 28% | 21,864 | 10.6 / 41 | 88,492 | +0.8% |
| calm + 10% dump | pressure formula | 5.7% | 11% | 10,208 | 4.9 / 47 | 112,067 | +1.0% |
| calm + 10% dump | size formula | 8.3% | 28% | 21,864 | 10.6 / 41 | 88,492 | +0.8% |
| ETH -40% / 24h | beta = 1 | 5.2% | 4% | 4,180 | 1.9 / 58 | 108,132 | +1.7% |
| ETH -40% / 24h | beta = 2 | 6.6% | 13% | 11,350 | 5.5 / 50 | 89,089 | +1.3% |
| ETH -40% / 24h | beta = 4 | 9.2% | 29% | 21,864 | 10.6 / 45 | 73,527 | +1.4% |

<!-- /fig -->

**Reading.** On the pool the design actually uses the ranking reverses: with beta = 1 there is less unserved selling, far less
redemption (<!-- fig:studies.beta_redeemed_pct_beta1_calm -->4<!-- /fig -->% of supply against <!-- fig:studies.beta_redeemed_pct_beta4_calm -->28<!-- /fig -->%), <!-- fig:studies.beta_exit_ratio_calm -->6.0<!-- /fig --> times fewer borrower exits in the calm case and <!-- fig:studies.beta_exit_ratio_crash40 -->5.6<!-- /fig --> times fewer after a 40% crash, and a larger supply. The reason is structural: inside a 0.99 - 1.01 band a redemption of
1,000 costs 1.5% with beta = 1, so it never pays and the band itself carries the price; with beta = 4 it costs 0.75%, so stuck sellers and keepers redeem and
low-rate borrowers are pushed out. A companion study on a virtual-reserve pool, in which the price is free to fall, gives the opposite ranking: there cheaper redemption tightens the peg. That study is not in this package (next section).
**Neither result settles beta**; what the two studies show together is that beta trades the
holders' cost of exit against the borrowers' redemption burden, and that its effect depends on the shape of the liquidity. The dynamic formulas still show no advantage.

### Studies referred to but not in this package

The whitepaper draws four conclusions from studies whose scripts and output are not in this repository. It states each only
qualitatively and quotes no number from it, because nothing here can reproduce one.

| Study | Conclusion the whitepaper draws from it |
| --- | --- |
| Pilot size sweep | the size of the pilot: the smallest debt at which the mechanism works, and the size beyond which results stop improving |
| Beta on a virtual-reserve pool, whose price is free to fall | with that pool shape, a larger beta tightens the peg (the opposite of the fixed-range result above) |
| Liquidity providers paid a share of interest | liquidity in the pool is highly sensitive to an assumed income |
| Keeper latency | keeper speed is among the largest effects on the distance from the peg |

Bringing one in means committing the script that runs it and its output under `model/results/`, adding it to the manifest,
and quoting its figures through markers.
