"""
A liquidity-vault accounting trace from the reference model, for LPFeeAccounting.trace.t.sol to replay (SPEC V6).

The model's LPFeeVault (its books; the pool itself is the Solidity vault's, tested on a fork) is driven through deposits
and withdrawals of liquidity by four holders, swap fees in both tokens, reward tokens paid in and streamed over fixed
epochs, claims and time. Scripted stretches make every seed meet what the books are for: fees and rewards that arrive
while nobody holds shares (carried forward), a just-in-time entrant after fees were collected (it gets none of them), a
holder who leaves and claims later, and a withdrawal above the holder's shares (refused). Each step records the operation,
whether the model accepted it, and afterwards the accumulators, the stream and every holder's shares, snapshots, amounts
owed and amounts claimed.

Imported by export_vectors.py; `build(rng)` returns the JSON-ready trace and the statistics recorded as figures.
"""
from model import Clock, LPFeeVault, Revert, atomic, WAD, DAY, require

E = WAD
N = 4
NAMES = [f"l{i}" for i in range(N)]
OPS = ["deposit", "withdraw", "fees", "incentive", "claim", "warp"]
STEPS = 360
START = 1_700_000_000
LEDGER_LEN = 11 + 10 * N
ALL = 3                                  # a claim's token: 0, 1, 2 alone (SPEC V7), or all three


def build(rng):
    clock = Clock()
    assert clock.now == START
    v = LPFeeVault(clock)
    W = v.PERIOD
    claimed = {n: [0, 0, 0] for n in NAMES}
    ops = {k: [] for k in ("kind", "who", "a", "b", "ok")}
    ledger = []
    ok_by_kind = {k: 0 for k in OPS}
    bad_by_kind = {k: 0 for k in OPS}
    st = dict(unassigned_rolled=0, idle_streamed=0, jit_entrant_got_no_old_fees=0, one_token_left_the_others=0)

    def snapshot():
        s = v.stream
        row = [v.total, *v.acc, *v.unassigned, s.last, s.rate, s.queued, s.idle]
        for n in NAMES:
            row += [v.shares[n], *v.snap[n], *v.owed[n], *claimed[n]]
        return row

    def record(kind, fn, who=0, a=0, b=0):
        try:
            atomic(v, fn)
            ok = 1
        except Revert:
            ok = 0
        (ok_by_kind if ok else bad_by_kind)[kind] += 1
        for key, x in zip(ops, (OPS.index(kind), who, a, b, ok)):
            ops[key].append(x)
        ledger.extend(snapshot())
        return ok

    def deposit(i, liq):
        def fn():
            require(liq > 0, "zero")                       # the vault refuses zero liquidity
            v.deposit(NAMES[i], liq)
        return record("deposit", fn, i, liq)

    def withdraw(i, liq):
        def fn():
            require(liq > 0, "zero")
            v.withdraw(NAMES[i], liq)
        return record("withdraw", fn, i, liq)

    def fees(f0, f1):
        return record("fees", lambda: v.collect_fees(f0, f1), a=f0, b=f1)

    def incentive(a):
        def fn():
            require(a > 0, "zero")
            v.notify_incentive(a)
        return record("incentive", fn, a=a)

    def claim(i, k=ALL):
        def fn():
            if k == ALL:
                out = v.claim(NAMES[i])
            else:
                out = [0, 0, 0]
                out[k] = v.claim(NAMES[i], k)                  # V7: one token alone
            for j in range(3):
                claimed[NAMES[i]][j] += out[j]
        return record("claim", fn, i, b=k)

    def warp(dt):
        return record("warp", lambda: clock.warp(dt), a=dt)

    def to_boundary():
        warp(v.stream._epoch_end(clock.now) - clock.now)

    # --- scripted stretches ----------------------------------------------------------------------------------------
    fees(1_000, 7 * 10**6)                                         # nobody holds shares: carried forward
    incentive(700 * E)
    to_boundary()
    warp(W)                                                        # the incentive streams to nobody: idle
    st["unassigned_rolled"] += 1
    st["idle_streamed"] += 1
    deposit(0, 10**12)
    fees(3 * 10**6, 5 * 10**18)                                    # l0 receives these and the carried ones
    deposit(1, 3 * 10**12)                                         # a just-in-time entrant after the fees ...
    before = list(v.pending(NAMES[0]))
    claim(0, 1)                                                    # one token: the other two stay owed, to the wei
    st["one_token_left_the_others"] += list(v.pending(NAMES[0])) == [before[0], 0, before[2]] and before[1] > 0
    claim(1)
    st["jit_entrant_got_no_old_fees"] += claimed["l1"][0] == 0 and claimed["l1"][1] == 0
    withdraw(0, 10**12 + 1)                                        # above the holder's shares: refused
    warp(2 * W)
    withdraw(0, 10**12)                                            # l0 leaves ...
    warp(DAY)
    claim(0)                                                       # ... and claims what it earned before leaving

    # --- random operations -----------------------------------------------------------------------------------------
    while len(ops["kind"]) < STEPS:
        r = rng.random()
        i = rng.randrange(N)
        if r < 0.2:
            deposit(i, rng.choice([1, rng.randint(1, 10**6), rng.randint(10**9, 10**15)]))
        elif r < 0.32:
            have = v.shares[NAMES[i]]
            withdraw(i, rng.choice([have, rng.randint(1, max(have, 1)), have + 1]))
        elif r < 0.52:
            fees(rng.choice([0, rng.randint(1, 10**6), rng.randint(1, 10**4) * 10**6]),
                 rng.choice([0, rng.randint(1, 10**12), rng.randint(1, 10**4) * E]))
        elif r < 0.6:
            incentive(rng.choice([1, rng.randint(1, 10**9), rng.randint(1, 5_000) * E]))
        elif r < 0.75:
            claim(i, rng.choice([0, 1, 2, ALL, ALL]))
        else:
            k = rng.random()
            if k < 0.15:
                to_boundary()
            elif k < 0.25:
                warp(rng.randint(2, 5) * W + rng.randint(0, DAY))
            else:
                warp(rng.choice([1, rng.randint(1, 3_600), rng.randint(1, 3 * DAY)]))
    for i in range(N):
        warp(1)
        claim(i)
    assert len(ledger) == len(ops["kind"]) * LEDGER_LEN
    assert st["jit_entrant_got_no_old_fees"] == 1 and st["one_token_left_the_others"] == 1, st
    assert min(ok_by_kind.values()) > 0 and bad_by_kind["withdraw"] > 0, (ok_by_kind, bad_by_kind)
    trace = {"ops": {k: [str(x) for x in vals] for k, vals in ops.items()}, "ledger": [str(x) for x in ledger],
             "ledgerLen": str(LEDGER_LEN), "config": {"holders": str(N), "start": str(START)}}
    st.update(steps=len(ops["kind"]), ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()), ok_by_kind=ok_by_kind)
    return trace, st
