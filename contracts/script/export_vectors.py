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

out = Path(__file__).resolve().parent.parent / "test" / "vectors" / "math.json"
out.write_text(json.dumps({"decay6h": S(decay6h), "decpow": dp, "stepA": ia, "stepB": ib}))
print(f"wrote {out} ({len(dp['out'])} decPow, {len(ia['out'])} stepA, {len(ib['out'])} stepB vectors)")
