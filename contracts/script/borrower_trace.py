"""
A borrower trace from the reference model, for BranchManager.t.sol to replay (SPEC 4, 8, 6.5 triggers).

The model's branch is driven through a random sequence of borrower operations -- open, borrow, repay, add and withdraw
collateral, the combined adjustment, rate changes, close, applying pending debt, NFT transfers -- together with time,
price and oracle-status changes, Stability Pool deposits (which decide the split of SPEC V1), frontend claims, stablecoin
transfers between users and, in the last part only, the shutdown triggers. Each step records the operation, whether the
model accepted it, and afterwards the whole aggregate ledger, every balance the branch can move, and the Trove the
operation touched; every CHECK_EVERY steps and at the end, every Trove and the redemption queue as well.

The replay must reproduce every acceptance and every refusal, and every recorded number wei for wei.

Imported by export_vectors.py; `build(rng)` returns the JSON-ready trace and the statistics recorded as figures.
"""
from model import (Clock, Token, Feed, System, Revert, atomic, WAD, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED,
                   ACTIVE, ZOMBIE, CLOSED_OWNER, CLOSED_LIQ, CLOSED_SETTLED)

E, PCT, DAY = WAD, WAD // 100, 86_400
N_USERS = 6
STEPS, SHUTDOWN_FROM = 700, 600          # the shutdown triggers only in the last 100 steps: a shutdown ends borrowing
CHECK_EVERY = 25
START = 1_700_000_000                    # the model's clock; the replay warps to it before deploying

# encodings shared with the Solidity replay
OPS = ["open", "borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer", "warp", "price",
       "status", "sp_dep", "sp_wd", "give", "fe_claim", "trigger", "poke"]
STATUS = {VALID: 0, NETWORK_UNSTABLE: 1, PRICE_INVALID: 2, FAILED: 3}
TROVE_STATUS = {ACTIVE: 1, ZOMBIE: 2, CLOSED_OWNER: 3, CLOSED_LIQ: 4, CLOSED_SETTLED: 5}
# accounts by index: the users, then the two frontend payouts and the payout of untagged Troves
NAMES = [f"u{i}" for i in range(N_USERS)] + ["fe1", "fe2", "IncentiveController"]

CONFIG = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E,
              debt_cap=400_000 * E, cap_ceiling=1_600_000 * E, gas_deposit=E // 1000)
FUNDING = 1_000 * E                      # collateral minted to each user at the start
PRICE0 = 2000 * E


def ledger_vector(s, b, weth):
    fe, sp = s.frontends, b.sp
    v = [b.agg_debt, b.agg_w, b.last_agg_update, b.bad_debt, b.shutdown_at, int(b.oracle_failed), b.active_coll,
         b.default_coll, b.gas_pool, b.n_open, b.total_stakes, b.settle_price or 0, b.unsettled, s.stable.supply,
         s.stable.bal[s.ESCROW], s.stable.bal[fe.ADDR], s.stable.bal[sp.addr], weth.bal[b.vault], b.vault_accounted,
         fe.total_deposited, fe.total_credited, sp.total, b.feed.last_good]
    for name in NAMES:
        v += [s.stable.bal[name], weth.bal[name], fe.claimable[name]]
    return v


def trove_vector(b, tid):
    t = b.troves.get(tid)
    if t is None:
        return [tid] + [0] * 9
    owner = NAMES.index(t.owner) + 1 if t.status in (ACTIVE, ZOMBIE) else 0
    return [tid, t.coll, t.debt, t.rate, t.stake, t.last_debt_update, t.last_rate_adjust, TROVE_STATUS[t.status],
            b.gas_left.get(tid, 0), owner]



