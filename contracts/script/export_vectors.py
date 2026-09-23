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

# --- the redemption queue (SPEC R2) ----------------------------------------------------------------------------------- #
# The model has no linked list: its queue is `Branch.redemption_order()`, a sort. So the vectors are taken from a run of
# the model's own branch -- opens, rate changes, closes, redemptions that turn Troves into Zombies, Zombies borrowing
# back into the queue, liquidations -- and every change of its Active set becomes a list operation, followed by the whole
# queue as the model orders it. Rates come mostly from a short list, so ties are the rule rather than an accident; the
# neighbours an exact hint would name are computed here, on a mirror, from the rule itself. RateSortedList.t.sol replays
# the operations with exact, empty, reversed, stale and random hints and must reproduce every queue.
from model import (Clock, Token, Feed, System, Revert, atomic, ACTIVE, ZOMBIE)  # noqa: E402

lr = random.Random(20260923 + 2)
E, PCT = WAD, WAD // 100
clock = Clock()
sysm = System(clock)
weth = Token("WETH")
feed = Feed(2000 * E)
br = sysm.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT,
                        pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=10**9 * E)
RATES = [br.min_rate, 1 * PCT, 1 * PCT, 2 * PCT, 3 * PCT, 7 * PCT]
USERS = [f"u{i}" for i in range(8)]
for u in USERS + ["whale"]:
    weth.mint(u, 10**7 * E)
whale = br.open_trove("whale", 10**6 * E, 5 * 10**6 * E, br.max_rate)    # supplies stable; ranks at the head


def pick_rate():
    return lr.choice(RATES) if lr.random() < 0.8 else lr.randint(br.min_rate, 10 * PCT)


def lop():
    """One user-level operation on the model branch; a model revert rolls it back and is simply skipped."""
    live = [t for t in br.troves.values() if t.status in (ACTIVE, ZOMBIE) and t.id != whale]
    active = [t for t in live if t.status == ACTIVE]
    zombies = [t for t in live if t.status == ZOMBIE]
    k = lr.choices(["open", "rate", "close", "redeem", "revive", "repay", "liquidate", "warp"],
                   [30, 18, 9, 14, 6, 6, 5, 12])[0]
    if k == "open" or not live:
        u = lr.choice(USERS)
        debt = lr.randint(2_000, 40_000) * E
        coll = debt * lr.randint(115, 300) // 100 // 2000
        return lambda: br.open_trove(u, coll, debt, pick_rate())
    if k == "rate" and active:
        t = lr.choice(active)
        return lambda: br.adjust_rate(t.id, pick_rate())
    if k == "close":
        t = lr.choice(live)

        def f():
            sysm.stable.transfer("whale", t.owner, br.debt_now(t))
            br.close_trove(t.id)
        return f
    if k == "redeem":
        return lambda: sysm.redeem("whale", lr.randint(500, 60_000) * E, max_iter=lr.randint(1, 8))
    if k == "revive" and zombies:
        t = lr.choice(zombies)

        return lambda: br.borrow(t.id, lr.randint(2_000, 10_000) * E)
    if k == "repay" and active:
        t = lr.choice(active)

        def f():
            sysm.stable.transfer("whale", t.owner, 5_000 * E)
            br.repay(t.id, lr.randint(1, 5_000) * E)
        return f
    if k == "liquidate" and active:
        def f():
            feed.price = 2000 * E * lr.randint(80, 97) // 100
            for t in [t for t in active if br.icr(t, feed.price) < br.mcr][:3]:
                br.liquidate(t.id, "keeper")
            feed.price = 2000 * E
        return f
    return lambda: clock.warp(lr.randint(1, 10 * 86_400))


mirror = []                                   # (rate, id) in list order: head (highest) first
ops = {"kind": [], "id": [], "rate": [], "prev": [], "next": []}
checks = {"len": [], "order": []}
INSERT, REMOVE, REINSERT, CHECK = 0, 1, 2, 3


def emit(kind, tid, rate, p=0, q=0):
    for key, v in zip(ops, (kind, tid, rate, p, q)):
        ops[key].append(S(v))


def place(tid, rate):
    """Where (rate, tid) goes by the rule: behind every node that ranks ahead of it. Returns (prev, next)."""
    i = 0
    while i < len(mirror) and mirror[i] > (rate, tid):
        i += 1
    mirror.insert(i, (rate, tid))
    return (mirror[i - 1][1] if i > 0 else 0), (mirror[i + 1][1] if i + 1 < len(mirror) else 0)


def unplace(tid):
    mirror[:] = [x for x in mirror if x[1] != tid]


