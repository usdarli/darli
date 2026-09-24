"""
Settlement traces from the reference model, for BranchSettlement.trace.t.sol to replay (SPEC 9, X1-X11).

Each trace runs one branch of the model through a short live life -- Troves at many ICRs, a Stability Pool, liquidations
that leave redistribution pending and surplus to their owners, interest -- then shuts it down and settles it. Four variants,
one per path of the settlement that matters:
  failure  the oracle fails; Troves are settled one by one and in batches, some are written off after the delay, one is
           written off and then settled before phase 1 ends (the write-off is undone), the rest are settled late, between
           claims, so their collateral reaches every claim unit alike
  absorb   TCR falls to between 100 % and SCR; under-water Troves' shortfall is absorbed by the healthy owners' surplus
  haircut  TCR falls under 100 %: the surplus is used up and the holders take a haircut
  empty    nobody settles; every Trove is written off, so phase 1 ends with an empty pot; burns register claim units that
           are paid only by the late settlements
Throughout, claims are tried before phase 1 ends (refused), surpluses are claimed early and late, and USDarli changes
hands. Each step records the operation, whether the model accepted it, and afterwards the branch's ledger, the settlement
accounts and every account's balances and claims; the touched Trove every step and every Trove every CHECK_EVERY steps.

Imported by export_vectors.py; `build(rng, variant)` returns the JSON-ready trace and the statistics recorded as figures.
"""
from model import (Clock, Token, Feed, System, Revert, atomic, WAD, L_PRECISION, VALID, FAILED, ACTIVE, ZOMBIE,
                   CLOSED_OWNER, CLOSED_LIQ, CLOSED_SETTLED)

E, PCT, DAY = WAD, WAD // 100, 86_400
N_USERS = 6
NAMES = [f"u{i}" for i in range(N_USERS)] + ["fe1", "fe2"]     # as in branch_trace.py: the same accounts and fixture
OPS = ["open", "sp_dep", "sp_wd", "sp_claim", "liquidate", "price", "status", "poke", "trigger", "warp", "give",
       "settle", "settle_batch", "write_off", "redeem_bad", "repay_bad", "claim_late", "claim_surplus", "claim_liq_surplus"]
TROVE_STATUS = {ACTIVE: 1, ZOMBIE: 2, CLOSED_OWNER: 3, CLOSED_LIQ: 4, CLOSED_SETTLED: 5}
SYSTEM = dict(beta=1, initial_base_rate=10 * PCT)
CONFIG = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E,
              debt_cap=400_000 * E, cap_ceiling=1_600_000 * E, gas_deposit=E // 1000)
FUNDING = 1_000 * E
PRICE0 = 2000 * E
START = 1_700_000_000
CHECK_EVERY = 20
VARIANTS = ("failure", "absorb", "haircut", "empty")
BRANCH_LEN, SETTLE_LEN, PER_ACCOUNT, TROVE_LEN = 18, 11, 8, 8
LEDGER_LEN = BRANCH_LEN + SETTLE_LEN + PER_ACCOUNT * len(NAMES)


def ledger_vector(s, b, weth):
    v = [b.agg_debt, b.agg_w, b.bad_debt, b.bad_debt_coll, b.shutdown_at, int(b.oracle_failed), b.active_coll,
         b.default_coll, b.gas_pool, b.n_open, b.unsettled, b.settle_price or 0, b.total_stakes, s.stable.supply,
         weth.bal[b.vault], b.vault_accounted, b.sp.total, b.last_zombie,
         b.claim_units, b.take, b.late_per_unit, b.late_pool, b.par_total, b.contrib_total, b.settle_surplus_pool,
         b.settle_surplus_gross, b.settle_short_total, b.surplus_keep or 0, int(b.surplus_keep is not None)]
    for n in NAMES:
        v += [s.stable.bal[n], weth.bal[n], b.surplus[n], b.gross_of[n], b.surplus_paid_amt[n], b.units_of[n],
              b.late_paid[n], s.frontends.claimable[n]]
    return v


def trove_vector(b, tid):
    t = b.troves.get(tid)
    if t is None:
        return [tid] + [0] * (TROVE_LEN - 1)
    debt, need = b.written_off.get(tid, (0, 0))
    return [tid, t.coll, t.debt, TROVE_STATUS[t.status], b.gas_left.get(tid, 0), int(tid in b.written_off), debt, need]


