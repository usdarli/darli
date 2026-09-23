"""
A redemption trace across three branches from the reference model, for CollateralRegistry.trace.t.sol to replay (SPEC R1,
R3, R5).

One system, three branches with their own collateral, feed and Stability Pool, one frontend registry and one redemption
router. Troves are opened, pools filled and emptied, prices moved and statuses changed per branch, time passes and users
redeem. Scripted episodes make sure routing meets each of its cases, whatever the seed: a branch whose pool covers its
whole debt (weight zero while the others have some), a request above the total uncovered debt (truncated), every
redeemable branch covered while an excluded branch carries the debt (weights by debt), a branch with a price that is not
Valid and a branch under SCR (both excluded), and a shut-down branch. Each step records the operation, whether the model
accepted it, and afterwards the router's state, each branch's ledger and queue head, and every balance; every
CHECK_EVERY steps and at the end, every Trove of every branch.

Imported by export_vectors.py; `build(rng)` returns the JSON-ready trace and the statistics recorded as figures.
"""
from model import (Clock, Token, Feed, Revert, atomic, System, WAD, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED,
                   ACTIVE, ZOMBIE, MIN_SP_RESIDUAL)

E, PCT, DAY = WAD, WAD // 100, 86_400
N_USERS, N_BRANCHES = 4, 3
STEPS, CHECK_EVERY = 400, 20
START = 1_700_000_000
PRICES0 = [2000 * E, 3000 * E, 1500 * E]
FUNDING = 1_000 * E                      # collateral of each branch minted to each user at the start
OPS = ["open", "sp_dep", "sp_wd", "price", "status", "warp", "redeem", "give", "trigger"]
STATUS = {VALID: 0, NETWORK_UNSTABLE: 1, PRICE_INVALID: 2, FAILED: 3}
TROVE_STATUS = {ACTIVE: 1, ZOMBIE: 2}
SYSTEM = dict(beta=4, initial_base_rate=10 * PCT)   # as in branch_trace.py
CONFIG = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E,
              debt_cap=10_000_000 * E, cap_ceiling=10_000_000 * E, gas_deposit=E // 1000)
NAMES = [f"u{i}" for i in range(N_USERS)]
# scripted episodes: (first step, kind); each is a short run of ordinary operations
EPISODES = {}
for s0, kind in ((60, "cover"), (110, "truncate"), (160, "by_debt"), (210, "invalid"), (250, "below_scr"),
                 (290, "cover"), (330, "truncate"), (360, "shutdown")):
    EPISODES[s0] = kind
BRANCH_LEN, USER_LEN = 8, 1 + N_BRANCHES
LEDGER_LEN = 3 + BRANCH_LEN * N_BRANCHES + USER_LEN * N_USERS
TROVE_LEN = 6


def ledger_vector(s, branches, tokens):
    v = [s.base_rate, s.last_fee_op, s.stable.supply]
    for b, tok in zip(branches, tokens):
        order = b.redemption_order()
        v += [b.agg_debt, b.agg_w, b.active_coll, b.sp.total, b.last_zombie, b.n_open, b.shutdown_at,
              order[0].id if order else 0]
    for name in NAMES:
        v += [s.stable.bal[name]] + [tok.bal[name] for tok in tokens]
    return v


def trove_vector(bi, b, tid):
    t = b.troves[tid]
    status = TROVE_STATUS.get(t.status, 3)                  # any closed status: 3
    return [bi, tid, t.coll, t.debt, t.rate, status]


