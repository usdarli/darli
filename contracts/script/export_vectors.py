"""
Differential-test vectors: the Python reference model is the oracle, Solidity must match bit for bit.
    python3 script/export_vectors.py ../model          -> test/vectors/math.json
"""
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else "../model")
from model import WAD, YEAR, dec_pow, ceil_div, _minute_decay_factor  # noqa: E402

rng = random.Random(20260919)
S = str

decay6h = _minute_decay_factor(360)
bases = [decay6h, _minute_decay_factor(60), _minute_decay_factor(2880), WAD, WAD - 1, WAD // 2, 1, 0]
dp = {"base": [], "exp": [], "out": []}
for b in bases:
    for n in [0, 1, 2, 3, 59, 60, 359, 360, 361, 720, 1440, 10_080, 525_600, 525_600_000, 525_600_001, 10**12]:
        dp["base"].append(S(b)); dp["exp"].append(S(n)); dp["out"].append(S(dec_pow(b, n)))
for _ in range(300):
    b, n = rng.randint(0, WAD), rng.choice([rng.randint(0, 5000), rng.randint(0, 10**9)])
    dp["base"].append(S(b)); dp["exp"].append(S(n)); dp["out"].append(S(dec_pow(b, n)))

# step A (ceil) and step B (floor) of whitepaper 4.2
ia = {"aggW": [], "dt": [], "out": []}
ib = {"debt": [], "rate": [], "dt": [], "out": []}
for _ in range(400):
    debt = rng.choice([rng.randint(1, 10**12), rng.randint(10**18, 10**30)])
    rate = rng.randint(1, 25 * WAD // 10)
    dt = rng.choice([0, 1, 12, 3600, 86400, 365 * 86400, rng.randint(0, 10**9)])
    ia["aggW"].append(S(debt * rate)); ia["dt"].append(S(dt)); ia["out"].append(S(ceil_div(debt * rate * dt, YEAR * WAD)))
    ib["debt"].append(S(debt)); ib["rate"].append(S(rate)); ib["dt"].append(S(dt)); ib["out"].append(S(debt * rate * dt // (YEAR * WAD)))

# step B over the WHOLE debt domain. `troveInterest` once computed `recordedDebt * annualRate` in plain uint256 before its
# 512-bit mulDiv, so it reverted wherever that product overflowed (debt above ~4.6e58 at the 250 % ceiling) although the
# exact result fits easily, and the model -- which has no such limit -- returned a value. These vectors sit in exactly
# that band. A separate generator keeps every earlier vector byte-identical, so the diff is append-only.
big = random.Random(20260923)
for _ in range(64):
    debt = big.randint(10**58, 10**70)
    rate = big.randint(25 * WAD // 10 // 2, 25 * WAD // 10)       # upper half of the rate range: the overflowing band
    dt = big.choice([1, 3600, 86400, 365 * 86400, big.randint(0, 10**9)])
    ib["debt"].append(S(debt)); ib["rate"].append(S(rate)); ib["dt"].append(S(dt)); ib["out"].append(S(debt * rate * dt // (YEAR * WAD)))
overflowing = sum(1 for d, r in zip(ib["debt"], ib["rate"]) if int(d) * int(r) >= 2**256)
assert overflowing >= 32, f"only {overflowing} large-debt vectors overflow debt * rate: the band is not being tested"

out = Path(__file__).resolve().parent.parent / "test" / "vectors" / "math.json"
out.write_text(json.dumps({"decay6h": S(decay6h), "decpow": dp, "stepA": ia, "stepB": ib}))

# Figures of record for contracts/ (model/figures.py). This is the one Python step that speaks for the Solidity side, and
# it runs without forge, so the evidence job can record these next to every other figure. `declared_tests` is a static
# count of `function test...` in contracts/test; `make contracts` checks that `forge test` ran exactly that many, so the
# number docs/RESULTS.md quotes is both generated and cross-checked against the tool.
import re  # noqa: E402
from figures import fig, dump  # noqa: E402

tests_dir = Path(__file__).resolve().parent.parent / "test"
declared = sum(len(re.findall(r"^\s*function\s+test\w*\s*\(", f.read_text(encoding="utf-8"), re.M))
               for f in sorted(tests_dir.rglob("*.sol")))
fig("vectors_total", len(dp["out"]) + len(ia["out"]) + len(ib["out"]), ",")
fig("vectors_stepB_beyond_256_bit_product", overflowing)
fig("declared_tests", declared)
dump("contracts")
print(f"wrote {out} ({len(dp['out'])} decPow, {len(ia['out'])} stepA, {len(ib['out'])} stepB vectors, "
      f"{overflowing} of them beyond where debt * rate fits in 256 bits)")