def build(rng, variant):
    assert variant in VARIANTS
    clock = Clock()
    assert clock.now == START
    s = System(clock, **SYSTEM)
    weth = Token("WETH")
    feed = Feed(PRICE0)
    b = s.create_branch("WETH", weth, feed, **CONFIG)
    fe = s.frontends
    assert fe.register("fe1", 0) == 1 and fe.register("fe2", 40 * PCT) == 2
    for u in NAMES[:N_USERS]:
        weth.mint(u, FUNDING)

    ops = {k: [] for k in ("kind", "caller", "tid", "a", "b", "c", "d", "ok")}
    batch, batch_len = [], []
    ledger, troves, troves_len = [], [], []
    ok_by_kind = {k: 0 for k in OPS}
    bad_by_kind = {k: 0 for k in OPS}
    st = dict(settled=0, batches=0, write_offs=0, undone=0, late=0, under_water=0, claims=0, claims_refused_phase1=0,
              late_paid=0, surplus_paid=0, empty_pot_claims=0)
    steps = []                                   # the planned operations; built phase by phase from the model's state

    def amt(lo, hi):
        return rng.randint(lo, hi) * E + rng.randint(0, 10**12)

    def richest():
        return max(range(N_USERS), key=lambda i: s.stable.bal[NAMES[i]])

    def open_ids():
        return [t.id for t in b.troves.values() if t.status in (ACTIVE, ZOMBIE)]

    def record(kind, fn, caller=0, tid=0, a=0, bb=0, ids=(), c=0, d=0):
        try:
            atomic(s, fn)
            ok = 1
        except Revert:
            ok = 0
        (ok_by_kind if ok else bad_by_kind)[kind] += 1
        for key, v in zip(ops, (OPS.index(kind), caller, tid, a, bb, c, d, ok)):
            ops[key].append(v)
        batch.extend(ids)
        batch_len.append(len(ids))
        ledger.extend(ledger_vector(s, b, weth))
        n = len(ops["kind"])
        ids_now = sorted(b.troves) if n % CHECK_EVERY == 0 else ([tid] if tid in b.troves else [])
        troves_len.append(len(ids_now))
        for i in ids_now:
            troves.extend(trove_vector(b, i))
        return ok

    # --- a live life -------------------------------------------------------------------------------------------------
    lo_icr = {"failure": 150, "absorb": 115, "haircut": 115, "empty": 150}[variant]
    for i in range(3):                                           # anchors: the branch far above CCR
        u, debt = i, amt(20_000, 40_000)
        coll = debt * 400 // 100 * E // feed.price
        record("open", lambda u=u, c=coll, d=debt: b.open_trove(NAMES[u], c, d, 5 * PCT), u, b.next_id, coll, debt,
               c=5 * PCT)
    for _ in range(26):
        u, debt = rng.randrange(N_USERS), amt(2_500, 30_000)
        coll = debt * rng.randint(lo_icr, 320) // 100 * E // feed.price
        rate, fid = rng.choice([PCT // 2, 1 * PCT, 3 * PCT, rng.randint(PCT // 2, 20 * PCT)]), rng.choice([0, 0, 1, 2])
        tid = b.next_id
        record("open", lambda u=u, c=coll, d=debt, r=rate, f=fid: b.open_trove(NAMES[u], c, d, r, frontend=f),
               u, tid, coll, debt, c=rate, d=fid)
        if rng.random() < 0.3:
            dt = rng.randint(1, 5 * DAY)
            record("warp", lambda dt=dt: clock.warp(dt), a=dt)
    for _ in range(3):
        u = richest()
        a = max(1, s.stable.bal[NAMES[u]] // 3)
        record("sp_dep", lambda u=u, a=a: b.sp.deposit(NAMES[u], a), u, a=a)
    for _ in range(3):                                           # liquidations: pool first, then redistribution
        live = [t for t in b.troves.values() if t.status in (ACTIVE, ZOMBIE) and b.debt_now(t)]
        if len(live) < 4:
            break
        weak = min(live, key=lambda t: b.coll_now(t) * WAD // b.debt_now(t))
        p = rng.randint(104, 108) * PCT * b.debt_now(weak) // b.coll_now(weak)
        debt_total, coll_total = b.agg_debt + b.pending_agg_interest(), b.active_coll + b.default_coll
        if coll_total * p // debt_total < 112 * PCT:
            continue
        record("price", lambda p=p: setattr(feed, "price", p), a=p)
        record("liquidate", lambda t=weak.id: b.liquidate(t, NAMES[0]), 0, weak.id)
        dt = rng.randint(1, 3 * DAY)
        record("warp", lambda dt=dt: clock.warp(dt), a=dt)
    record("price", lambda: setattr(feed, "price", PRICE0), a=PRICE0)
    for _ in range(4):
        u, v = rng.randrange(N_USERS), rng.randrange(N_USERS)
        x = amt(1, 5_000)
        record("give", lambda u=u, v=v, x=x: s.stable.transfer(NAMES[u], NAMES[v], x), u, a=v, bb=x)

    # --- the shutdown --------------------------------------------------------------------------------------------------
    if variant in ("failure", "empty"):
        record("status", lambda: setattr(feed, "status", FAILED), a=3)
        record("poke", b.poke_oracle)
    else:
        debt_total, coll_total = b.agg_debt + b.pending_agg_interest(), b.active_coll + b.default_coll
        # absorb: TCR under SCR but far enough above 100 % that the owners keep part of their surplus
        target = rng.randint(103, 108) if variant == "absorb" else rng.randint(80, 95)
        p = target * PCT * debt_total // coll_total
        record("price", lambda p=p: setattr(feed, "price", p), a=p)
        record("trigger", b.trigger_shutdown)
    assert b.shutdown_at, f"{variant}: the branch did not shut down"
    price = b.settle_price
    st["under_water"] = sum(1 for t in b.troves.values() if t.status in (ACTIVE, ZOMBIE)
                            and b.coll_now(t) * price < b.debt_now(t) * WAD)

    def try_claim(who):
        bal = s.stable.bal[NAMES[who]]
        x = rng.randint(1, max(bal, 1)) if rng.random() < 0.8 else bal
        return record("redeem_bad", lambda: b.redeem_bad_debt_coll(NAMES[who], x), who, a=x)

    # --- phase 1 -------------------------------------------------------------------------------------------------------
    remaining = open_ids()
    rng.shuffle(remaining)
    n_settle_now = {"failure": len(remaining) * 2 // 3, "absorb": len(remaining) - 4, "haircut": len(remaining) - 4,
                    "empty": 0}[variant]
    early, rest = remaining[:n_settle_now], remaining[n_settle_now:]
    st["claims_refused_phase1"] += not try_claim(richest())             # nobody is paid while a Trove is unsettled (X4)
    while early:
        r = rng.random()
        if r < 0.25 and len(early) >= 2:
            k = rng.randint(2, min(6, len(early)))
            ids, early = early[:k], early[k:]
            u = rng.randrange(N_USERS)
            if record("settle_batch", lambda ids=ids, u=u: b.settle_troves(ids, NAMES[u]), u, ids=ids):
                st["batches"] += 1
                st["settled"] += len(ids)
        elif r < 0.75:
            tid, early = early[0], early[1:]
            u = rng.randrange(N_USERS)
            st["settled"] += record("settle", lambda t=tid, u=u: b.settle_trove(t, NAMES[u]), u, tid)
        else:
            who = richest()
            ok = try_claim(who)                                        # refused while any Trove is unsettled (X4)
            st["claims_refused_phase1"] += not ok
            u = rng.randrange(N_USERS)
            record("claim_liq_surplus", lambda u=u: b.claim_liquidation_surplus(NAMES[u]), u)
            u = rng.randrange(N_USERS)
            record("claim_surplus", lambda u=u: b.claim_settlement_surplus(NAMES[u]), u)
    # a write-off before the delay is refused; after it, the rest are written off, one of them is settled at once
    if rest:
        record("write_off", lambda t=rest[0]: b.write_off(t, NAMES[1]), 1, rest[0])
        dt = 30 * DAY + rng.randint(0, DAY)
        record("warp", lambda: clock.warp(dt), a=dt)
        if variant != "empty" and len(rest) >= 2:
            undo = rest[0]
            if record("write_off", lambda: b.write_off(undo, NAMES[2]), 2, undo):
                st["write_offs"] += 1
            if record("settle", lambda: b.settle_trove(undo, NAMES[3]), 3, undo):
                st["undone"] += 1                                      # settled before phase 1 ends: undone (X5)
                st["settled"] += 1
            rest = rest[1:]
        for tid in rest:
            u = rng.randrange(N_USERS)
            if record("write_off", lambda t=tid, u=u: b.write_off(t, NAMES[u]), u, tid):
                st["write_offs"] += 1
    assert b.unsettled == 0 and b.surplus_keep is not None, f"{variant}: phase 1 did not end"
    late = [t.id for t in b.troves.values() if t.status in (ACTIVE, ZOMBIE)]
    keep_at_end_of_phase_one = b.surplus_keep

    # --- phase 2: claims, surpluses and the late settlements between them -------------------------------------------
    pot_empty = b.bad_debt_coll == 0
    rng.shuffle(late)
    for i in range(60):
        r = rng.random()
        if late and (r < 0.15 or i > 50):
            tid, late = late[0], late[1:]
            u = rng.randrange(N_USERS)
            st["late"] += record("settle", lambda t=tid, u=u: b.settle_trove(t, NAMES[u]), u, tid)
        elif r < 0.5:
            who = rng.randrange(N_USERS)
            if s.stable.bal[NAMES[who]] == 0:
                who = richest()
            empty_now = b.bad_debt_coll == 0
            if try_claim(who):
                st["claims"] += 1
                st["empty_pot_claims"] += empty_now
        elif r < 0.6:
            who = richest()
            x = rng.randint(1, max(s.stable.bal[NAMES[who]], 1))
            record("repay_bad", lambda: b.repay_bad_debt(NAMES[who], x), who, a=x)    # only with an empty pot
        elif r < 0.7:
            who = rng.randrange(N_USERS)
            before = b.late_paid[NAMES[who]]
            record("claim_late", lambda: b.claim_late(NAMES[who]), who)
            st["late_paid"] += b.late_paid[NAMES[who]] > before
        elif r < 0.85:
            who = rng.randrange(N_USERS)
            before = b.surplus_paid_amt[NAMES[who]]
            record("claim_surplus", lambda: b.claim_settlement_surplus(NAMES[who]), who)
            st["surplus_paid"] += b.surplus_paid_amt[NAMES[who]] > before
        elif r < 0.9:
            who = rng.randrange(N_USERS)
            record("claim_liq_surplus", lambda: b.claim_liquidation_surplus(NAMES[who]), who)
        elif r < 0.95:
            who = richest()
            x = max(s.stable.bal[NAMES[who]] // 4, 1)
            want = b.bad_debt_coll * x // max(b.bad_debt, 1) + 1       # one wei more than the share: refused
            record("redeem_bad", lambda: b.redeem_bad_debt_coll(NAMES[who], x, want), who, a=x, bb=want)
        else:
            u, v = rng.randrange(N_USERS), rng.randrange(N_USERS)
            x = amt(1, 3_000)
            record("give", lambda: s.stable.transfer(NAMES[u], NAMES[v], x), u, a=v, bb=x)
    for tid in late:                                                   # the Troves still written off are settled ...
        st["late"] += record("settle", lambda t=tid: b.settle_trove(t, NAMES[0]), 0, tid)
    for who in range(N_USERS):                                         # ... and everybody collects everything
        before = b.late_paid[NAMES[who]]
        record("claim_late", lambda w=who: b.claim_late(NAMES[w]), who)
        st["late_paid"] += b.late_paid[NAMES[who]] > before
        before = b.surplus_paid_amt[NAMES[who]]
        record("claim_surplus", lambda w=who: b.claim_settlement_surplus(NAMES[w]), who)
        st["surplus_paid"] += b.surplus_paid_amt[NAMES[who]] > before

    ledger_len = LEDGER_LEN
    assert len(ledger) == len(ops["kind"]) * ledger_len
    assert st["claims_refused_phase1"] >= 1, (variant, st)
    assert all(t.status not in (ACTIVE, ZOMBIE) for t in b.troves.values()), "every Trove is settled in the end"
    assert st["claims"] >= 5, (variant, st)
    if variant == "failure":
        # the healthy owners' surplus covered the written-off Troves at par, so their late settlements give it back
        # to the owners (keep rises) rather than to the holders
        assert st["undone"] == 1 and st["late"] >= 1 and st["batches"] >= 1, st
        assert keep_at_end_of_phase_one < b.surplus_keep, (keep_at_end_of_phase_one, b.surplus_keep)
    if variant == "absorb":
        assert st["under_water"] >= 1 and 0 < b.take and b.surplus_keep < L_PRECISION and st["surplus_paid"] >= 1, st
    if variant == "haircut":
        assert b.take == b.settle_surplus_gross and b.surplus_keep == 0, st   # all the surplus is used ...
        assert b.settle_short_total > b.take, "... and the holders take a haircut"
    if variant == "empty":
        assert pot_empty and st["empty_pot_claims"] >= 1 and st["late"] >= 1 and st["late_paid"] >= 1, st
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()}, "batch": [str(x) for x in batch],
             "batchLen": [str(x) for x in batch_len], "ledger": [str(x) for x in ledger], "ledgerLen": str(ledger_len),
             "troves": [str(x) for x in troves], "trovesLen": [str(x) for x in troves_len], "troveLen": str(TROVE_LEN),
             "config": {"users": str(N_USERS), "funding": str(FUNDING), "start": str(START), "betaWad": str(SYSTEM["beta"] * WAD), "initialBaseRate": str(SYSTEM["initial_base_rate"])}}
    st["keep_rose"] = int(keep_at_end_of_phase_one < b.surplus_keep)
    stats = dict(steps=len(ops["kind"]), ok=sum(ok_by_kind.values()), refused=sum(bad_by_kind.values()),
                 ok_by_kind=ok_by_kind, bad_by_kind=bad_by_kind, settlement=st, keep=b.surplus_keep)
    return trace, stats