def build(rng):
    clock = Clock()
    assert clock.now == START
    s = System(clock, **SYSTEM)
    tokens = [Token(f"C{i}") for i in range(N_BRANCHES)]
    feeds = [Feed(p) for p in PRICES0]
    branches = [s.create_branch(f"B{i}", tokens[i], feeds[i], **CONFIG) for i in range(N_BRANCHES)]
    for tok in tokens:
        for u in NAMES:
            tok.mint(u, FUNDING)

    ops = {k: [] for k in ("kind", "br", "caller", "a", "b", "c", "d", "ok")}
    ledger, troves, troves_len = [], [], []
    ok_by_kind = {k: 0 for k in OPS}
    bad_by_kind = {k: 0 for k in OPS}
    route = dict(truncated=0, by_debt=0, zero_weight=0, excluded_invalid=0, excluded_below_scr=0, excluded_shutdown=0,
                 several_branches=0)
    fn = stale = None
    script = []                                              # the operations of the running episode, in order

    def amt(lo, hi):
        return rng.randint(lo, hi) * E + rng.randint(0, 10**12)

    def richest():
        return max(range(N_USERS), key=lambda i: s.stable.bal[NAMES[i]])

    def redeemable(b):
        if b.shutdown_at or b.feed.status != VALID:
            return False
        return b.tcr(b.feed.price) >= b.scr

    def unbacked(b):
        return max(b.agg_debt - max(b.sp.total - MIN_SP_RESIDUAL, 0), 0)

    for step in range(STEPS):
        episode = EPISODES.get(step)
        if episode == "cover":
            # one branch's pool covers its whole debt: redeemable, weight zero, while the others still have weight
            script = [("valid_all",), ("give_to", 0), ("sp_cover", 0, 0), ("redeem_some",)]
        elif episode == "truncate":
            # a request above the total uncovered debt of the redeemable branches is truncated to it. With every branch
            # redeemable that cannot happen to a request the redeemer can pay for (SPEC 10.5): the uncovered debt is the
            # supply outside the pools, the redeemer's balance included. So branch 2 carries debt and is excluded, and
            # the pools of the other two are filled to leave a little uncovered
            script = [("valid_all",), ("open_big", 2)] + [("give_to", 1)] * 3 + \
                     [("sp_part", 1, 0), ("sp_part", 1, 1), ("set_status", 2, PRICE_INVALID), ("redeem_over",),
                      ("set_status", 2, VALID)]
        elif episode == "by_debt":
            # branch 2 carries the debt and is excluded (price not Valid); the other two are covered in full, so no
            # redeemable branch has any uncovered debt and the split goes by debt
            script = [("valid_all",), ("open_big", 2)] + [("give_to", 2)] * 3 + \
                     [("sp_cover", 2, 0), ("sp_cover", 2, 1), ("set_status", 2, PRICE_INVALID), ("redeem_some",),
                      ("set_status", 2, VALID)]
        elif episode == "invalid":
            script = [("valid_all",), ("set_status", 1, NETWORK_UNSTABLE), ("redeem_some",), ("set_status", 1, VALID)]
        elif episode == "below_scr":
            script = [("valid_all",), ("crash", 1), ("redeem_some",), ("restore", 1)]
        elif episode == "shutdown":
            script = [("valid_all",), ("set_status", 0, FAILED), ("trigger", 0), ("set_status", 0, VALID),
                      ("redeem_some",)]
        step_script = script.pop(0) if script else None

        kind = rng.choice(["open"] * 6 + ["sp_dep"] * 3 + ["sp_wd"] * 2 + ["price"] * 3 + ["status"] * 2 +
                          ["warp"] * 4 + ["redeem"] * 6 + ["give"] * 3)
        bi = rng.randrange(N_BRANCHES)
        caller, a, bb, c, d = rng.randrange(N_USERS), 0, 0, 0, 0
        b, feed = branches[bi], feeds[bi]
        if step < 30 and not step_script:
            kind = "open"                                     # a populated system first
        if step_script:
            what = step_script[0]
            if what == "valid_all":
                bi = next((i for i, f in enumerate(feeds) if f.status != VALID and not branches[i].shutdown_at), 0)
                kind, a = "status", STATUS[VALID]
            elif what == "set_status":
                bi, kind, a = step_script[1], "status", STATUS[step_script[2]]
            elif what == "trigger":
                bi, kind = step_script[1], "trigger"
            elif what == "give_to":
                # the second-richest user hands its balance to the richest
                order = sorted(range(N_USERS), key=lambda i: s.stable.bal[NAMES[i]])
                kind, caller, a, bb = "give", order[-2], order[-1], s.stable.bal[NAMES[order[-2]]]
            elif what in ("sp_cover", "sp_part"):
                bi = step_script[2]
                kind, caller = "sp_dep", richest()
                if what == "sp_cover":
                    target, reserve = branches[bi].agg_debt + MIN_SP_RESIDUAL + 1_000 * E, 0
                else:
                    # leave a little of the debt uncovered, and the depositor enough to ask for more than all of it
                    target, reserve = branches[bi].agg_debt + MIN_SP_RESIDUAL - amt(500, 3_000), 15_000 * E
                a = max(1, min(target - branches[bi].sp.total, s.stable.bal[NAMES[caller]] - reserve))
            elif what == "open_big":
                bi, kind, caller = step_script[1], "open", richest()
                bb = amt(150_000, 250_000)
                a = min(bb * 3 * E // feeds[bi].price, tokens[bi].bal[NAMES[caller]] - E)
                c = 20 * PCT
            elif what == "crash":
                # branch 1 below SCR (above zero), without a shutdown: nobody triggers one inside the episode
                bi, kind = 1, "price"
                debt = branches[1].agg_debt + branches[1].pending_agg_interest()
                coll = branches[1].active_coll + branches[1].default_coll
                a = max(1, rng.randint(90, 105) * PCT * debt // max(coll, 1))
            elif what == "restore":
                bi, kind, a = 1, "price", PRICES0[1]
            elif what == "redeem_some":
                kind, caller = "redeem", richest()
                a = rng.randint(1, max(s.stable.bal[NAMES[caller]] // 2, 1))
                bb, c = rng.randint(1, 6), WAD
            elif what == "redeem_over":
                kind, caller = "redeem", richest()
                live = [x for x in branches if redeemable(x)]
                total = sum(unbacked(x) for x in live)
                a = min(total + amt(1, 5_000), s.stable.bal[NAMES[caller]])
                bb, c = 50, WAD
        b, feed = branches[bi], feeds[bi]

        if kind == "open":
            if not step_script:
                bb = amt(2_500, 40_000)
                a = bb * rng.randint(130, 400) // 100 * E // feed.price
                c = rng.choice([PCT // 2, 1 * PCT, 2 * PCT, 4 * PCT, rng.randint(PCT // 2, 30 * PCT)])
            coll, debt, rate, u = a, bb, c, caller
            fn = lambda: b.open_trove(NAMES[u], coll, debt, rate)
        elif kind == "sp_dep":
            if not step_script:
                a = amt(1, 20_000)
            fn = lambda: b.sp.deposit(NAMES[caller], a)
        elif kind == "sp_wd":
            a = amt(1, 20_000)
            fn = lambda: b.sp.withdraw(NAMES[caller], a)
        elif kind == "price":
            if not step_script:
                a = PRICES0[bi] * rng.randint(70, 130) // 100
            fn = lambda: setattr(feed, "price", a)
        elif kind == "status":
            if not step_script:
                a = rng.choice([0, 0, 0, 1, 2])
            st = {v: k for k, v in STATUS.items()}[a]
            fn = lambda: setattr(feed, "status", st)
        elif kind == "warp":
            a = rng.choice([rng.randint(1, 59), rng.randint(60, 3_600), rng.randint(1, 3 * DAY)])
            fn = lambda: clock.warp(a)
        elif kind == "redeem":
            if not step_script:
                bal = s.stable.bal[NAMES[caller]]
                a = rng.randint(1, max(bal, 1)) if rng.random() < 0.95 else bal + 1
                bb = rng.randint(1, 8)
                c = WAD if rng.random() < 0.9 else s.fee_floor
            fn = lambda: s.redeem(NAMES[caller], a, max_iter=bb, max_fee_rate=c)
        elif kind == "give":
            if not step_script:
                a, bb = rng.randrange(N_USERS), amt(1, 20_000)
            fn = lambda: s.stable.transfer(NAMES[caller], NAMES[a], bb)
        elif kind == "trigger":
            fn = b.trigger_shutdown
        assert fn is not stale, f"step {step} ({kind}) did not build its own operation"
        stale = fn

        # what the routing will meet, from the state before the operation
        live = [x for x in branches if redeemable(x)]
        weights = [unbacked(x) for x in live]
        try:
            atomic(s, fn)
            ok = 1
        except Revert:
            ok = 0
        (ok_by_kind if ok else bad_by_kind)[kind] += 1
        if ok and kind == "redeem" and live:
            route["truncated"] += sum(weights) > 0 and a > sum(weights)
            route["by_debt"] += sum(weights) == 0
            route["zero_weight"] += sum(weights) > 0 and 0 in weights
            route["several_branches"] += sum(w > 0 for w in weights) >= 2
            for x in branches:
                if x not in live:
                    route["excluded_shutdown" if x.shutdown_at else
                          "excluded_invalid" if x.feed.status != VALID else "excluded_below_scr"] += 1
        for key, v in zip(ops, (OPS.index(kind), bi, caller, a, bb, c, d, ok)):
            ops[key].append(v)
        ledger += ledger_vector(s, branches, tokens)
        full = step % CHECK_EVERY == CHECK_EVERY - 1 or step == STEPS - 1
        n = 0
        if full:
            for i, x in enumerate(branches):
                for tid in sorted(x.troves):
                    troves += trove_vector(i, x, tid)
                    n += 1
        troves_len.append(n)

    assert len(ledger) == STEPS * LEDGER_LEN
    assert route["truncated"] >= 2 and route["by_debt"] >= 1 and route["zero_weight"] >= 2, route
    assert route["excluded_invalid"] >= 1 and route["excluded_below_scr"] >= 1 and route["excluded_shutdown"] >= 1, route
    assert route["several_branches"] >= 10 and ok_by_kind["redeem"] >= 20, (route, ok_by_kind)
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()}, "ledger": [str(x) for x in ledger],
             "ledgerLen": str(LEDGER_LEN), "troves": [str(x) for x in troves],
             "trovesLen": [str(x) for x in troves_len],
             "config": {"users": str(N_USERS), "funding": str(FUNDING), "start": str(START),
                        "prices": [str(p) for p in PRICES0]}}
    stats = dict(steps=STEPS, ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()), ok_by_kind=ok_by_kind,
                 bad_by_kind=bad_by_kind, routing=route)
    return trace, stats
