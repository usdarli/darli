"""
Invariant fuzzer. Random sequences of user ops, liquidations, redemptions, price moves,
oracle/network states, governance parameter changes and idle time.
Invariants are checked BEFORE and AFTER every step.   python3 fuzz.py [seeds] [steps]
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import random
import sys

from model import (L_PRECISION, route_revenue, StreamingStaking, WAD, DAY, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED, ACTIVE, ZOMBIE,
                   Clock, Token, Feed, System, Revert, atomic, check_invariants)

E = WAD
PCT = WAD // 100
USERS = [f"u{i}" for i in range(6)]


def build(rng):
    clock = Clock()
    s = System(clock, sp_share=rng.choice([50, 72, 80]) * PCT, frontend_share=rng.choice([0, 3, 10]) * PCT)
    brs = []
    for name, price in (("WETH", 2000 * E), ("LST", 2300 * E)):
        tok = Token(name)
        b = s.create_branch(name, tok, Feed(price), mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT,
                            pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=5 * 10**6 * E, gas_deposit=(E // 1000 if name == "WETH" else 0))   # explicit: the first branch posts deposits
        for u in USERS:
            tok.mint(u, 10**4 * E)
        brs.append(b)
    fids = [0, s.frontends.register("FE1", 0), s.frontends.register("FE2", 40 * PCT)]
    s.fix_staking_destination(StreamingStaking(clock, s.stable))      # the fixed revenue destination, as at deployment
    assert any(b.gas_deposit > 0 for b in brs), "fuzzer must exercise the gas-deposit paths"
    return clock, s, brs, fids


def step(rng, clock, s, brs, fids, stats):
    b = rng.choice(brs)
    u = rng.choice(USERS)
    mine = [t for t in b.open_troves() if t.owner == u]
    anyt = b.open_troves()
    op = rng.choice(["open", "open", "borrow", "repay", "repay", "add", "withdraw", "rate", "close", "apply",
                     "adjust", "adjust", "sp_dep", "sp_wd", "sp_claim", "liq", "liq", "redeem", "price", "price", "warp", "warp",
                     "status", "min_debt", "donate", "stake", "unstake", "stk_claim", "route", "route", "fe_claim", "urgent", "urgent", "late", "claim_late", "bad_debt", "bad_debt", "transfer", "shutdown", "surplus"])
    price = b.feed.price
    stats["last"] = op

    def amt(lo, hi):
        return rng.randint(lo, hi) * E + rng.randint(0, 10**9)

    if op == "open":
        debt = amt(2_000, 60_000)
        coll = debt * rng.randint(112, 400) // 100 * E // price
        return lambda: b.open_trove(u, coll, debt, rng.randint(1, 250) * PCT // 2 + rng.randint(0, 99),
                                    frontend=rng.choice(fids))
    if op == "borrow" and mine:
        return lambda: b.borrow(rng.choice(mine).id, amt(1, 20_000))
    if op == "repay" and mine:
        return lambda: b.repay(rng.choice(mine).id, amt(1, 30_000))
    if op == "add" and mine:
        return lambda: b.add_coll(rng.choice(mine).id, rng.randint(1, 10**19))
    if op == "withdraw" and mine:
        return lambda: b.withdraw_coll(rng.choice(mine).id, rng.randint(1, 5 * 10**18))
    if op == "adjust" and mine:
        dc = rng.choice([-1, 0, 1]) * rng.randint(1, 3 * 10**18)
        dd = rng.choice([-1, 0, 1]) * amt(1, 15_000)
        return lambda: b.adjust_trove(rng.choice(mine).id, dc, dd)
    if op == "rate" and mine:
        return lambda: b.adjust_rate(rng.choice(mine).id, rng.randint(1, 250) * PCT // 2)
    if op == "close" and mine:
        return lambda: b.close_trove(rng.choice(mine).id)
    if op == "apply" and anyt:
        return lambda: b.apply_pending_debt(rng.choice(anyt).id)
    if op == "sp_dep":
        bal = s.stable.bal[u]
        if bal > E:
            return lambda: b.sp.deposit(u, rng.randint(E, bal))
    if op == "sp_wd":
        return lambda: b.sp.withdraw(u, rng.randint(1, 10**24))
    if op == "sp_claim":
        return lambda: b.sp.claim(u)
    if op == "liq" and anyt:
        cands = sorted(anyt, key=lambda t: b.icr(t, price))
        return lambda: b.liquidate(cands[0].id, "liquidator")
    if op == "redeem":
        bal = s.stable.bal[u]
        if bal > E:
            return lambda: s.redeem(u, rng.randint(E, bal), max_iter=rng.randint(1, 8))
    if op == "price":
        def f():
            b.feed.price = max(price * rng.choice([70, 90, 95, 98, 100, 102, 105, 110, 125]) // 100, E)
            b.trigger_shutdown()
        return f
    if op == "warp":
        return lambda: clock.warp(rng.choice([1, 12, 3600, DAY, 30 * DAY, 400 * DAY]))
    if op == "status":
        def f():
            b.feed.status = rng.choice([VALID, VALID, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED])
        return f
    if op == "min_debt":
        def f():
            b._step_a()
            b.min_debt = rng.choice([100, 2_000, 5_000, 10_000]) * E      # not a governance action any more: exercises the MIN_DEBT rules on troves of every size
        return f
    if op == "stake":
        who = rng.choice(["k1", "k2", "k3"]); amt = rng.randint(1, 5_000) * E
        return lambda: s.staking.stake(who, amt)
    if op == "unstake":
        who = rng.choice(["k1", "k2", "k3"]); have = s.staking.stake_of[who]
        if not have:
            return None
        amt = rng.randint(1, have)
        return lambda: s.staking.unstake(who, amt)
    if op == "stk_claim":
        who = rng.choice(["k1", "k2", "k3"])
        return lambda: s.staking.claim(who)
    if op == "route":
        return lambda: route_revenue(s)
    if op == "donate":
        def f():
            k = rng.randint(0, 3)
            if k == 0 and b.coll.bal[u] > 10:
                b.coll.transfer(u, b.vault, rng.randint(1, 10))
            elif k == 1 and b.coll.bal[u] > 10:
                b.coll.transfer(u, b.sp.addr, rng.randint(1, 10))
            elif s.stable.bal[u] > 10:
                s.stable.transfer(u, rng.choice([b.sp.addr, s.frontends.ADDR, s.ESCROW]), rng.randint(1, 10))
        return f
    if op == "fe_claim":
        return lambda: s.frontends.claim(rng.choice(USERS + ["FE1", "FE2"]))
    if op == "urgent" and b.shutdown_at and anyt:                 # after a shutdown: settle, or (after the deadline) write off
        t = rng.choice(anyt)
        if rng.random() < 0.3:
            return lambda: b.write_off(t.id, u)
        return lambda: b.settle_trove(t.id, u)
    if op == "late" and b.shutdown_at and b.written_off:            # a written-off Trove pays after all
        tid = rng.choice(list(b.written_off))
        return lambda: b.settle_trove(tid, u)
    if op == "claim_late" and b.late_per_unit:
        return lambda: b.claim_late(u)
    if op == "bad_debt" and b.bad_debt:
        bal = min(s.stable.bal[u], b.bad_debt)
        if bal > 0:
            R = bal if rng.random() < 0.4 else rng.randint(1, bal)
            if rng.random() < 0.5 and not b.oracle_failed:
                b.feed.price = b.feed.price * 3 // 2      # bucket worth more than the bad debt
            return (lambda: b.redeem_bad_debt_coll(u, R)) if b.bad_debt_coll else (lambda: b.repay_bad_debt(u, R))
    if op == "transfer" and mine:
        return lambda: b.transfer_trove(rng.choice(mine).id, rng.choice(USERS))
    if op == "shutdown":
        return b.trigger_shutdown
    if op == "surplus":
        return lambda: b.claim_surplus(u)
    return None


def run(seed, steps):
    rng = random.Random(seed)
    clock, s, brs, fids = build(rng)
    stats = dict(ok=0, reverted=0, max_eps=0, max_ratio=0.0, by={})
    for i in range(steps):
        fn = step(rng, clock, s, brs, fids, stats)
        if fn is None:
            continue
        check_invariants(s, f"seed {seed} step {i} BEFORE")
        try:
            atomic(s, fn)
            stats["ok"] += 1
            stats["by"][stats["last"]] = stats["by"].get(stats["last"], 0) + 1      # per-operation coverage
        except Revert:
            stats["reverted"] += 1
        rep = check_invariants(s, f"seed {seed} step {i} AFTER")
        for bb in brs:
            assert bb.gas_pool >= 0 and bb.settle_surplus_pool >= 0 and bb.late_pool >= 0 and bb.bad_debt_coll >= 0, f"seed {seed} step {i}: a named pool went negative"
        for bb in brs:                                              # late recoveries: entitlements never exceed the named pools
            if bb.late_per_unit:
                owed = sum(bb.units_of[w] * bb.late_per_unit // L_PRECISION - bb.late_paid[w] for w in list(bb.units_of))
                assert owed <= bb.late_pool + 3, f"seed {seed} step {i}: late entitlements exceed the late pool"
            if bb.surplus_keep is not None:
                owed_s = sum(bb.gross_of[w] * bb.surplus_keep // L_PRECISION - bb.surplus_paid_amt[w] for w in list(bb.gross_of))
                assert owed_s <= bb.settle_surplus_pool + 3, f"seed {seed} step {i}: surplus entitlements exceed the surplus pool"
        for bb in brs:                                              # staged settlement: nobody is paid before phase 1 ends ...
            if bb.shutdown_at and bb.unsettled > 0:
                key = (bb.name, "pot")
                prev = stats.setdefault("pots", {}).get(key)
                claims = (bb.bad_debt_coll, bb.bad_debt)
                # ... so while Troves are unsettled the pot can only GROW and claims can only be ADDED
                assert prev is None or (claims[0] >= prev[0] and claims[1] >= prev[1]), f"seed {seed} step {i}: somebody was paid during phase 1"
                stats["pots"][key] = claims
        stk = s.staking
        assert s.stable.bal[stk.addr] + 5 >= stk.liabilities() - 1, f"seed {seed} step {i}: staking contract cannot cover what it owes"
        for name, r in rep.items():
            stats["max_eps"] = max(stats["max_eps"], r["eps"])
            b = s.branches[name]
            bound = r["n_a"] + r["n_b"] + r["n_r"] * (len(b.troves) + 1) + 1
            stats["max_ratio"] = max(stats["max_ratio"], r["eps"] / bound)
            assert r["eps"] <= bound, f"eps {r['eps']} > bound {bound} (seed {seed} step {i})"
    stats["shutdown"] = [b.name for b in brs if b.shutdown_at]
    stats["troves_rewarded"] = sum(len(b.gas_paid) for b in brs)
    stats["gas_paid_total"] = sum(sum(b.gas_paid.values()) for b in brs)
    stats["bad_debt"] = sum(b.bad_debt for b in brs)
    return stats


def _main():

        seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 40
        steps = int(sys.argv[2]) if len(sys.argv) > 2 else 400
        by = {}
        tot = dict(ok=0, reverted=0, max_eps=0, max_ratio=0.0, shutdowns=0, with_bad_debt=0)
        for seed in range(seeds):
            st = run(seed, steps)
            tot["ok"] += st["ok"]; tot["reverted"] += st["reverted"]
            tot["max_eps"] = max(tot["max_eps"], st["max_eps"]); tot["max_ratio"] = max(tot["max_ratio"], st["max_ratio"])
            for k, v in st["by"].items():
                by[k] = by.get(k, 0) + v
            tot["shutdowns"] += len(st["shutdown"]); tot["with_bad_debt"] += 1 if st["bad_debt"] else 0
            tot["troves_rewarded"] = tot.get("troves_rewarded", 0) + st["troves_rewarded"]
            tot["gas_paid_total"] = tot.get("gas_paid_total", 0) + st["gas_paid_total"]
        print(f"{seeds} seeds x {steps} steps: all invariants held before and after every step")
        print(tot)
        assert tot["troves_rewarded"] > 0, "no Trove was ever rewarded: the deposit paths were not exercised"
        print("successful ops:", dict(sorted(by.items())))


if __name__ == "__main__":
    try:
        _main()
    except AssertionError as e:                       # a PROPERTY failed: the only outcome that counts as a kill for mutants.py
        print("PROPERTY_FAILURE", str(e)[:300])
        sys.exit(1)
    except Exception as e:                            # anything else is an infrastructure error, never a kill
        import traceback; traceback.print_exc()
        print("INFRASTRUCTURE_ERROR", type(e).__name__)
        sys.exit(2)
