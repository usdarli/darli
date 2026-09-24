"""
A staking trace from the reference model, for DarliStaking.trace.t.sol to replay (SPEC V3-V5).

The model's StreamingStaking is driven through stakes, unstakes and claims by four stakers, revenue arriving in the
interest escrow and routed to the stakers (route_revenue), and time: seconds, hours, days, a warp to exactly the next
epoch boundary, several epochs at once. Scripted stretches make every seed meet what the fixed epochs are for: a week in
which nobody is staked (what streams then rolls into the next epoch), one-wei hand-overs every hour on top of a large one,
a staker who unstakes and claims later, and a stream that runs dry. Each step records the operation, whether the model
accepted it, and afterwards the stream, the stakers' accounts and every reward balance.

Imported by export_vectors.py; `build(rng)` returns the JSON-ready trace and the statistics recorded as figures.
"""
from model import Clock, Token, Revert, StreamingStaking, WAD, DAY, require, atomic

E = WAD
N = 4
NAMES = [f"k{i}" for i in range(N)]
ESCROW = "InterestEscrow"
OPS = ["stake", "unstake", "claim", "revenue", "route", "warp"]
DARLI_EACH = 1_000_000 * E
STEPS = 400
START = 1_700_000_000
LEDGER_LEN = 11 + 5 * N


def ledger_vector(stk, tok, darli_left):
    st = stk.stream
    v = [st.t0, st.last, st.rate, st.queued, st.idle, stk.total, stk.rpt, tok.bal[stk.addr], tok.bal[ESCROW],
         tok.supply, stk.stream._epoch_end(st.last)]
    for n in NAMES:
        v += [stk.stake_of[n], stk.paid[n], stk.earned[n], tok.bal[n], darli_left[n]]
    return v


def build(rng):
    clock = Clock()
    assert clock.now == START
    tok = Token("uUSD")
    stk = StreamingStaking(clock, tok)
    W = stk.PERIOD
    darli_left = {n: DARLI_EACH for n in NAMES}          # DARLI each staker still holds (the model does not move it)
    ops = {k: [] for k in ("kind", "who", "a", "ok")}
    ledger = []
    ok_by_kind = {k: 0 for k in OPS}
    bad_by_kind = {k: 0 for k in OPS}
    stats = dict(idle_epochs=0, exact_boundaries=0, multi_epoch_warps=0, one_wei_routes=0, claims_after_exit=0)

    def record(kind, fn, who=0, a=0):
        try:
            atomic(stk, fn)                          # a refusal leaves no trace, as on-chain
            ok = 1
        except Revert:
            ok = 0
        (ok_by_kind if ok else bad_by_kind)[kind] += 1
        for key, v in zip(ops, (OPS.index(kind), who, a, ok)):
            ops[key].append(v)
        ledger.extend(ledger_vector(stk, tok, darli_left))

    def stake(i, a):
        def fn():
            require(0 < a <= darli_left[NAMES[i]], "stake: amount")     # the contract pulls DARLI and refuses zero
            stk.stake(NAMES[i], a)
            darli_left[NAMES[i]] -= a
        record("stake", fn, i, a)

    def unstake(i, a):
        def fn():
            require(a > 0, "unstake: zero")
            stk.unstake(NAMES[i], a)
            darli_left[NAMES[i]] += a
        record("unstake", fn, i, a)

    def claim(i):
        record("claim", lambda: stk.claim(NAMES[i]), i)

    def revenue(a):
        record("revenue", lambda: tok.mint(ESCROW, a), a=a)

    def route():
        def fn():
            amount = tok.bal[ESCROW]
            if amount:
                stk.notify_reward(ESCROW, amount)
        record("route", fn)

    def warp(dt):
        record("warp", lambda: clock.warp(dt), a=dt)

    def to_boundary():
        dt = stk.stream._epoch_end(clock.now) - clock.now
        warp(dt)
        stats["exact_boundaries"] += 1

    # --- scripted stretches ----------------------------------------------------------------------------------------
    stake(0, 1_000 * E)
    revenue(7_000 * E); route()
    for _ in range(30):                                            # one wei every hour on top of a large hand-over
        warp(3_600); revenue(1); route(); stats["one_wei_routes"] += 1
    to_boundary()
    stake(1, 3_000 * E)
    warp(2 * DAY)
    unstake(0, stk.stake_of["k0"])                                 # k0 leaves ...
    unstake(1, stk.stake_of["k1"])                                 # ... and so does k1: nobody is staked
    revenue(5_000 * E); route()
    to_boundary()
    warp(W)                                                        # a whole epoch streams into `idle`
    stats["idle_epochs"] += 1
    stake(2, 500 * E)
    warp(3 * W + 11)                                               # the idle amount is paid out an epoch later
    stats["multi_epoch_warps"] += 1
    claim(0); stats["claims_after_exit"] += 1                      # what k0 earned before leaving is still his
    claim(2)

    # --- random operations -----------------------------------------------------------------------------------------
    while len(ops["kind"]) < STEPS:
        r = rng.random()
        i = rng.randrange(N)
        if r < 0.2:
            stake(i, rng.choice([rng.randint(1, 10**6), rng.randint(1, 50_000) * E + rng.randint(0, 10**12)]))
        elif r < 0.32:
            have = stk.stake_of[NAMES[i]]
            a = rng.choice([have, rng.randint(1, max(have, 1)), have + 1])   # all, part, or one wei too many
            unstake(i, a)
        elif r < 0.47:
            claim(i)
        elif r < 0.6:
            revenue(rng.choice([1, rng.randint(1, 10**9), rng.randint(1, 20_000) * E + rng.randint(0, 10**12)]))
        elif r < 0.72:
            route()
        else:
            k = rng.random()
            if k < 0.15:
                to_boundary()
            elif k < 0.25:
                warp(rng.randint(2, 6) * W + rng.randint(0, DAY))
                stats["multi_epoch_warps"] += 1
            else:
                warp(rng.choice([1, rng.randint(1, 3_600), rng.randint(1, 3 * DAY)]))
    for i in range(N):                                             # everybody collects at the end
        warp(1)
        claim(i)
    assert len(ledger) == len(ops["kind"]) * LEDGER_LEN
    assert min(ok_by_kind.values()) > 0 and bad_by_kind["unstake"] > 0, (ok_by_kind, bad_by_kind)
    assert stats["exact_boundaries"] >= 5 and stats["multi_epoch_warps"] >= 3, stats
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()}, "ledger": [str(x) for x in ledger],
             "ledgerLen": str(LEDGER_LEN), "config": {"stakers": str(N), "darli": str(DARLI_EACH), "start": str(START)}}
    stats.update(steps=len(ops["kind"]), ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()),
                 ok_by_kind=ok_by_kind, routed=tok.supply)
    return trace, stats