def sync():
    """Turn the change of the model's Active set into list operations, then record the whole queue."""
    want = {t.id: t.rate for t in br.redemption_order()}
    have = {tid: rate for rate, tid in mirror}
    changed = False
    for tid in sorted(set(have) - set(want)):
        unplace(tid); emit(REMOVE, tid, 0); changed = True
    for tid in sorted(set(have) & set(want)):
        if have[tid] != want[tid]:
            unplace(tid); emit(REINSERT, tid, want[tid], *place(tid, want[tid])); changed = True
    for tid in sorted(set(want) - set(have)):
        emit(INSERT, tid, want[tid], *place(tid, want[tid])); changed = True
    order = [t.id for t in br.redemption_order()]
    assert order == [tid for _, tid in reversed(mirror)], "the mirror disagrees with the model's queue"
    if changed:
        emit(CHECK, 0, 0)
        checks["len"].append(S(len(order)))
        checks["order"].extend(S(tid) for tid in order)
    return order if changed else None


LIST_STEPS = 700
sync()
max_size = ties = 0
for _ in range(LIST_STEPS):
    try:
        atomic(sysm, lop())
    except Revert:
        pass
    order = sync()
    if order is not None:                      # a queue was recorded: does it hold two Troves at the same rate?
        max_size = max(max_size, len(order))
        rates = [br.troves[tid].rate for tid in order]
        ties += len(rates) != len(set(rates))
kinds = [int(k) for k in ops["kind"]]
n_ins, n_rem, n_re = kinds.count(INSERT), kinds.count(REMOVE), kinds.count(REINSERT)
assert min(n_ins, n_rem, n_re) >= 50 and max_size >= 20 and ties >= 100, (n_ins, n_rem, n_re, max_size, ties)
outl = Path(__file__).resolve().parent.parent / "test" / "vectors" / "sorted_list.json"
outl.write_text(json.dumps({"ops": ops, "checks": checks}))

# --- the borrower trace (SPEC 4, 8, 6.5 triggers): see borrower_trace.py ------------------------------------------------ #
import borrower_trace  # noqa: E402

trace, tstats = borrower_trace.build(random.Random(20260924))
never_ok = [k for k, n in tstats["ok_by_kind"].items() if n == 0]
never_refused = [k for k in ("open", "borrow", "repay", "withdraw", "adjust", "rate", "close", "sp_dep", "give")
                 if tstats["bad_by_kind"][k] == 0]
assert not never_ok and not never_refused, f"trace does not exercise: accepted {never_ok}, refused {never_refused}"
outt = Path(__file__).resolve().parent.parent / "test" / "vectors" / "borrower_trace.json"
outt.write_text(json.dumps(trace))

# Figures of record for contracts/ (model/figures.py). This is the one Python step that speaks for the Solidity side, and
# it runs without forge, so the evidence job can record these next to every other figure. `declared_tests` is a static
# count of `function test...` and `function invariant...` in contracts/test (forge runs and counts both); `make contracts`
# checks that `forge test` ran exactly that many, so the number docs/RESULTS.md quotes is both generated and cross-checked
# against the tool.
import re  # noqa: E402
from figures import fig, dump  # noqa: E402

tests_dir = Path(__file__).resolve().parent.parent / "test"
declared = sum(len(re.findall(r"^\s*function\s+(?:test|invariant)\w*\s*\(", f.read_text(encoding="utf-8"), re.M))
               for f in sorted(tests_dir.rglob("*.sol")))
fig("vectors_total", len(dp["out"]) + len(ia["out"]) + len(ib["out"]), ",")
fig("vectors_stepB_beyond_256_bit_product", overflowing)
fig("declared_tests", declared)
fig("list_vector_operations", n_ins + n_rem + n_re, ",")
fig("list_vector_queues_checked", len(checks["len"]), ",")
fig("list_vector_queues_with_ties", ties, ",")
fig("list_vector_max_size", max_size)
fig("borrower_trace_steps", tstats["steps"])
fig("borrower_trace_accepted", tstats["ok"])
fig("borrower_trace_refused", tstats["refused"])
fig("borrower_trace_troves", tstats["troves"])
fig("borrower_trace_full_checks", tstats["full_checks"])
dump("contracts")
print(f"wrote {out} ({len(dp['out'])} decPow, {len(ia['out'])} stepA, {len(ib['out'])} stepB vectors, "
      f"{overflowing} of them beyond where debt * rate fits in 256 bits)")
print(f"wrote {outt} ({tstats['steps']} steps: {tstats['ok']} accepted, {tstats['refused']} refused; "
      f"{tstats['troves']} Troves; {tstats['full_checks']} full checks; ends shut down)")
print(f"wrote {outl} ({n_ins} inserts, {n_rem} removals, {n_re} reinsertions; {len(checks['len'])} queues checked, "
      f"{ties} with tied rates, up to {max_size} Troves)")
