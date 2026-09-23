"""
A branch trace from the reference model, for BranchManager.trace.t.sol to replay (SPEC 4, 6, 8).

The model's branch is driven through a random sequence of borrower operations -- open, borrow, repay, add and withdraw
collateral, the combined adjustment, rate changes, close, applying pending debt, NFT transfers -- and of liquidations,
together with time, price and oracle-status changes, Stability Pool deposits, withdrawals and claims, surplus claims,
frontend claims, stablecoin transfers between users and, in the last part only, the shutdown triggers. Guided price moves
put a Trove just below MCR (so liquidations happen, some offset against the pool, some redistributed, some both) and put
the branch below CCR (so recovery mode is tried). Each step records the operation, whether the
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
EPISODES = {s + i: e for s in (150, 250, 350, 450, 550) for i, e in enumerate(("valid", "fund", "aim", "liq"))}
# scripted dust repayments (B4): an owner who can pay tries to leave its Trove just under the minimum debt
EPISODES.update({s: "dust" for s in (200, 300, 400, 500)})
START = 1_700_000_000                    # the model's clock; the replay warps to it before deploying

# encodings shared with the Solidity replay
OPS = ["open", "borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer", "warp", "price",
       "status", "sp_dep", "sp_wd", "give", "fe_claim", "trigger", "poke", "liquidate", "sp_claim", "surplus"]
STATUS = {VALID: 0, NETWORK_UNSTABLE: 1, PRICE_INVALID: 2, FAILED: 3}
TROVE_STATUS = {ACTIVE: 1, ZOMBIE: 2, CLOSED_OWNER: 3, CLOSED_LIQ: 4, CLOSED_SETTLED: 5}
# accounts by index: the users, then the two frontend payouts
NAMES = [f"u{i}" for i in range(N_USERS)] + ["fe1", "fe2"]

CONFIG = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E,
              debt_cap=400_000 * E, cap_ceiling=1_600_000 * E, gas_deposit=E // 1000)
FUNDING = 1_000 * E                      # collateral minted to each user at the start
PRICE0 = 2000 * E


def ledger_vector(s, b, weth):
    fe, sp = s.frontends, b.sp
    v = [b.agg_debt, b.agg_w, b.last_agg_update, b.bad_debt, b.shutdown_at, int(b.oracle_failed), b.active_coll,
         b.default_coll, b.gas_pool, b.n_open, b.total_stakes, b.settle_price or 0, b.unsettled, s.stable.supply,
         s.stable.bal[s.ESCROW], s.stable.bal[fe.ADDR], s.stable.bal[sp.addr], weth.bal[b.vault], b.vault_accounted,
         fe.total_deposited, fe.total_credited, sp.total, b.feed.last_good,
         b.L_coll, b.L_debt, b.err_lc, b.err_ld, b.stakes_snap, b.coll_snap, b.bad_debt_coll,
         sp.P, sp.scale, sp.err_coll, sp.err_yield, sp.S[sp.scale], sp.B[sp.scale], weth.bal[sp.addr]]
    for name in NAMES:
        v += [s.stable.bal[name], weth.bal[name], fe.claimable[name], b.surplus[name], sp.compounded(name),
              sp.pending_coll(name), sp.pending_yield(name), sp.claim_coll[name], sp.claim_yield[name]]
    return v


LEDGER_BASE, PER_ACCOUNT = 37, 9


def trove_vector(b, tid):
    t = b.troves.get(tid)
    if t is None:
        return [tid] + [0] * (TROVE_LEN - 1)
    owner = NAMES.index(t.owner) + 1 if t.status in (ACTIVE, ZOMBIE) else 0
    return [tid, t.coll, t.debt, t.rate, t.stake, t.last_debt_update, t.last_rate_adjust, TROVE_STATUS[t.status],
            b.gas_left.get(tid, 0), owner, t.snap_lc, t.snap_ld]


TROVE_LEN = 12



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
    liq = dict(offset=0, redistributed=0, both=0, bad_debt=0, with_surplus=0)
    aimed = 0                                                        # the Trove the last guided price was aimed at
    episode_target = None
    dust_refused = 0
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
                ["status"] * 2 + ["sp_dep"] * 4 + ["sp_wd"] * 2 + ["give"] * 5 + ["fe_claim"] * 2 + \
                ["liquidate"] * 5 + ["sp_claim"] * 2 + ["surplus"] * 2
        if step >= SHUTDOWN_FROM:
            kinds += ["trigger"] * 3 + ["poke"] * 2
        k = rng.choice(kinds)
        # scripted episodes, at fixed steps: fund the pool, aim a price at the smallest Trove, liquidate it. They are
        # ordinary operations; they make sure liquidations that leave the owner a surplus happen, whatever the seed
        episode = EPISODES.get(step)
        if episode == "valid":
            # the target: the smallest Trove whose 107 % price keeps the branch at or above 112 %, so aiming at it
            # neither shuts the branch down nor is refused
            debt_total, coll_total = b.agg_debt + b.pending_agg_interest(), b.active_coll + b.default_coll
            fits = [t for t in live if b.debt_now(t) and coll_total * (107 * PCT * b.debt_now(t) // b.coll_now(t))
                    // max(debt_total, 1) >= 112 * PCT]
            # ... and, among those, one the pool can be funded to absorb in full: the richest user's balance plus what
            # the pool already holds above its residual
            richest = max(s.stable.bal[NAMES[i]] for i in range(N_USERS))
            coverable = [t for t in fits if b.debt_now(t) + 1_000 * E <= b.sp.total - 10**18 + richest]
            episode_target = min(coverable or fits, key=lambda t: b.debt_now(t), default=None)
        smallest = episode_target if episode else None
        if episode:
            k = {"valid": "status", "fund": "sp_dep", "aim": "price", "liq": "liquidate", "dust": "repay"}[episode]
        elif live and feed.status == VALID and b.tcr(feed.price) < b.ccr and rng.random() < 0.4:
            k = "adjust"                                     # below CCR: recovery mode is what needs exercising
        elif feed.status == VALID and b.shutdown_at == 0 and rng.random() < 0.5 and \
                any(b.debt_now(t) and b.icr(t, feed.price) < b.mcr for t in live):
            k = "liquidate"                                  # a Trove is below MCR: liquidation is what needs exercising
        if step == STEPS - 30:
            k = "fail"                                       # the oracle fails for good ...
        elif step == STEPS - 29:
            k = "poke"                                       # ... and the branch observes it: the rest runs shut down
        if k in ("borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer", "liquidate") and not every:
            k = "open"
        caller, a, bb, c, d, touched = 0, 0, 0, 0, 0, 0
        dust_try = False
        target = None
        result = {}
        if k == "liquidate":
            # mostly a Trove that is below MCR now; otherwise any Trove, which must be refused
            under = [t for t in live if b.debt_now(t) and b.icr(t, feed.price) < b.mcr]
            if under and rng.random() < 0.85:
                aimed_now = [t for t in under if t.id == aimed]
                target = aimed_now[0] if aimed_now else rng.choice(under)
            else:
                target = rng.choice(every)
            touched, caller = target.id, rng.randrange(N_USERS)
            fn = lambda: result.update(b.liquidate(target.id, NAMES[caller]))
        elif k in ("borrow", "repay", "add", "withdraw", "adjust", "rate", "close", "apply", "transfer"):
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
        if k == "liquidate":
            pass
        elif k == "open":
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
        elif k == "repay" and episode == "dust":
            payers = [t for t in live if b.debt_now(t) > b.min_debt
                      and s.stable.bal[t.owner] >= b.debt_now(t) - b.min_debt + 10**6]
            if payers:
                target = rng.choice(payers)
                touched, caller = target.id, NAMES.index(target.owner)
                a = b.debt_now(target) - b.min_debt + rng.randint(1, 10**6)   # leaves 1 .. 1e6 wei under the minimum
                dust_try = True
            else:
                a = amt(1, 30_000)                                             # nobody can pay: an ordinary repayment
            fn = lambda: b.repay(target.id, a)
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
            weakest = min(live, key=lambda t: b.coll_now(t) * WAD // max(b.debt_now(t), 1), default=None)
            a = 0
            if episode == "aim" and smallest is not None:
                # scripted: the smallest Trove at an ICR of 107 %, between the pool's premium and MCR (L3 surplus)
                p = 107 * PCT * b.debt_now(smallest) // b.coll_now(smallest)
                if coll_total * p // debt_total >= 112 * PCT:
                    a, aimed = p, smallest.id
            elif weakest is not None and b.debt_now(weakest) and len(live) >= 2 and rng.random() < 0.5:
                # guided: the weakest Trove just below MCR (sometimes under water), if the branch stays above SCR and
                # another Trove is there to take a redistribution (a lone Trove would become bad debt and end the trace).
                # The band between the pool's premium and MCR leaves the owner a surplus (L3), but only when the pool can
                # absorb the whole debt, so it is aimed at only then
                pool_absorbs = b.sp.total - 10**18 >= b.debt_now(weakest)
                target = rng.randint(106, 109) if pool_absorbs and rng.random() < 0.7 else rng.randint(95, 105)
                aimed = weakest.id                                   # liquidated first, while it is below MCR
                p = target * PCT * b.debt_now(weakest) // b.coll_now(weakest)
                if coll_total * p // debt_total >= 112 * PCT:
                    a = p
            if a:
                pass
            elif rng.random() < 0.35 and debt_total and coll_total:
                # guided: put the branch below CCR but above SCR, where the recovery-mode rules of B8 apply
                a = rng.randint(115, 148) * PCT * debt_total // coll_total
            else:
                a = rng.randint(1_150, 2_600) * E
            fn = lambda: setattr(feed, "price", a)
        elif k == "fail":
            k, a = "status", STATUS[FAILED]
            fn = lambda: setattr(feed, "status", FAILED)
        elif k == "status" and episode == "valid":
            a = STATUS[VALID]
            fn = lambda: setattr(feed, "status", VALID)
        elif k == "status":
            choices = [VALID] * 4 + [PRICE_INVALID, NETWORK_UNSTABLE] + ([FAILED] if step >= SHUTDOWN_FROM else [])
            st = rng.choice(choices)
            a = STATUS[st]
            fn = lambda: setattr(feed, "status", st)
        elif k == "sp_dep":
            caller = rng.randrange(N_USERS)
            a = amt(1, 60_000)
            if episode == "fund":
                # scripted: the richest user funds the pool to cover the smallest Trove, if it can
                caller = max(range(N_USERS), key=lambda i: s.stable.bal[NAMES[i]])
                need = b.debt_now(smallest) - (b.sp.total - 10**18) + 1_000 * E if smallest else 0
                a = max(1, min(s.stable.bal[NAMES[caller]], need))
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
        elif k == "sp_claim":
            caller = rng.randrange(N_USERS)
            fn = lambda: b.sp.claim(NAMES[caller])
        elif k == "surplus":
            caller = rng.randrange(N_USERS)
            fn = lambda: b.claim_surplus(NAMES[caller])
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
        dust_refused += dust_try and not ok
        if ok and k == "liquidate":
            liq["offset"] += result["X"] > 0
            liq["redistributed"] += result["Y"] > 0 and not result["bad"]
            liq["both"] += result["X"] > 0 and result["Y"] > 0 and not result["bad"]
            liq["bad_debt"] += result["bad"]
            liq["with_surplus"] += result["surplus"] > 0
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

    ledger_len = LEDGER_BASE + PER_ACCOUNT * len(NAMES)
    assert len(ledger) == STEPS * ledger_len
    assert dust_refused >= 2, f"only {dust_refused} repayments leaving dust were tried and refused (B4)"
    assert liq["offset"] >= 5 and liq["redistributed"] >= 5 and liq["both"] >= 1 and liq["with_surplus"] >= 3, liq
    assert b.shutdown_at, "the trace must end with a shut-down branch"
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()},
             "ledger": [str(x) for x in ledger], "ledgerLen": str(ledger_len), "troveLen": str(TROVE_LEN),
             "troves": [str(x) for x in troves], "trovesLen": [str(x) for x in troves_len],
             "queue": [str(x) for x in queues], "queueLen": [str(x) for x in queue_len],
             "full": [str(x) for x in full_flags],
             "config": {"users": str(N_USERS), "funding": str(FUNDING), "price0": str(PRICE0), "start": str(START)}}
    stats = dict(full_checks=sum(full_flags), steps=STEPS, ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()), ok_by_kind=ok_by_kind,
                 bad_by_kind=bad_by_kind, shutdown=b.shutdown_at != 0, troves=len(b.troves), liquidations=liq)
    return trace, stats