def build(rng):
    clock = Clock()
    assert clock.now == START
    s = System(clock)                                       # sp_share 72 %, frontend_share 3 % (SPEC 2)
    weth = Token("WETH")
    feed = Feed(PRICE0)
    b = s.create_branch("WETH", weth, feed, **CONFIG)
    fe = s.frontends
    assert fe.register("fe1", 0) == 1 and fe.register("fe2", 40 * PCT) == 2
    users = NAMES[:N_USERS]
    for u in users:
        weth.mint(u, FUNDING)

    ops = {k: [] for k in ("kind", "caller", "tid", "a", "b", "c", "d", "ok")}
    ledger, troves, troves_len = [], [], []
    queues, queue_len, full_flags = [], [], []
    ok_by_kind = {k: 0 for k in OPS}
    bad_by_kind = {k: 0 for k in OPS}

    def amt(lo, hi):
        return rng.randint(lo, hi) * E + rng.randint(0, 10**12)

    def pick_rate():
        if rng.random() < 0.05:
            return rng.choice([b.min_rate - 1, b.max_rate + 1])          # out of range: refused
        return rng.choice([b.min_rate, 1 * PCT, 3 * PCT, 3 * PCT, 8 * PCT]) if rng.random() < 0.6 else rng.randint(b.min_rate, 40 * PCT)

    for step in range(STEPS):
        live = [t for t in b.troves.values() if t.status in (ACTIVE, ZOMBIE)]
        every = list(b.troves.values())
        kinds = ["open"] * 8 + ["borrow"] * 4 + ["repay"] * 5 + ["add"] * 3 + ["withdraw"] * 3 + ["adjust"] * 8 + \
                ["rate"] * 4 + ["close"] * 3 + ["apply"] * 2 + ["transfer"] * 2 + ["warp"] * 6 + ["price"] * 4 + \
                ["status"] * 2 + ["sp_dep"] * 3 + ["sp_wd"] * 2 + ["give"] * 5 + ["fe_claim"] * 2
        if step >= SHUTDOWN_FROM:
            kinds += ["trigger"] * 3 + ["poke"] * 2
        k = rng.choice(kinds)
        if live and feed.status == VALID and b.tcr(feed.price) < b.ccr and rng.random() < 0.4:
            k = "adjust"                                     # below CCR: recovery mode is what needs exercising
        if step == STEPS - 30:
            k = "fail"                                       # the oracle fails for good ...
        elif step == STEPS - 29:
            k = "poke"                                       # ... and the branch observes it: the rest runs shut down
        if k in ("borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer") and not every:
            k = "open"
        caller, a, bb, c, d, touched = 0, 0, 0, 0, 0, 0
        target = None
        if k in ("borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer"):
            # mostly open Troves; now and then a closed one, which every operation must refuse
            pool = live if live and rng.random() < 0.93 else every
            if k == "transfer":
                pool = live                                  # a closed Trove has no NFT left to transfer
                if not pool:
                    k = "open"
            if pool:
                target = rng.choice(pool)
                touched = target.id
                caller = NAMES.index(target.owner) if target.status in (ACTIVE, ZOMBIE) else rng.randrange(N_USERS)
        if k == "open":
            u = rng.randrange(N_USERS)
            debt = amt(1_000, 60_000)
            coll = debt * rng.randint(105, 400) // 100 * E // max(feed.price, 1)
            rate, fid = pick_rate(), rng.choice([0, 0, 1, 2])
            caller, a, bb, c, d = u, coll, debt, rate, fid
            touched = b.next_id
            fn = lambda: b.open_trove(NAMES[u], coll, debt, rate, frontend=fid)
        elif k == "borrow":
            a = amt(1, 6_000)
            fn = lambda: b.borrow(target.id, a)
        elif k == "repay":
            a = amt(1, 30_000)
            fn = lambda: b.repay(target.id, a)
        elif k == "add":
            a = rng.randint(1, 20 * E)
            fn = lambda: b.add_coll(target.id, a)
        elif k == "withdraw":
            a = rng.randint(1, 3 * E)
            fn = lambda: b.withdraw_coll(target.id, a)
        elif k == "adjust":
            dc = rng.choice([-1, 0, 1]) * rng.randint(1, 8 * E)
            dd = rng.choice([-1, 0, 1]) * amt(1, 15_000)
            if feed.status == VALID and b.tcr(feed.price) < b.ccr and rng.random() < 0.8:
                # below CCR, try exactly what recovery mode rules on (SPEC B8): new debt with a top-up, which is allowed
                # only if TCR ends >= CCR; and collateral out with a repayment worth more, or less, than it
                if rng.random() < 0.5:
                    dd = amt(1, 3_000)
                    dc = dd * rng.randint(100, 400) // 100 * E // feed.price
                else:
                    dd = -amt(200, 3_000)
                    dc = -(-dd * rng.randint(50, 150) // 100 * E // feed.price) - 1
            if dc == 0 and dd == 0:
                dd = amt(1, 5_000)
            a, bb, c = abs(dc), abs(dd), (1 if dc < 0 else 0) + (2 if dd < 0 else 0)
            fn = lambda: b.adjust_trove(target.id, dc, dd)
        elif k == "rate":
            a = pick_rate()
            fn = lambda: b.adjust_rate(target.id, a)
        elif k == "close":
            fn = lambda: b.close_trove(target.id)
        elif k == "apply":
            caller = rng.randrange(N_USERS)                  # permissionless
            fn = lambda: b.apply_pending_debt(target.id)
        elif k == "transfer":
            a = rng.randrange(N_USERS)
            fn = lambda: b.transfer_trove(target.id, NAMES[a])
        elif k == "warp":
            a = rng.choice([rng.randint(1, 3_600), rng.randint(1, 10 * DAY), rng.randint(20 * DAY, 45 * DAY)])
            fn = lambda: clock.warp(a)
        elif k == "price":
            debt_total, coll_total = b.agg_debt + b.pending_agg_interest(), b.active_coll + b.default_coll
            if rng.random() < 0.35 and debt_total and coll_total:
                # guided: put the branch below CCR but above SCR, where the recovery-mode rules of B8 apply
                a = rng.randint(115, 148) * PCT * debt_total // coll_total
            else:
                a = rng.randint(1_150, 2_600) * E
            fn = lambda: setattr(feed, "price", a)
        elif k == "fail":
            k, a = "status", STATUS[FAILED]
            fn = lambda: setattr(feed, "status", FAILED)
        elif k == "status":
            choices = [VALID, VALID, PRICE_INVALID, NETWORK_UNSTABLE] + ([FAILED] if step >= SHUTDOWN_FROM else [])
            st = rng.choice(choices)
            a = STATUS[st]
            fn = lambda: setattr(feed, "status", st)
        elif k == "sp_dep":
            caller = rng.randrange(N_USERS)
            a = amt(1, 20_000)
            fn = lambda: b.sp.deposit(NAMES[caller], a)
        elif k == "sp_wd":
            caller = rng.randrange(N_USERS)
            a = amt(1, 20_000)
            fn = lambda: b.sp.withdraw(NAMES[caller], a)
        elif k == "give":
            caller, a = rng.randrange(N_USERS), rng.randrange(N_USERS)
            bb = amt(1, 20_000)
            fn = lambda: s.stable.transfer(NAMES[caller], NAMES[a], bb)
        elif k == "fe_claim":
            caller = rng.randrange(len(NAMES))
            fn = lambda: fe.claim(NAMES[caller])
        elif k == "trigger":
            fn = b.trigger_shutdown
        else:
            fn = b.poke_oracle
        try:
            atomic(s, fn)
            ok = 1
        except Revert:
            ok = 0
        (ok_by_kind if ok else bad_by_kind)[k] += 1
        for key, v in zip(ops, (OPS.index(k), caller, touched, a, bb, c, d, ok)):
            ops[key].append(v)
        ledger += ledger_vector(s, b, weth)
        # the touched Trove every step (0 = none); every Trove and the queue every CHECK_EVERY steps and at the end
        full = step % CHECK_EVERY == CHECK_EVERY - 1 or step == STEPS - 1
        ids = sorted(b.troves) if full else ([touched] if touched in b.troves else [])
        troves_len.append(len(ids))
        for tid in ids:
            troves += trove_vector(b, tid)
        order = [t.id for t in b.redemption_order()] if full else []
        queue_len.append(len(order))
        full_flags.append(int(full))
        queues += order

    assert len(ledger) == STEPS * (23 + 3 * len(NAMES))
    assert b.shutdown_at, "the trace must end with a shut-down branch"
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()},
             "ledger": [str(x) for x in ledger], "ledgerLen": str(23 + 3 * len(NAMES)),
             "troves": [str(x) for x in troves], "trovesLen": [str(x) for x in troves_len],
             "queue": [str(x) for x in queues], "queueLen": [str(x) for x in queue_len],
             "full": [str(x) for x in full_flags],
             "config": {"users": str(N_USERS), "funding": str(FUNDING), "price0": str(PRICE0), "start": str(START)}}
    stats = dict(full_checks=sum(full_flags), steps=STEPS, ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()), ok_by_kind=ok_by_kind,
                 bad_by_kind=bad_by_kind, shutdown=b.shutdown_at != 0, troves=len(b.troves))
    return trace, stats
