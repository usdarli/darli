"""
Invariant fuzzer. Random sequences of user ops, liquidations, redemptions, price moves,
oracle/network states, governance parameter changes and idle time.
Invariants are checked BEFORE and AFTER every step.   python3 fuzz.py [seeds] [steps] [first_seed]

`first_seed` lets a nightly run cover seeds nobody has run before instead of repeating the release configuration; it
defaults to 0, so `fuzz.py 30 300` stays exactly the run docs/RESULTS.md records, and only that run writes figures.
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

# Minimum number of SUCCESSFUL executions of each operation, per 9,000 (seeds x steps) of budget, scaled to the budget
# actually run. The histogram below was already printed, but nothing failed when an entry went to zero: `claim_late` sat
# at 0 and `liq` at 17 while `docs/SPEC.md` 12 claimed fuzzer coverage of liquidation and of the late-recovery claims.
# A path that stops being reachable is a silent loss of coverage, so it is now an assertion. These are floors with
# margin under what the release configuration reaches, not targets: raise them when the generator gets better, and
# never lower one to make a run pass -- a fallen count means a path became unreachable, which is the finding.
MIN_COVERAGE = {"open": 60, "borrow": 4, "repay": 12, "close": 4, "withdraw": 6, "adjust": 12, "rate": 6,
                "liq": 20, "redeem": 15, "sp_dep": 15, "sp_wd": 60, "bad_debt": 8, "urgent": 12,
                "late": 2, "claim_late": 2, "surplus": 50, "crash": 80, "transfer": 8, "unstake": 30}
COVERAGE_BASE = 9_000            # the (seeds x steps) budget MIN_COVERAGE is stated for: the release configuration 30 x 300


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
                     "status", "min_debt", "donate", "stake", "unstake", "stk_claim", "route", "route", "fe_claim", "urgent", "urgent", "late", "late", "claim_late", "claim_late", "bad_debt", "bad_debt", "transfer", "shutdown", "surplus",
                     "crash", "crash", "liq", "liq"])
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
    if op == "crash":
        # A uniform random walk almost never puts a single Trove under MCR while the branch stays live, so the waterfall of
        # SPEC L2 (offset, redistribution, bad debt) was reached 17 times in 9,000 steps. This operation prices the weakest
        # Trove deliberately: it moves the feed to the price at which that Trove's ICR is a chosen value at or below MCR,
        # which is what a crash does to the thinnest position first. It changes no rule; it only makes the state reachable.
        if not anyt:
            return None
        def f():
            # Take the Troves weakest first and move the feed to the price at which one of them is liquidatable while the
            # BRANCH IS STILL LIVE (TCR >= SCR). A price that also takes TCR under SCR produces a shutdown, not a
            # liquidation, which is why the plain random walk reached the waterfall so rarely. If no Trove can be put
            # under MCR without shutting the branch down, nothing moves.
            for t in sorted(anyt, key=lambda t: b.icr(t, b.feed.price)):
                d = b.debt_now(t)
                if not d or not t.coll:
                    continue
                target = rng.choice([100, 100, 104, 108]) * PCT           # ICR the Trove should have after the move
                p = max(target * d // t.coll, 1)
                if b.tcr(p) >= b.scr:
                    b.feed.price = p
                    return
            # deliberately no trigger_shutdown(): a price move is not a report. Recording a shutdown is somebody's
            # transaction (`shutdown`, `price`, `status`, a liquidation or a redemption), and leaving that to the other
            # operations is what gives a liquidator the window a real keeper has.
        return f
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
        if rng.random() < 0.5:                                   # write-off is the only route to a late recovery
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
                # BOUND 0, argued, not measured. late_per_unit = SUM_i floor(to_holders_i * L / claim_units) <=
                # (SUM_i to_holders_i) * L / claim_units, and SUM_w units_of[w] <= claim_units because units are only ever
                # issued against bad_debt. Hence SUM_w floor(units_w * late_per_unit / L) <= SUM_i to_holders_i, and the
                # pool holds exactly SUM_i to_holders_i - SUM_w late_paid[w]. Every division floors in the pool's favour,
                # so the entitlement can never exceed it by even one wei.
                owed = sum(bb.units_of[w] * bb.late_per_unit // L_PRECISION - bb.late_paid[w] for w in list(bb.units_of))
                assert owed <= bb.late_pool, f"seed {seed} step {i}: late entitlements exceed the late pool by {owed - bb.late_pool}"
            if bb.surplus_keep is not None:
                # BOUND 0, same argument. surplus_keep = floor((G - take) * L / G) with G = settle_surplus_gross =
                # SUM_w gross_of[w], so SUM_w floor(gross_w * keep / L) <= G * keep / L <= G - take, which is what the pool
                # was given at the end of phase 1; later recoveries only add to it, and every payment lowers both sides.
                owed_s = sum(bb.gross_of[w] * bb.surplus_keep // L_PRECISION - bb.surplus_paid_amt[w] for w in list(bb.gross_of))
                assert owed_s <= bb.settle_surplus_pool, f"seed {seed} step {i}: surplus entitlements exceed the surplus pool by {owed_s - bb.settle_surplus_pool}"
        for bb in brs:                                              # staged settlement: nobody is paid before phase 1 ends ...
            if bb.shutdown_at and bb.unsettled > 0:
                key = (bb.name, "pot")
                prev = stats.setdefault("pots", {}).get(key)
                claims = (bb.bad_debt_coll, bb.bad_debt)
                # ... so while Troves are unsettled the pot can only GROW and claims can only be ADDED
                assert prev is None or (claims[0] >= prev[0] and claims[1] >= prev[1]), f"seed {seed} step {i}: somebody was paid during phase 1"
                stats["pots"][key] = claims
        stk = s.staking
        # BOUND 1, and the one wei is `liabilities()`'s own deliberate round-up (it returns accrued + unstreamed + 1), not
        # slack: every term inside it floors, so accrued + unstreamed never exceeds the balance actually held.
        assert s.stable.bal[stk.addr] + 1 >= stk.liabilities(), \
            f"seed {seed} step {i}: staking contract cannot cover what it owes (short by {stk.liabilities() - 1 - s.stable.bal[stk.addr]})"
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
        first = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        by = {}
        tot = dict(ok=0, reverted=0, max_eps=0, max_ratio=0.0, shutdowns=0, with_bad_debt=0)
        for seed in range(first, first + seeds):
            st = run(seed, steps)
            tot["ok"] += st["ok"]; tot["reverted"] += st["reverted"]
            tot["max_eps"] = max(tot["max_eps"], st["max_eps"]); tot["max_ratio"] = max(tot["max_ratio"], st["max_ratio"])
            for k, v in st["by"].items():
                by[k] = by.get(k, 0) + v
            tot["shutdowns"] += len(st["shutdown"]); tot["with_bad_debt"] += 1 if st["bad_debt"] else 0
            tot["troves_rewarded"] = tot.get("troves_rewarded", 0) + st["troves_rewarded"]
            tot["gas_paid_total"] = tot.get("gas_paid_total", 0) + st["gas_paid_total"]
        print(f"{seeds} seeds x {steps} steps from seed {first}: all invariants held before and after every step")
        print(tot)
        assert tot["troves_rewarded"] > 0, "no Trove was ever rewarded: the deposit paths were not exercised"
        print("successful ops:", dict(sorted(by.items())))

        budget = seeds * steps
        if budget < COVERAGE_BASE:
            # Enforcing a floor on a budget too small to reach the path would make the floor a lottery, not a check: at
            # 10 x 200 `close` legitimately reaches zero. A short run is a smoke test and says so; the floors belong to
            # the release configuration, which CI also runs.
            print(f"coverage: floors NOT enforced ({budget} < {COVERAGE_BASE} steps of budget: smoke run)")
        else:
            scale = budget / COVERAGE_BASE
            short = []
            for op in sorted(MIN_COVERAGE):
                need = max(1, round(MIN_COVERAGE[op] * scale))
                if by.get(op, 0) < need:
                    short.append(f"{op} {by.get(op, 0)} < {need}")
            assert not short, ("coverage floor not met (a path stopped being reachable): " + "; ".join(short))
            print(f"coverage: every one of {len(MIN_COVERAGE)} required operations met its floor")

        if (seeds, steps, first) == (30, 300, 0):        # the configuration docs/RESULTS.md records
            from figures import fig, dump
            fig("fuzz_stats", tot)
            fig("fuzz_max_eps_wei", tot["max_eps"])
            fig("fuzz_troves_rewarded", tot["troves_rewarded"])
            fig("fuzz_shutdowns", tot["shutdowns"])
            for op in ("liq", "bad_debt", "late", "claim_late", "redeem", "sp_dep", "urgent"):
                fig(f"fuzz_ops_{op}", by.get(op, 0))
            print(f"figures: {dump('fuzz')} recorded")


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
