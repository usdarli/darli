# Results of record (version 0.0.1)

Every figure quoted in the documents comes from this file. Reproduce with the commands in `model/README.md`; the manifest lists the sha256 (first 16 hex) of every file the figures depend on.

> **Caveats.** Behaviour in every economic run is uncalibrated. The pilot tables use the fixed-range pool, finite keeper budgets and identical market paths per seed. The "vault parity" tables (rejected loss-sharing rule) are not shipped; regenerate with `VAULT_PARITY=1 python3 pilot_sweep.py 4 6 20`.

## Manifest — the only list of hashes in this file (sha256, first 16 hex)
| file | hash |
| --- | --- |
| model/beta_pilot_compare.py | `64251462b830a798` |
| model/check_manifest.py | `2f901179b726f247` |
| model/econ_sim.py | `879485b31c7fc5a0` |
| model/fuzz.py | `d4156587f0234a12` |
| model/fuzz_oracle.py | `bd0b958ba3b95874` |
| model/model.py | `cff6b6b56e6d668b` |
| model/mutants.py | `f843e7c2fc7e8b60` |
| model/pilot_sweep.py | `fedbe2706b9613eb` |
| model/spec_check.py | `956fc8d649b1d115` |
| model/test_econ_sim.py | `5a7fc6dbfc4e20d7` |
| model/test_scenarios.py | `b147cad481aa3f8b` |
| model/results/pilot_seeds.jsonl | `93d76cc221a27b03` |
| model/results/pilot_summary.jsonl | `3490a40155f0a8b5` |
| model/results/beta_pilot_compare.jsonl | `fa07685fba612226` |
| docs/SPEC.md | `8dee4513e00ac8c5` |

## Run record for version 0.0.1

| group | command | tool | result |
| --- | --- | --- | --- |
| scenarios | `python3 test_scenarios.py` | Python 3.12 | 30/30 passed |
| simulator self-tests | `python3 test_econ_sim.py` | Python 3.12 | 8/8 passed |
| accounting fuzzer | `python3 fuzz.py 30 300` | Python 3.12 | no property violated (max eps 19 wei); 43 Troves rewarded |
| oracle fuzzer | `python3 fuzz_oracle.py 200 150` | Python 3.12 | no property violated |
| mutants | `python3 mutants.py` | Python 3.12 | 32 run, 32 killed, 0 survived, 0 invalid |
| spec mapping | `python3 spec_check.py` | Python 3.12 | all 30 scenarios and all 32 mutants cited and exist |
| manifest | `python3 check_manifest.py` | Python 3.12 | all hashes match, all required files listed |
| differential vectors | `python3 contracts/script/export_vectors.py model` | Python 3.12 | 1,228 vectors, identical to the shipped file |
| Solidity | `forge test` | forge 1.5.1-stable, solc 0.8.26 | 31 passed, 0 failed |
| pilot tables | `python3 pilot_sweep.py 0 6 20` | Python 3.12 | shipped in `results/`; hardest case rerun identical |

All on the release commit, 2026-09-22, Linux x86-64. A hash match proves a file is the one recorded; this table records that the results were produced by running these files.

## Current results on exactly these files , byte-code caching disabled
- `test_scenarios.py`: **30/30 scenarios passed** (scenario 27(c) tests the rounding bound with a 100-claim case)
- `fuzz.py 30 300`: {'ok': 4609, 'reverted': 777, 'max_eps': 19, 'max_ratio': 0.42857142857142855, 'shutdowns': 32, 'with_bad_debt': 18, 'troves_rewarded': 43, 'gas_paid_total': 42000000000000000}
  The first branch now really posts a deposit ; the run asserts that
  at least one branch has a deposit and that rewards were actually paid.
- `fuzz_oracle.py 200 150`: {'Valid': 1243, 'PriceInvalid': 1016, 'NetworkUnstable': 3104, 'Failed': 2814, 'revert': 2364}
- `test_econ_sim.py`: **8/8 simulator self-tests passed**

### Rounding bound 
Each claim of R units receives floor(pot * R / claims) and leaves < 1 wei in the pot; a later claim receives at most R / claims <= 1 wei of each earlier
claim's dust. So a pay-out moves by at most (number of earlier claims) wei, and splitting a claim into k parts loses at most k wei. Measured: 40 wei after 100 earlier claims, within the bound of 100.

### Ownership accounting 
Surplus: entitlement_i = floor(gross_i * keep) - paid_i, with gross_i and keep both non-decreasing along every allowed path (a late Trove of the same owner only adds to
gross_i; a late recovery only lowers the absorbed shortfall), so the entitlement never falls and the time of claiming cannot change the total (6 / 20 ETH single-owner case: 20.9952 on both paths). Gas: each Trove has its own remaining deposit; write-off pays half of it, the settlement pays the rest, and
no path can pay more than the deposit (three-Trove case: 0.030 paid for 0.030 posted).

### Late recovery: the end state equals a timely settlement
Let C = collateral handed over by settled Troves, S = shortfalls (a written-off Trove counts its whole par need), G = healthy borrowers' gross surplus,
take = min(S, G), pot = C + take, keep = (G - take) / G. When a written-off Trove pays after all, C, S and G are RECOMPUTED, holders receive pot' - pot
(shared per claim unit), and every owner's entitlement becomes gross_i * keep'. Since pot' - pot = c + take' - take and keep' * G' - keep * G = g - take' + take,
the two together equal c + g, the Trove's whole collateral: exact conservation. pot' - pot >= 0 because pot = C + min(S, G) never exceeds par and rises to par
first. `scenario_29` checks the 6 / 20 ETH case (A 3.4976, B 17.4976 on both paths), the empty-pot case (the early burner
receives the same late share as the late claimant), a real-shortfall case under both variants, and the fuzzer's find (a written-off Trove settled while phase 1 is
still open reverses the write-off).

### Completion of settlement 
`scenario_27`: (a) 1,500 Troves settled in 30 batches of 50 with `open_troves()` replaced by a function that fails the test: constant work per Trove, no scan;
the settler receives every gas deposit; a batch of 51 is refused. (b) one Trove is never settled: claims and write-off are refused for 30 days; then anyone writes it off,
phase 1 ends, holder A is paid; the Trove is settled later after all; A's late share + B's later claim are equal to within 3 wei, under both variants; under
"borrowers absorb" the borrower whose surplus had covered for it is refunded; all collateral is conserved to the wei. (c) rounding: the one-wei example reproduced;
order moves a pay-out by at most 1 wei, splitting a claim into 10 parts loses at most 10 wei.
NOT modelled: real gas; a Trove whose settlement reverts because of a contract bug (the write-off path assumes its debt can at least be read).

### Order independence
`scenario_22`: three shutdown states, EVERY permutation of settling Troves x EVERY permutation of claiming, both variants: identical payout per holder (<= 2 wei).
`scenario_23`: payouts equal an independent rational-arithmetic computation; conservation of all collateral; surplus withheld until phase 1 ends; fully backed state pays exactly par;
zero-debt Trove, pending redistribution, last-Trove dust, market price different from the reference price.
Rates in the two-Trove example (Troves ~120% and ~60%): **0.8991 for both holders** with borrowers absorbing, **0.7997 for both** with vault parity
.

### `python3 pilot_sweep.py <first> <last> 20` — the proposed pilot, staged settlement, healthy borrowers absorb first
| case | shutdowns / 20 | min economic backing mean / median / worst | holders' recovery mean / median / worst run | worst account | best minus worst account (max over runs) | balances losing >=1%: mean / worst run | borrowers' surplus kept (mean, USD) | SP result mean / worst | LP settlement % mean / worst |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pilot, calm + 10% dump | 0 | 1.77 / 1.82 / 1.23 | 1.000 / 1.000 / 1.000 | 1.00 | 0.000000 | 0% / 0% | 0 | +360 / +0 | +0.8 / +0.5 |
| ETH -40% in 24h, network up | 3 | 1.38 / 1.35 / 1.04 | 0.997 / 1.000 / 0.972 | 0.97 | 0.000000 | 15% / 100% | 575 | +1306 / +0 | +0.6 / -0.8 |
| ETH -40%, feed dead 12h, network up | 3 | 1.38 / 1.35 / 1.04 | 0.996 / 1.000 / 0.965 | 0.96 | 0.000000 | 15% / 100% | 560 | +1281 / +0 | +0.6 / -1.6 |
| ETH -40% during 12h sequencer outage | 3 | 1.39 / 1.34 / 1.04 | 0.996 / 1.000 / 0.965 | 0.96 | 0.000000 | 15% / 100% | 538 | +1218 / +0 | +0.6 / -1.6 |
| ETH -60% in 24h, network up | 13 | 1.12 / 1.09 / 1.03 | 1.000 / 1.000 / 0.951 | 0.95 | 0.000000 | 40% / 100% | 2,085 | +2079 / +175 | +0.2 / -2.6 |
| ETH -60% during 24h sequencer outage | 13 | 0.99 / 1.03 / 0.57 | 0.922 / 0.999 / 0.566 | 0.57 | 0.000000 | 35% / 100% | 1,299 | -2404 / -14012 | -4.3 / -23.2 |


Reading: the spread between accounts is zero in every run of every case. Recovery below 1.00 in the milder cases is the fall of the collateral's MARKET price between the
shutdown and the claim (settlement is at the reference price); it is not a shortfall. `settlement_study.py` is obsolete (order cannot matter any more) and was removed from the current set.

### `python3 beta_pilot_compare.py <first> <last> 20` — beta on the pilot's REAL fixed-range pool, identical market paths, beta sampled once
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

**Reading.** On the pool the design actually uses the ranking reverses: with beta = 1 there is less unserved selling, far less
redemption (4% of supply against 28%), five times fewer borrower exits and a larger supply. The reason is structural: inside a 0.99 - 1.01 band a redemption of
1,000 costs 1.5% with beta = 1, so it never pays and the band itself carries the price; with beta = 4 it costs 0.75%, so stuck sellers and keepers redeem and
low-rate borrowers are pushed out. A companion study on a virtual-reserve pool, in which the price is free to fall, gives the opposite ranking: there cheaper redemption tightens the peg.
**Neither result settles beta**; what the two studies show together is that beta trades the
holders' cost of exit against the borrowers' redemption burden, and that its effect depends on the shape of the liquidity. The dynamic formulas still show no advantage.


