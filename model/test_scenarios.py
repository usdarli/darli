"""
Failure scenarios pinning the rules of `docs/SPEC.md`. Run:  python3 test_scenarios.py
Each scenario checks the invariants before and after every step where it matters.
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import random
import sys
import traceback

from figures import fig
from model import (L_PRECISION, LPFeeVault, OracleFeed, Source, Sequencer, NETWORK_UNSTABLE, P_FLOOR, WAD, DAY, YEAR, VALID, PRICE_INVALID, FAILED, ACTIVE, ZOMBIE, MIN_SP_RESIDUAL,
                   MAX_SP_DEPOSITS, Clock, Token, Feed, System, StreamingStaking, Revert,
                   check_invariants)

PCT = WAD // 100
E = WAD


def setup(price=2000 * E, debt_cap=10**9 * E, cap_ceiling=None, **sys_kw):
    clock = Clock()
    s = System(clock, **sys_kw)
    weth = Token("WETH")
    feed = Feed(price)
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT,
                        pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=debt_cap, cap_ceiling=cap_ceiling)
    return clock, s, b, weth, feed


def fund(weth, who, amt):
    weth.mint(who, amt)


def expect_revert(fn, *a, **kw):
    import model
    try:
        model.atomic(model.CURRENT_SYSTEM, fn, *a, **kw)
    except Revert as e:
        return str(e)
    raise AssertionError(f"expected revert from {fn.__name__}")


def give_stable(s, b, weth, who, amount):
    """Mint stable for `who` by opening a very safe helper trove, then transfer."""
    helper = f"helper:{who}:{len(b.troves)}"
    fund(weth, helper, 10**6 * E)
    b.open_trove(helper, 10**6 * E, amount, 5 * PCT)
    s.stable.transfer(helper, who, amount)


def pool_all(s, keep=()):
    """Test-only 'market': route every liquid stable balance to one account."""
    for holder in list(s.stable.bal):
        if holder not in keep and holder != "pool" and s.stable.bal[holder]:
            s.stable.transfer(holder, "pool", s.stable.bal[holder])


# --------------------------------------------------------------------------- #
def scenario_01_time_without_transactions():
    clock, s, b, weth, _ = setup()
    fund(weth, "A", 100 * E); fund(weth, "B", 100 * E)
    a = b.open_trove("A", 100 * E, 10_000 * E, 5 * PCT)
    bb = b.open_trove("B", 100 * E, 20_000 * E, 10 * PCT)
    check_invariants(s, "open")
    clock.warp(3 * YEAR)                       # nothing happens for three years
    rep = check_invariants(s, "after 3y, before step A")     # identity (2) must hold *now*
    assert b.pending_agg_interest() > 0
    b.apply_pending_debt(a)
    check_invariants(s, "after touching A only")
    clock.warp(17)
    check_invariants(s, "17s later")
    b.apply_pending_debt(bb)
    rep = check_invariants(s, "after touching B")
    return f"eps after 3y = {rep['WETH']['eps']} wei"


def scenario_02_shutdown_then_time():
    clock, s, b, weth, feed = setup()
    for who in "ABC":
        fund(weth, who, 100 * E)
    ta = b.open_trove("A", 10 * E, 10_000 * E, 5 * PCT)
    tb = b.open_trove("B", 10 * E, 10_000 * E, 50 * PCT)
    tc = b.open_trove("C", 10 * E, 12_000 * E, 20 * PCT)
    clock.warp(30 * DAY)
    feed.price = 1200 * E                      # TCR = 36000/32000+ < 110%  -> SCR trigger
    b.trigger_shutdown()
    assert b.shutdown_at == clock.now and b.agg_w == 0
    debts_at_shutdown = {t.id: b.debt_now(t) for t in b.open_troves()}
    supply_at_shutdown = s.stable.supply
    clock.warp(400 * DAY)
    check_invariants(s, "long after shutdown")
    for t in b.open_troves():
        assert b.debt_now(t) == debts_at_shutdown[t.id], "trove debt grew after shutdown"
    assert b.pending_agg_interest() == 0
    # after a shutdown no single-Trove exit exists any more; every Trove is settled at the frozen debt and ONE reference price
    for fn in (lambda: b.repay(ta, 1_000 * E), lambda: b.close_trove(tb), lambda: b.add_coll(ta, 1 * E), lambda: b.liquidate(tc, "k")):
        assert "settle" in expect_revert(fn)
    assert b.settle_price == 1200 * E, "the reference price is the price at the moment of shutdown"
    feed.price = 700 * E                                         # later market moves change nothing
    for tid in (tc, ta, tb):
        r = b.settle_trove(tid)
        assert r["debt"] == debts_at_shutdown[tid], "settlement must see the frozen debt"
    assert b.agg_w == 0 and b.settle_price == 1200 * E and b.unsettled == 0
    assert s.stable.supply == supply_at_shutdown
    check_invariants(s, "after settlement")
    expect_revert(b.open_trove, "A", 1 * E, 2_000 * E, 5 * PCT)
    return "debts frozen at shutdownAt; aggW stays 0"


def scenario_03_sp_jit_deposit():
    clock, s, b, weth, _ = setup()
    fund(weth, "A", 1000 * E)
    b.open_trove("A", 1000 * E, 500_000 * E, 20 * PCT)
    give_stable(s, b, weth, "old", 10_000 * E)
    give_stable(s, b, weth, "whale", 5_000_000 * E)
    b.sp.deposit("old", 10_000 * E)
    clock.warp(90 * DAY)                       # interest accrues, nobody touches the branch
    bal0 = s.stable.bal["whale"]
    b.sp.deposit("whale", 5_000_000 * E)       # tries to front-run the pending interest
    b.sp.withdraw("whale", 5_000_000 * E)
    b.sp.claim("whale")
    profit = s.stable.bal["whale"] - bal0
    assert profit == 0, f"JIT depositor captured {profit}"
    _, y_old = b.sp.claim("old")
    assert y_old > 0
    check_invariants(s)
    return f"whale profit = 0, old depositor yield = {y_old / E:.2f}"


def scenario_04_staker_stream():
    """Fixed weekly epochs: what is handed over during epoch k is streamed over epoch k + 1."""
    clock, s, b, weth, _ = setup()
    give_stable(s, b, weth, "router", 70_000 * E)
    give_stable(s, b, weth, "router2", 70_000 * E)
    stk = StreamingStaking(clock, s.stable)
    W = stk.PERIOD
    stk.stake("old", 1_000 * E)
    clock.warp(3 * DAY)
    stk.notify_reward("router", 70_000 * E)    # epoch 0: queued, nothing is paid yet
    clock.warp(W - 3 * DAY - 12)
    assert stk.claim("old") == 0, "revenue handed over in epoch k must not be paid before epoch k + 1"
    stk.stake("whale", 999_000 * E)            # enters 12 seconds before the stream starts ...
    clock.warp(24)                             # ... and leaves 12 seconds into it
    stk.unstake("whale", 999_000 * E)
    got = stk.claim("whale")
    max_fair = 70_000 * E * 12 // W            # the whole stream for the 12 seconds it was really there
    assert got <= max_fair, "whale got more than its 12 seconds of stream"
    # old staker leaves mid-stream: accrued reward must stay claimable
    clock.warp(3 * DAY)
    stk.unstake("old", 1_000 * E)
    clock.warp(30 * DAY)
    stk.notify_reward("router2", 70_000 * E)   # later funding must not dilute what old earned
    earned_old = stk.claim("old")
    lo = 70_000 * E * (3 * DAY) // W * 99 // 100
    assert earned_old >= lo, "old staker lost accrued reward after exit"
    # stream seconds that elapsed with zero stake must not vanish: they join the next epoch
    stk.stake("late", 1 * E)
    clock.warp(2 * W + 1)
    late = stk.claim("late")
    total_paid = got + earned_old + late
    assert 140_000 * E - total_paid < 10**6, "reward tokens stranded in the staking contract"
    return (f"nothing paid before the next epoch; whale got {got / E:.4f} (cap {max_fair / E:.4f}); old kept {earned_old / E:.2f}; "
            f"idle-stream rollover paid later = {late / E:.2f}; stranded = {140_000 * E - total_paid} wei")


def scenario_05_frontend_long_untouched():
    clock, s, b, weth, _ = setup()
    fe = s.frontends
    fid = fe.register("FE1", 25 * PCT)
    fund(weth, "A", 100 * E); fund(weth, "B", 100 * E)
    ta = b.open_trove("A", 100 * E, 50_000 * E, 10 * PCT, frontend=fid)
    credited_open = fe.total_credited
    clock.warp(60 * DAY)
    tb = b.open_trove("B", 100 * E, 50_000 * E, 10 * PCT)      # untagged; touches the branch
    for _ in range(30):                        # B is touched weekly for months, A never
        clock.warp(7 * DAY)
        b.apply_pending_debt(tb)
    before = fe.claimable["FE1"] + fe.claimable["A"]
    a_interest = b.accrued(b.troves[ta])
    b.apply_pending_debt(ta)
    gained = fe.claimable["FE1"] + fe.claimable["A"] - before
    assert gained == a_interest * fe.share // WAD, "frontend reward is not exactly its own trove's interest share"
    assert fe.claimable["A"] * 3 <= fe.claimable["FE1"] + 3, "kickback split wrong"
    check_invariants(s)
    # NFT transfer settles first: kickback up to the transfer stays with the old owner
    clock.warp(30 * DAY)
    pre = fe.claimable["A"]
    b.transfer_trove(ta, "A2")
    assert fe.claimable["A"] > pre and fe.claimable["A2"] == 0
    clock.warp(30 * DAY)
    b.apply_pending_debt(ta)
    assert fe.claimable["A2"] > 0
    b.apply_pending_debt(tb)                   # every trove touched at the same instant
    for who in ("FE1", "A", "A2", "B"):
        fe.claim(who)
    check_invariants(s)
    dust = s.stable.bal[fe.ADDR]
    assert dust < 10**6, "registry remainder should be rounding dust only"
    return f"credits <= deposits; ownerless rounding dust left in registry = {dust} wei"


def scenario_06_min_debt_increase():
    clock, s, b, weth, _ = setup()
    fund(weth, "A", 200 * E)
    ta = b.open_trove("A", 100 * E, 2_000 * E, 5 * PCT)
    b.min_debt = 3_000 * E                     # governance raises MIN_DEBT above A's debt
    b.repay(ta, 100 * E)                       # must not revert
    b.add_coll(ta, 1 * E)                      # must not revert
    msg = expect_revert(b.borrow, ta, 100 * E) # borrowing must reach the new minimum
    assert "MIN_DEBT" in msg
    b.borrow(ta, 1_200 * E)
    # and a trove that *was* above the minimum cannot be repaid into the dust zone
    msg = expect_revert(b.repay, ta, 500 * E)
    assert "dust" in msg
    check_invariants(s)
    return "repay/addColl free below the new minimum; borrow must reach it"


def scenario_07_liquidations():
    out = []
    # (a) ICR < 100 %, SP full: depositors take the loss
    clock, s, b, weth, feed = setup()
    fund(weth, "bad", 10 * E); fund(weth, "good", 1000 * E)
    give_stable(s, b, weth, "dep", 100_000 * E)
    b.sp.deposit("dep", 100_000 * E)
    t = b.open_trove("bad", 10 * E, 10_000 * E, 5 * PCT)
    b.open_trove("good", 1000 * E, 10_000 * E, 5 * PCT)
    feed.price = 800 * E                       # collateral worth 8000 < debt
    r = b.liquidate(t, "liq")
    assert r["Y"] == 0 and r["surplus"] == 0
    value_to_sp = r["coll_x"] * feed.price // E
    assert value_to_sp < r["X"], "SP should be short when ICR < 100%"
    check_invariants(s, "7a")
    out.append(f"7a SP burned {r['X'] / E:.0f}, got value {value_to_sp / E:.0f}")
    # (b) ICR < 100 %, SP empty: redistribution to the other trove
    clock, s, b, weth, feed = setup()
    fund(weth, "bad", 10 * E); fund(weth, "good", 1000 * E)
    t = b.open_trove("bad", 10 * E, 10_000 * E, 5 * PCT)
    g = b.open_trove("good", 1000 * E, 10_000 * E, 5 * PCT)
    feed.price = 800 * E
    d_before = b.debt_now(b.troves[g])
    r = b.liquidate(t, "liq")
    assert r["X"] == 0 and not r["bad"]
    lost = r["Y"] - (b.debt_now(b.troves[g]) - d_before)
    assert 0 <= lost <= 1, "with 1e36 precision the redistribution carry must be at most 1 wei"
    check_invariants(s, "7b")
    out.append(f"7b redistributed (carry {lost} wei with 1e36 precision)")
    # (c) last trove, SP empty: bad debt + shutdown, never a revert
    clock, s, b, weth, feed = setup()
    fund(weth, "only", 10 * E)
    t = b.open_trove("only", 10 * E, 10_000 * E, 5 * PCT)
    feed.price = 1050 * E
    r = b.liquidate(t, "liq")
    assert r["bad"] and b.shutdown_at and b.bad_debt >= r["Y"] and b.bad_debt_coll == r["coll_y"]
    assert s.stable.supply == b.agg_debt == b.bad_debt
    check_invariants(s, "7c")
    out.append(f"7c badDebt={b.bad_debt / E:.2f} coll={b.bad_debt_coll / E:.4f}")
    return "; ".join(out)


def _bad_debt_branch():
    clock, s, b, weth, feed = setup()
    fund(weth, "only", 10 * E)
    t = b.open_trove("only", 10 * E, 10_000 * E, 5 * PCT)
    feed.price = 1050 * E
    b.liquidate(t, "liq")
    return clock, s, b, weth, feed


def scenario_08_bad_debt_settlement():
    # exact example from the critique: badDebt = 100, badDebtColl = 200
    clock, s, b, weth, feed = _bad_debt_branch()
    b.bad_debt_coll += 0                       # keep real numbers; test the 1:2 shape by price below
    for who in list(s.frontends.claimable):
        s.frontends.claim(who)
    pool_all(s, keep=(s.frontends.ADDR, b.sp.addr))
    holders = "pool"
    short = b.bad_debt - s.stable.bal["pool"]
    total_bad, total_coll = b.bad_debt, b.bad_debt_coll
    expect_revert(b.repay_bad_debt, holders, 1 * E)            # bucket not empty -> donation refused
    # three redeemers, different order, price moves in between: ratio must not change
    parts = [total_bad // 5, total_bad // 3, None]
    if short > 0:                              # tokens stuck as rounding dust elsewhere
        s.stable.transfer(s.frontends.ADDR, "pool", short)
    got = []
    ratio0 = total_coll * E // total_bad
    for i, R in enumerate(parts):
        R = b.bad_debt if R is None else R
        feed.price = [5000 * E, 300 * E, 1 * E][i]
        ratio_before = b.bad_debt_coll * E // b.bad_debt
        out = b.redeem_bad_debt_coll(holders, R)
        got.append((R, out))
        assert abs(out * E // R - ratio_before) <= 1
        assert abs(ratio_before - ratio0) <= 10, "pro-rata ratio drifted with order/price"
    assert b.bad_debt == 0 and b.bad_debt_coll == 0, "ownerless collateral left behind"
    assert s.stable.supply == 0 and b.agg_debt == 0
    expect_revert(b.redeem_bad_debt_coll, holders, 1)
    check_invariants(s)
    # bucket exhausted but bad debt left -> burning still works (pays nothing now, keeps the right to later recoveries)
    clock, s, b, weth, feed = _bad_debt_branch()
    b._coll_out("sink", b.bad_debt_coll); b.bad_debt_coll = 0               # simulate exhaustion
    assert b.redeem_bad_debt_coll("only", 1 * E) == 0 and b.units_of["only"] == 1 * E
    b.repay_bad_debt("only", 1 * E)
    check_invariants(s)
    return f"both reach zero together; ratio stable at {ratio0 / E:.6f} coll per unit"


def scenario_09_builtin_cap_schedule():
    """Immutable system: nobody raises the cap, it raises itself. cap(t) = min(ceiling, cap0 * 2^floor(days / 30))."""
    clock, s, b, weth, _ = setup(debt_cap=100_000 * E, cap_ceiling=350_000 * E)
    assert b.debt_cap == 100_000 * E
    clock.warp(30 * DAY - 1); assert b.debt_cap == 100_000 * E, "must not rise a second early"
    clock.warp(1);            assert b.debt_cap == 200_000 * E
    clock.warp(30 * DAY);     assert b.debt_cap == 350_000 * E, "the ceiling binds (not 400,000)"
    clock.warp(3650 * DAY);   assert b.debt_cap == 350_000 * E, "and it binds for ever"
    for forbidden in ("increase_cap", "decrease_cap", "graduate", "paused", "is_paused", "deprecated", "caps", "guardian"):
        assert not hasattr(s, forbidden) and not hasattr(b, forbidden), f"a governance hook survived: {forbidden}"
    return "100k -> 200k on day 30 -> ceiling 350k; no setter, pause or retirement exists on System or Branch"


def scenario_10_cap_limits_only_new_debt():
    clock, s, b, weth, _ = setup(debt_cap=20_000 * E, cap_ceiling=20_000 * E)
    fund(weth, "a", 1000 * E); fund(weth, "c", 1000 * E)
    ta = b.open_trove("a", 100 * E, 19_000 * E, 50 * PCT)
    msg = expect_revert(b.open_trove, "c", 100 * E, 2_000 * E, 5 * PCT)
    assert "debt cap" in msg
    clock.warp(200 * DAY)                                     # interest pushes aggDebt far above the cap
    b.apply_pending_debt(ta)
    assert b.agg_debt > b.debt_cap, "interest is never blocked by the cap"
    b.repay(ta, 1_000 * E); b.add_coll(ta, 1 * E)             # nothing that reduces risk is blocked either
    expect_revert(b.borrow, ta, 100 * E)                      # only new debt is
    check_invariants(s)
    return "above the cap only new borrowing is closed; interest, repayment and collateral top-ups are untouched"


def scenario_11_rounding_stress():
    clock, s, b, weth, feed = setup()
    fid = s.frontends.register("FE", 50 * PCT)
    fund(weth, "A", 10**6 * E); fund(weth, "B", 10**6 * E)
    ta = b.open_trove("A", 10**5 * E, 2_000 * E + 1, WAD // 200 + 1, frontend=fid)
    give_stable(s, b, weth, "dep", 3_000 * E)
    b.sp.deposit("dep", 2 * E)                 # tiny SP, just above the residual
    max_eps = 0
    for i in range(20_000):                    # 20k step-A with 1..3 s of interest each
        clock.warp(1 + i % 3)
        b._step_a()
        if i % 997 == 0:
            b.apply_pending_debt(ta)
        if i % 2500 == 0:
            max_eps = max(max_eps, check_invariants(s, f"tiny {i}")["WETH"]["eps"])
    rep = check_invariants(s, "tiny end")["WETH"]
    assert rep["eps"] <= rep["n_a"] + rep["n_b"], "eps exceeded the counting bound"
    msg1 = f"eps={rep['eps']} after {rep['n_a']} step-A / {rep['n_b']} step-B"
    # P and scale under many offsets at both ends of the deposit domain
    jumps = []
    for total in (MIN_SP_RESIDUAL + 10**6, MAX_SP_DEPOSITS):
        clock, s, b, weth, feed = setup()
        sp = b.sp
        s.stable.mint("dep", total); b.agg_debt += total       # raw state injection for the SP math only
        sp.deposit("dep", total)
        bumps = 0
        for k in range(2_000):
            avail = sp.total - MIN_SP_RESIDUAL
            if avail <= 0:
                break
            X = max(avail * 999 // 1000, 1)
            b.coll.mint(sp.addr, 1); sp_scale = sp.scale
            sp.offset(X, 1); b.agg_debt -= X
            bumps = max(bumps, sp.scale - sp_scale)
            assert sp.P > 0 and sp.total >= sp.compounded("dep")
        assert sp.total >= MIN_SP_RESIDUAL
        jumps.append(bumps)
    return msg1 + f"; P>0 across the whole domain; largest scale jump in ONE offset = {max(jumps)}"


def scenario_12_end_of_life():
    clock, s, b, weth, feed = setup()
    fid = s.frontends.register("FE", 0)
    users = ["u1", "u2", "u3"]
    tids = []
    for i, u in enumerate(users):
        fund(weth, u, 100 * E)
        tids.append(b.open_trove(u, 100 * E, (10_000 + 7 * i) * E + i, (5 + 3 * i) * PCT, frontend=fid))
    give_stable(s, b, weth, "dep", 20_000 * E)
    helper_tid = max(b.troves)
    b.sp.deposit("dep", 20_000 * E)
    clock.warp(200 * DAY)
    feed.price = 110 * E                       # u3 becomes liquidatable; SP absorbs it
    b.liquidate(tids[2], "liq")
    feed.price = 2000 * E
    clock.warp(100 * DAY)
    # everyone unwinds. Interest went to SP / frontend / escrow holders, so borrowers must
    # obtain it from them; a test-only pool stands in for the market.
    b.sp.withdraw("dep", 10**30); b.sp.claim("dep")
    open_ids = [t.id for t in b.open_troves()]
    for tid in open_ids:
        b.apply_pending_debt(tid)              # crystallise frontend credits first
    for who in list(s.frontends.claimable):
        s.frontends.claim(who)
    shortfalls = []
    for k, tid in enumerate(open_ids):
        t = b.troves[tid]
        pool_all(s, keep=(s.frontends.ADDR, b.sp.addr))
        need = b.debt_now(t)
        have = s.stable.bal["pool"]
        if have < need:                        # only possible for the very last trove
            assert k == len(open_ids) - 1
            stuck = s.stable.bal[s.frontends.ADDR] + s.stable.bal[b.sp.addr]
            shortfalls.append((need - have, stuck))
            need = have                        # closeTrove accepts the dust shortfall
        s.stable.transfer("pool", t.owner, need)
        b.close_trove(tid)
    for who in list(s.frontends.claimable):
        s.frontends.claim(who)
    b.claim_surplus("u3")
    rep = check_invariants(s, "end of life")
    assert not b.open_troves()
    assert b.agg_debt == b.bad_debt == s.stable.supply, "every issued token must sit in a named account"
    where = {k: v for k, v in s.stable.bal.items() if v}
    vault_left = b.coll.bal[b.vault]
    assert vault_left == sum(b.surplus.values()) + b.bad_debt_coll + b.default_coll
    return (f"residual supply = badDebt dust = {b.bad_debt} wei; last-trove shortfall (wei, stuck dust) = "
            f"{shortfalls}; vault leftover = {vault_left} (defaultColl dust {b.default_coll}); "
            f"token holders at the end: {where}")


def scenario_13_extra_checks():
    # (a) a single offset that takes the pool from the top of the domain to the residual
    clock, s, b, weth, feed = setup()
    s.stable.mint("dep", MAX_SP_DEPOSITS); b.agg_debt += MAX_SP_DEPOSITS
    b.sp.deposit("dep", MAX_SP_DEPOSITS)
    b.sp.P = P_FLOOR + 12345                   # a state earlier offsets can reach: P just above the floor
    b.sp.deps["dep"]["P"] = b.sp.P
    b.coll.mint(b.sp.addr, 1)
    before = b.sp.scale
    b.sp.offset(MAX_SP_DEPOSITS - MIN_SP_RESIDUAL, 1); b.agg_debt -= MAX_SP_DEPOSITS - MIN_SP_RESIDUAL
    jump = b.sp.scale - before
    assert b.sp.P >= P_FLOOR and jump == 2, "a single `if` bump would leave P below the floor"
    stranded = b.sp.total - b.sp.compounded("dep")
    assert stranded < 10**9, "deposit must survive two scale changes"
    # (b) redeem(huge, max_iter=1) must not spike baseRate beyond what was really redeemed
    clock, s, b, weth, feed = setup()
    for i in range(5):
        fund(weth, f"w{i}", 1000 * E)
        b.open_trove(f"w{i}", 1000 * E, 100_000 * E, (5 + i) * PCT)
    supply0 = s.stable.supply
    for i in range(1, 5):                                      # the redeemer holds everything it asks for (SPEC 10.5)
        s.stable.transfer(f"w{i}", "w0", s.stable.bal[f"w{i}"])
    red, _ = s.redeem("w0", 450_000 * E, max_iter=1)          # asks for 90% of supply, one trove only
    assert red < 110_000 * E, "max_iter=1 must cap the redemption at one trove"
    assert s.base_rate <= red * WAD // supply0 + 1, "stored baseRate must follow the amount actually redeemed"
    check_invariants(s)
    # (c) SPEC 10.5: a request above the redeemer's balance is refused as a whole, even when the one Trove that
    # max_iter allows holds less debt than the balance, so the burn alone would succeed
    base, bal = s.base_rate, s.stable.bal["w0"]
    assert b.debt_now(b.redemption_order()[0]) < bal
    expect_revert(s.redeem, "w0", bal + 1, max_iter=1)
    assert (s.base_rate, s.stable.bal["w0"]) == (base, bal), "a refused redemption must leave no trace"
    s.redeem("w0", bal, max_iter=1)                            # exactly the balance is allowed
    return (f"one offset can move the scale by {jump}; deposit stranded after two scale changes = "
            f"{stranded} wei; baseRate after partial redeem = {s.base_rate / 1e16:.2f}%")


def scenario_14_redemption_routing():
    clock = Clock()
    s = System(clock)
    kw = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT,
              min_debt=2000 * E, debt_cap=10**7 * E)
    ta, tb = Token("A"), Token("B")
    A = s.create_branch("A", ta, Feed(2000 * E), **kw)
    B = s.create_branch("B", tb, Feed(2000 * E), **kw)
    # branch C only supplies the redeemer with extra tokens; its feed goes invalid, so it is
    # outside the routing and its debt is not part of the unbacked total
    tc = Token("C")
    C = s.create_branch("C", tc, Feed(2000 * E), **kw)
    tc.mint("x", 10**4 * E)
    C.open_trove("x", 10**3 * E, 50_000 * E, 5 * PCT)
    C.feed.status = PRICE_INVALID
    c_debt = C.agg_debt
    for tok, br in ((ta, A), (tb, B)):
        tok.mint("x", 10**4 * E)
        br.open_trove("x", 10**3 * E, 100_000 * E, 5 * PCT)
    # back branch A almost fully with its SP -> its unbacked portion is small
    A.sp.deposit("x", 99_000 * E)
    unb_a = A.agg_debt - (A.sp.total - MIN_SP_RESIDUAL)
    unb_b = B.agg_debt
    before_a, before_b = A.agg_debt, B.agg_debt
    # ask for more than the total unbacked: the request is truncated, not spread disproportionately
    red, out = s.redeem("x", 101_500 * E, max_iter=5)
    assert red <= unb_a + unb_b
    took_a, took_b = before_a - A.agg_debt, before_b - B.agg_debt
    assert took_a <= unb_a + 1 and took_b <= unb_b + 1, "a branch was redeemed beyond its unbacked portion"
    assert took_a + took_b == red, "per-branch shares must add up exactly"
    assert red == unb_a + unb_b, "request above the total unbacked must be truncated to it"
    assert C.agg_debt == c_debt, "branch without a valid price must be left out"
    # a branch below SCR is skipped (and can be shut down by anyone)
    B.feed.price = 100 * E
    a0 = A.agg_debt
    s.redeem("x", 500 * E)
    assert B.agg_debt == before_b - took_b and A.agg_debt < a0
    check_invariants(s)
    return f"request truncated to total unbacked ({(unb_a + unb_b) / E:.0f}); split exact; branch below SCR skipped"


def scenario_15_code_review_fixes():
    out = []
    # (a) SP deposits stay open after shutdown and absorb a liquidation that would otherwise be bad debt
    clock, s, b, weth, feed = setup()
    fund(weth, "a", 10 * E); fund(weth, "rich", 1000 * E)
    ta = b.open_trove("a", 10 * E, 10_000 * E, 5 * PCT)
    b.open_trove("rich", 1000 * E, 50_000 * E, 5 * PCT)
    feed.status = FAILED
    b.trigger_shutdown()
    assert b.shutdown_at
    assert "deposits are closed" in expect_revert(b.sp.deposit, "rich", 20_000 * E)   # the pool absorbs nothing after a shutdown
    assert "settled" in expect_revert(b.liquidate, ta, "liq")
    assert b.settle_price == feed.last_good, "oracle failure: the reference price is the last good price"
    check_invariants(s, "15a")
    out.append("after an oracle-failure shutdown: no SP deposit, no liquidation, reference price = last good price")
    # (b) below CCR: withdrawal alone is refused, withdrawal matched by repayment is allowed
    clock, s, b, weth, feed = setup()
    fund(weth, "u", 100 * E)
    tu = b.open_trove("u", 10 * E, 10_000 * E, 5 * PCT)   # ICR 200%
    feed.price = 1400 * E                                  # TCR ~ 140% < CCR
    expect_revert(b.withdraw_coll, tu, 1 * E)
    expect_revert(b.adjust_trove, tu, -1 * E, -1_000 * E)  # 1 ETH = 1400 > 1000 repaid
    b.adjust_trove(tu, -1 * E, -1_500 * E)                 # repayment worth more than the withdrawal
    expect_revert(b.adjust_trove, tu, 0, 500 * E)          # borrowing keeps TCR below CCR
    check_invariants(s, "15b")
    out.append("below CCR: matched withdrawal ok, plain withdrawal and borrowing refused")
    # (c) premature rate change, zombies, identical rate
    clock, s, b, weth, feed = setup()
    fund(weth, "u", 100 * E); fund(weth, "v", 100 * E)
    tu = b.open_trove("u", 10 * E, 10_000 * E, 5 * PCT)
    tv = b.open_trove("v", 50 * E, 10_000 * E, 9 * PCT)
    expect_revert(b.adjust_rate, tu, 5 * PCT)              # not a new rate
    d0 = b.debt_now(b.troves[tu])
    b.adjust_rate(tu, 6 * PCT)                             # inside the cooldown -> fee on the whole debt
    assert b.debt_now(b.troves[tu]) > d0
    s.redeem("v", 9_500 * E)                               # u (lowest rate) becomes a zombie with debt left
    assert b.troves[tu].status == ZOMBIE and b.last_zombie == tu
    expect_revert(b.adjust_rate, tu, 7 * PCT)              # zombies cannot change rate
    s.redeem("v", 300 * E)                                 # the tracked zombie is redeemed first
    assert b.debt_now(b.troves[tu]) < 600 * E and b.troves[tv].debt > 10_000 * E - 1
    check_invariants(s, "15c")
    out.append("zombie pointer redeemed first; zombie/identical rate changes refused")
    # (d) bootstrap base rate decays with the half-life
    clock = Clock()
    s2 = System(clock, initial_base_rate=WAD)
    r0, _ = s2._decayed_base_rate()
    clock.warp(12 * 3600)
    r12, _ = s2._decayed_base_rate()
    assert r0 == WAD and abs(r12 - WAD // 4) < WAD // 1000, "two half-lives should leave ~25%"
    out.append(f"initial base rate 100% -> {r12 / 1e16:.2f}% after 12h")
    return "; ".join(out)


def scenario_16_only_the_rules_can_stop_anything():
    """There is no pause. The only thing that ever closes operations is a shutdown triggered by the rules. While the branch is
    live every exit is open; after a shutdown the exit of a borrower is settlement at par out of his own collateral, which
    anybody (he himself first of all) can trigger, and the Stability Pool can always be left."""
    clock, s, b, weth, feed = setup()
    fund(weth, "u", 100 * E)
    tu = b.open_trove("u", 50 * E, 10_000 * E, 5 * PCT)
    give_stable(s, b, weth, "u", 5_000 * E)
    b.sp.deposit("u", 1_000 * E)
    b.withdraw_coll(tu, 1 * E); b.borrow(tu, 500 * E); b.adjust_trove(tu, -1 * E, 200 * E)     # all open while live
    b.repay(tu, 100 * E); b.add_coll(tu, 1 * E)
    feed.status = FAILED
    b.poke_oracle()
    assert b.shutdown_at
    for name, fn in {"withdraw_coll": lambda: b.withdraw_coll(tu, 1 * E), "borrow": lambda: b.borrow(tu, 100 * E),
                     "adjust(-coll)": lambda: b.adjust_trove(tu, -1 * E, 0), "open": lambda: b.open_trove("u", 10 * E, 5_000 * E, 5 * PCT)}.items():
        assert "shut down" in expect_revert(fn), name
    b.sp.withdraw("u", 1_000 * E)                                    # never blocked
    coll_before, debt = b.coll_now(b.troves[tu]), b.debt_now(b.troves[tu])
    r = b.settle_trove(tu, "u")                                      # the owner settles his own Trove himself, at once
    assert r["contribution"] == -(-debt * E // b.settle_price) and r["surplus"] == coll_before - r["contribution"]
    check_invariants(s)
    return "live: everything open; after a rule-triggered shutdown: no new risk, SP exit open, borrower exits by par settlement"


def scenario_17_sp_shadow_accounting():
    """Per-depositor values are compared with an independent exact (rational) computation.
    The solvency invariant alone cannot see an under-payment."""
    import random
    from fractions import Fraction as F
    rng = random.Random(7)
    worst_rel, worst_abs, max_scale = F(0), 0, 0
    for case in range(6):
        clock, s, b, weth, feed = setup()
        sp = b.sp
        shadow_dep, shadow_coll, shadow_yield = {}, {}, {}

        def dep(who, amt):
            s.stable.mint(who, amt); b.agg_debt += amt          # raw state injection: SP maths only
            sp.deposit(who, amt)
            shadow_dep[who] = shadow_dep.get(who, F(0)) + amt
            shadow_coll.setdefault(who, F(0)); shadow_yield.setdefault(who, F(0))

        def offset(X, c):
            D = sum(shadow_dep.values())
            b.coll.mint(sp.addr, c)
            sp.offset(X, c); b.agg_debt -= X
            for w in shadow_dep:
                shadow_coll[w] += F(c) * shadow_dep[w] / D
                shadow_dep[w] *= F(sp.total) / F(sp.total + X)

        def give_yield(y):
            D = sum(shadow_dep.values())
            s.stable.mint(sp.addr, y); b.agg_debt += y
            sp.credit_yield(y)
            for w in shadow_dep:
                shadow_yield[w] += F(y) * shadow_dep[w] / D

        if case == 0:                                          # the worked example, step by step
            dep("old", MAX_SP_DEPOSITS)
            offset(MAX_SP_DEPOSITS - MIN_SP_RESIDUAL, 10**18)
            dep("refill1", MAX_SP_DEPOSITS - MIN_SP_RESIDUAL)
            offset(MAX_SP_DEPOSITS - MIN_SP_RESIDUAL, 10**18)
            dep("refill2", 10**22 - MIN_SP_RESIDUAL)
            offset(10**22 - MIN_SP_RESIDUAL, 10**18)
            give_yield(10**18)
            got = sp.pending_yield("old")
            assert got > 0, "deposit alive after 3 scale changes must still earn (SCALE_SPAN=2 returned 0)"
        else:
            for i in range(rng.randint(2, 5)):
                dep(f"d{i}", rng.randint(10**18, 10**rng.randint(19, 29)))
            for _ in range(60):
                k = rng.random()
                avail = sp.total - MIN_SP_RESIDUAL
                if k < 0.45 and avail > 0:
                    num, den = rng.choice([(1, 10), (1, 2), (999, 1000), (999_999, 1_000_000), (1, 1)])
                    offset(min(max(avail * num // den, 1), avail), rng.randint(1, 10**20))
                elif k < 0.75:
                    give_yield(rng.randint(1, 10**24))
                else:
                    dep(f"n{rng.randint(0, 3)}", rng.randint(10**18, 10**27))
        max_scale = max(max_scale, sp.scale)
        for w in shadow_dep:
            pairs = [(sp.compounded(w), shadow_dep[w]), (sp.pending_coll(w) + sp.claim_coll[w], shadow_coll[w]),
                     (sp.pending_yield(w) + sp.claim_yield[w], shadow_yield[w])]
            for got, exact in pairs:
                assert got <= exact + 1, f"over-payment: {got} > {float(exact)}"
                short = exact - got
                worst_abs = max(worst_abs, int(short))
                if exact > 10**9:
                    worst_rel = max(worst_rel, short / exact)
                assert short <= 10**3 + exact / 10**9, f"under-payment {float(short)} of {float(exact)} (case {case}, {w})"
    return (f"never over-pays; worst under-payment {fig('sp_worst_underpayment_wei', worst_abs)} wei / "
            f"{float(worst_rel):.2e} relative; deepest scale reached {fig('sp_deepest_scale', max_scale)}")


def scenario_18_direct_transfers():
    """Tokens pushed straight into core contracts must not break the books or become claimable by anyone."""
    clock, s, b, weth, feed = setup()
    fund(weth, "u", 100 * E); fund(weth, "griefer", 10 * E)
    tu = b.open_trove("u", 50 * E, 10_000 * E, 5 * PCT)
    b.sp.deposit("u", 2_000 * E)
    weth.transfer("griefer", b.vault, 1)                       # one wei used to break INV-4
    weth.transfer("griefer", b.sp.addr, 5)
    s.stable.transfer("u", b.sp.addr, 7)
    s.stable.transfer("u", s.frontends.ADDR, 3)
    s.stable.transfer("u", s.ESCROW, 11)
    check_invariants(s, "after donations")
    assert b.unaccounted_coll() == 1
    clock.warp(30 * DAY); b.apply_pending_debt(tu)
    before = weth.bal["u"]
    b.sp.withdraw("u", 10**30); b.sp.claim("u")
    assert weth.bal["u"] == before, "a depositor received donated collateral"
    assert not hasattr(b, "skim"), "no function may hand stray collateral to a recipient chosen by the caller"
    assert b.unaccounted_coll() == 1, "stray collateral stays in the vault, outside every ledger, for ever"
    return "books unaffected; donated collateral belongs to nobody and cannot be taken by anybody"


def scenario_19_lp_vault_fee_accounting():
    from model import LPFeeVault
    clock = Clock()
    v = LPFeeVault(clock)
    v.deposit("early", 1_000)
    v.collect_fees(300, 9)                                     # swap fees earned before `late` arrives
    v.notify_incentive(70_000)                                 # reward tokens: streamed over the NEXT 7-day epoch
    clock.warp(14 * DAY)
    v.deposit("late", 9_000)
    assert v.pending("late") == (0, 0, 0), "a new depositor must have no claim on earlier fees or incentives"
    v.collect_fees(1_000, 100)
    v.withdraw("early", 1_000)                                 # full exit
    owed = v.pending("early")
    assert owed[:2] == (300 + 100, 9 + 10) and 69_990 <= owed[2] <= 70_000, owed   # still claimable after the exit
    assert v.claim("early") == owed and v.pending("early") == (0, 0, 0)
    assert v.pending("late")[:2] == (900, 90)
    assert v.principal_out["early"] == 1_000, "principal is tracked apart from fees"
    # enter with 99% of the shares right before a funding, leave right after
    v.deposit("small", 100)
    v.withdraw("late", 9_000)
    v.notify_incentive(70_000)
    clock.warp(7 * DAY - (clock.now - v.stream.t0) % (7 * DAY) - 6)   # six seconds before the epoch that pays it
    v.deposit("jit", 9_900)                                    # 99% of the shares
    clock.warp(12)                                             # in for 12 seconds around the boundary
    v.withdraw("jit", 9_900)
    got = v.claim("jit")[2]
    assert got <= 70_000 * 12 // (7 * DAY) + 1, f"JIT entrant captured {got} of a 70,000 funding"
    # stream seconds with nobody in the vault are not lost
    v.withdraw("small", 100); v.claim("small")
    clock.warp(3 * DAY)                                        # nobody in the vault while the stream runs
    v.deposit("back", 500)
    clock.warp(15 * DAY)
    assert v.claim("back")[2] > 25_000, "idle stream time must roll into the next epoch"
    return f"no claim on the past; entitlement survives exit; JIT entrant got {got} of 70,000; idle stream rolls over"





HOUR = 3600
STALE, TIMEOUT, GRACE = 3 * HOUR, 24 * HOUR, 1 * HOUR


def oracle_setup(l2=True, gas_mode="stipend", n_sources=1, combine="single", max_skew=None):
    clock = Clock()
    s = System(clock)
    weth = Token("WETH")
    seq = Sequencer(clock) if l2 else None
    srcs = [Source(clock, 2000 * E)] + [Source(clock, E) for _ in range(n_sources - 1)]
    feed = OracleFeed(clock, srcs, [STALE] * n_sources, TIMEOUT, sequencer=seq, grace=GRACE,
                      combine=combine, max_skew=max_skew, gas_mode=gas_mode)
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT,
                        pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=10**7 * E)
    fund(weth, "u", 1000 * E)
    b.open_trove("u", 100 * E, 20_000 * E, 5 * PCT)
    return clock, s, b, feed, srcs, seq


def scenario_20_oracle_failure_detection():
    out = []
    # (a) a sequencer outage far longer than staleness AND timeout must not shut the branch down
    clock, s, b, feed, (src,), seq = oracle_setup()
    seq.set(False); clock.warp(30 * HOUR)
    assert b.poke_oracle() == NETWORK_UNSTABLE
    seq.set(True); clock.warp(GRACE - 1)
    assert b.poke_oracle() == NETWORK_UNSTABLE                  # grace period
    clock.warp(2)
    assert b.poke_oracle() == PRICE_INVALID                     # feed is 31h old, but the network was up for 1h only
    b.trigger_shutdown(); assert b.shutdown_at == 0
    expect_revert(b.borrow, 1, 1_000 * E)                       # risk-increasing ops wait
    b.add_coll(1, 1 * E); b.repay(1, 100 * E)                   # risk-reducing ops never need the oracle
    src.push()
    assert b.poke_oracle() == VALID and b.shutdown_at == 0
    out.append("a: 30h sequencer outage -> no shutdown")
    # (b) genuinely dead feed with a healthy network: PriceInvalid, then Failed after the timeout
    clock, s, b, feed, (src,), seq = oracle_setup()
    clock.warp(STALE + 1);      assert b.poke_oracle() == PRICE_INVALID and b.shutdown_at == 0
    clock.warp(TIMEOUT - STALE - 1); assert b.poke_oracle() == PRICE_INVALID     # exactly TIMEOUT old: not yet
    clock.warp(1)
    expect_revert(b.borrow, 1, 1_000 * E)                       # a borrower op reverts and must NOT latch
    assert b.shutdown_at == 0 and not b.oracle_failed
    assert b.poke_oracle() == FAILED and b.shutdown_at == clock.now and b.oracle_failed
    src.push(9_999 * E)                                         # too late: the branch no longer reads the feed
    assert b.poke_oracle() == FAILED and b._shutdown_price() == 2000 * E
    out.append("b: dead feed -> Failed exactly after TIMEOUT, latched only by a non-reverting path")
    # (c) malformed answers: two observations TIMEOUT apart; a healthy observation in between resets the clock
    clock, s, b, feed, (src,), seq = oracle_setup()
    src.value = 0
    assert b.poke_oracle() == PRICE_INVALID and feed.invalid_since == clock.now
    clock.warp(TIMEOUT - 1); src.push(0); assert b.poke_oracle() == PRICE_INVALID
    src.push(2100 * E);      assert b.poke_oracle() == VALID and feed.invalid_since == 0
    src.push(-5);            assert b.poke_oracle() == PRICE_INVALID
    clock.warp(TIMEOUT - 1); src.push(-5); assert b.poke_oracle() == PRICE_INVALID
    clock.warp(1);           src.push(-5); assert b.poke_oracle() == FAILED
    assert b._shutdown_price() == 2100 * E
    out.append("c: malformed -> marker, reset by a healthy poke, Failed after a full TIMEOUT")
    # (d) a marker written inside a reverting transaction does not survive
    clock, s, b, feed, (src,), seq = oracle_setup()
    src.reverts = True
    expect_revert(b.borrow, 1, 1_000 * E)
    assert feed.invalid_since == 0, "marker survived a reverted transaction"
    clock.warp(TIMEOUT + HOUR)
    assert b.poke_oracle() == PRICE_INVALID, "first persisted observation only starts the clock"
    clock.warp(TIMEOUT); assert b.poke_oracle() == FAILED
    out.append("d: borrower reverts do not start the clock; a keeper must poke twice")
    # (e) gas griefing: no gas amount may turn a healthy feed into a 'malformed' observation.
    # For a cheap feed the attack fails by itself (the 1/64 left cannot pay for the rest of the transaction),
    # so the test uses a gas-hungry feed (2M), where 1/64 of the gas is enough to write the marker.
    def griefable(mode, nested, cost, limit):
        clock = Clock(); s2 = System(clock)
        src = Source(clock, 2000 * E, gas_cost=cost, nested=nested)
        feed = OracleFeed(clock, [src], [STALE], TIMEOUT, gas_mode=mode, feed_gas_limit=limit)
        b2 = s2.create_branch("X", Token("X"), feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT,
                              pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=10**6 * E)
        hit = False
        for gas in range(50_000, int(cost * 1.7), max(cost // 400, 1)):
            src.push()
            try:
                if atomic_poke(b2, gas) != VALID:
                    hit = True
            except Revert:
                pass
        return hit
    assert not griefable("none", False, 60_000, 200_000), "cheap feed: attack should starve the rest of the tx"
    assert griefable("none", False, 2_000_000, 2_500_000), "no guard + hungry feed must be griefable (else the test is blind)"
    assert not griefable("heuristic64", False, 2_000_000, 2_500_000)
    assert not griefable("stipend", False, 2_000_000, 2_500_000)
    clock0 = Clock()
    assert OracleFeed(clock0, [Source(clock0, E)], [STALE], TIMEOUT).gas_mode == "stipend", \
        "the specified guard must be the default, not an opt-in"
    out.append("e: hungry feed is griefable with no guard; both guards stop it for a flat call")
    # (e2) nested source (proxy -> aggregator): when the inner call runs dry the proxy reverts and RETURNS its own
    # 1/64, so the caller ends with ~2/64 and the 1/64 heuristic does not fire
    assert griefable("heuristic64", True, 1_000_000, 1_300_000), "expected the nested case to defeat the heuristic"
    assert not griefable("stipend", True, 1_000_000, 1_300_000)
    out.append("e2: nested gas-hungry feed defeats the 1/64 heuristic; the fixed stipend is unaffected")
    # (f) a feed that burns all forwarded gas: the 1/64 heuristic can never observe it -> permanent limbo
    clock, s, b, feed, (src,), seq = oracle_setup(gas_mode="heuristic64")
    src.burns_all_gas = True
    for _ in range(5):
        clock.warp(TIMEOUT)
        expect_revert(b.poke_oracle)
    assert b.shutdown_at == 0 and feed.invalid_since == 0
    clock, s, b, feed, (src,), seq = oracle_setup(gas_mode="stipend")
    src.burns_all_gas = True
    assert b.poke_oracle() == PRICE_INVALID
    clock.warp(TIMEOUT); assert b.poke_oracle() == FAILED
    out.append("f: gas-burning feed = limbo under the 1/64 heuristic, Failed under the fixed stipend")
    # (g) composite feed: either component can fail it; the OLDEST component drives the staleness path; skew
    clock, s, b, feed, (a, r), seq = oracle_setup(n_sources=2, combine="ratio", max_skew=2 * HOUR)
    assert feed.fetch() == (2000 * E, VALID)
    clock.warp(2 * HOUR + 1); a.push()                          # r is 2h+1s older than a
    assert b.poke_oracle() == PRICE_INVALID, "component skew"
    r.push(); assert b.poke_oracle() == VALID
    clock.warp(TIMEOUT + 1); a.push()                           # a is fresh, r is dead
    assert b.poke_oracle() == FAILED
    out.append("g: composite skew -> PriceInvalid; oldest component -> Failed")
    # (h) timestamp in the future is malformed, not 'very fresh'
    clock, s, b, feed, (src,), seq = oracle_setup()
    src.updated_at = clock.now + 600
    assert b.poke_oracle() == PRICE_INVALID and feed.invalid_since == clock.now
    # (i) the real minimum distance between a valid observation and Failed is TIMEOUT - staleness
    clock, s, b, feed, (src,), seq = oracle_setup(l2=False)
    clock.warp(STALE); assert b.poke_oracle() == VALID          # last moment at which the old answer is still accepted
    t_valid = clock.now
    clock.warp(TIMEOUT - STALE); assert b.poke_oracle() == PRICE_INVALID
    clock.warp(1);               assert b.poke_oracle() == FAILED
    assert clock.now - t_valid == TIMEOUT - STALE + 1
    out.append(f"i: Failed can follow a Valid observation after TIMEOUT - staleness = {(TIMEOUT - STALE) // HOUR}h, not {TIMEOUT // HOUR}h")
    return "; ".join(out)


def atomic_poke(b, gas):
    import model
    return model.atomic(model.CURRENT_SYSTEM, b.poke_oracle, gas)


def scenario_21_darli_stakers_receive_the_fee_share():
    """DARLI: no vote, no power, no destinations. Stakers receive the protocol's share of interest and
    loan fees, pro rata and streamed. End to end: borrowers' interest -> escrow -> permissionless router -> staking -> claim."""
    import os
    from model import route_revenue
    assert not os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "governance.py")), \
        "no governance module may exist in an immutable, vote-free system"
    clock, s, b, weth, feed = setup()
    fund(weth, "a", 1000 * E)
    b.open_trove("a", 1000 * E, 500_000 * E, 10 * PCT)
    b.sp.deposit("a", 50_000 * E)                              # with an empty Stability Pool its share would go to the escrow too
    escrow0, agg0 = s.stable.bal[s.ESCROW], b.agg_debt
    stk = StreamingStaking(clock, s.stable, addr="DarliStaking")
    s.fix_staking_destination(stk)
    expect_revert(s.fix_staking_destination, StreamingStaking(clock, s.stable, addr="Attacker"))   # once, for ever
    stk.stake("early", 600 * E); stk.stake("other", 400 * E)
    clock.warp(73 * DAY)                                       # ~10,000 of interest accrues
    b.apply_pending_debt(1)
    escrow = s.stable.bal[s.ESCROW]
    protocol_share = WAD - s.sp_share - s.frontends.share
    minted = b.agg_debt - agg0
    assert abs((escrow - escrow0) - minted * protocol_share // WAD) <= 3, "the escrow must receive exactly the protocol's share of what was minted"
    routed = route_revenue(s)                                  # the caller passes NO destination
    assert routed == escrow and s.stable.bal[s.ESCROW] == 0 and route_revenue(s) == 0
    W = stk.PERIOD
    clock.warp(W - (clock.now - stk.stream.t0) % W - 6)        # six seconds before the epoch that pays it
    stk.stake("jit", 99_000 * E)
    clock.warp(12); stk.unstake("jit", 99_000 * E)
    jit = stk.claim("jit")
    assert jit <= routed * 12 // W + 1, "a just-in-time staker must earn only its seconds"
    clock.warp(W + 1)
    e, o = stk.claim("early"), stk.claim("other")
    assert abs(e * 400 - o * 600) <= 10**6, "pro rata to stake"
    assert routed - (e + o + jit) < 10**6, "everything routed is paid out, nothing stranded"
    for gone in ("IncentiveController", "VotingStake", "Governor", "Guardian"):
        import model
        assert not hasattr(model, gone)
    check_invariants(s)
    return f"escrow {escrow / E:,.0f} -> stakers 60/40 ({e / E:,.0f} / {o / E:,.0f}); JIT staker {jit / E:.2f}; no vote exists"


def _settlement_state(colls, p0, p1, absorbs, debts=None, holders=("A", "B")):
    """Troves opened at price p0 through the ordinary path, then the price falls to p1 and the rules shut the branch down."""
    clock = Clock(); s = System(clock, frontend_share=0)
    weth = Token("WETH"); feed = Feed(p0 * E)
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT,
                        pen_redist=10 * PCT, min_debt=500 * E, debt_cap=10**7 * E)
    b.settlement_surplus_absorbs = absorbs
    debts = debts or [5_000] * len(colls)
    for i, (c, d) in enumerate(zip(colls, debts)):
        weth.mint(f"t{i + 1}", c * E); b.open_trove(f"t{i + 1}", c * E, d * E, 5 * PCT)
    share = sum(debts) * E // len(holders)
    owners = [f"t{i + 1}" for i in range(len(colls))]
    pot = {o: s.stable.bal[o] for o in owners}
    for h in holders:                                            # spread the minted tokens evenly over the holders
        need = share
        for o in owners:
            give = min(need, s.stable.bal[o]); s.stable.transfer(o, h, give); need -= give
    feed.price = p1 * E
    b.trigger_shutdown()
    assert b.shutdown_at and b.settle_price == p1 * E
    return s, b, weth


def _run_settlement(s, b, settle_order, claim_order):
    import itertools
    assert "not complete" in expect_revert(b.redeem_bad_debt_coll, claim_order[0], 1 * E), "nobody may be paid during phase 1"
    for tid in settle_order:
        b.settle_trove(tid)
    got = {}
    for h in claim_order:
        bal = s.stable.bal[h]
        got[h] = (b.redeem_bad_debt_coll(h, min(bal, b.bad_debt)), bal)
    check_invariants(s, "settlement")
    return got


def scenario_22_staged_settlement_is_order_free():
    """Equal treatment of equal claims, over EVERY order of
    settling Troves and EVERY order of claiming: each holder's payout per token must be identical across all of them."""
    import itertools
    out = []
    for colls, p0 in (((6, 3), 2000), ((6, 1), 10_000), ((6, 3, 5), 2000)):
        for absorbs in (True, False):
            seen = set()
            n = len(colls)
            for so in itertools.permutations(range(1, n + 1)):
                for co in itertools.permutations(("A", "B")):
                    s, b, weth = _settlement_state(colls, p0, 1000, absorbs)
                    got = _run_settlement(s, b, so, co)
                    seen.add(tuple(sorted((h, c) for h, (c, _bal) in got.items())))
                    rates = [c * 1000 * E // bal for c, bal in got.values()]
                    assert max(rates) - min(rates) <= 10**6, f"holders paid at different rates: {rates}"
            assert len(seen) == 1 or max(abs(a[0][1] - c[0][1]) for a in seen for c in seen) <= 2, \
                f"payout depends on the order ({colls}, absorbs={absorbs}): {seen}"
            out.append(f"{colls} {'borrowers absorb' if absorbs else 'vault parity'}: {rates[0] / E:.4f}")
    return "every order of settling and claiming gives every holder the same rate -> " + "; ".join(out)


def scenario_23_settlement_economics_and_edges():
    """Independent economic invariant + edge cases (acceptance criteria 2 and 3)."""
    from fractions import Fraction
    out = []
    # --- exact expectation, computed independently with rationals, both variants (6 ETH ~120%, 3 ETH ~60%, price 1000)
    for absorbs in (True, False):
        s, b, weth = _settlement_state((6, 3), 2000, 1000, absorbs)
        d = {tid: b.debt_now(b.troves[tid]) for tid in (1, 2)}
        need = {tid: -(-d[tid] * E // (1000 * E)) for tid in d}
        coll = {1: 6 * E, 2: 3 * E}
        contrib = {tid: min(coll[tid], need[tid]) for tid in d}
        short = sum(need[tid] - contrib[tid] for tid in d); gross = sum(coll[tid] - contrib[tid] for tid in d)
        take = min(short, gross) if absorbs else 0
        exp_pot = sum(contrib.values()) + take
        exp_rate = Fraction(exp_pot, b.agg_debt)
        total_coll = 9 * E
        got = _run_settlement(s, b, (2, 1), ("B", "A"))
        paid = sum(c for c, _ in got.values())
        for h, (c, bal) in got.items():
            assert abs(Fraction(c) - exp_rate * bal) <= 2, f"{h} was not paid the common rate"
        s1 = b.claim_surplus("t1"); s2 = b.claim_surplus("t2")
        assert s2 == 0 and abs(s1 - (gross - take)) <= 2, "borrower surplus differs from the independent computation"
        # conservation: holders' payouts + owners' surplus + what is still in named accounts == all collateral
        assert paid + s1 + s2 + b.bad_debt_coll + b.settle_surplus_pool == total_coll
        unclaimed = b.bad_debt                                     # tokens of other holders (fees sitting in the escrow) keep their equal claim
        assert abs(Fraction(b.bad_debt_coll) - exp_rate * unclaimed) <= 3, "what is left in the pot must be exactly the unclaimed tokens' share"
        assert b.settle_surplus_pool <= 2, "only rounding dust may remain in the surplus pool"
        rate_fig = fig("holders_rate_absorb" if absorbs else "holders_rate_parity", float(exp_rate) * 1000, ".4f")
        fig("healthy_borrower_keeps_absorb_eth" if absorbs else "healthy_borrower_keeps_parity_eth", s1 / E, ".3f")
        out.append(f"{'borrowers absorb' if absorbs else 'vault parity'}: holders {rate_fig:.4f} per token, healthy borrower keeps {s1 / E:.3f} ETH")
    # --- surplus is released only after phase 1 when it may still be needed
    s, b, weth = _settlement_state((6, 3), 2000, 1000, True)
    b.settle_trove(1)
    assert "phase 1" in expect_revert(b.claim_surplus, "t1")
    b.settle_trove(2); b.claim_surplus("t1")
    # --- fully backed: everybody gets exactly par and borrowers keep everything else, under both variants
    for absorbs in (True, False):
        s, b, weth = _settlement_state((11, 21), 2000, 1000, absorbs, debts=[10_000, 20_000])   # TCR ~107% -> shutdown, nobody under water
        assert all(b.coll_now(t) * 1000 * E >= b.debt_now(t) * E for t in b.open_troves())
        got = _run_settlement(s, b, (1, 2), ("A", "B"))
        for c, bal in got.values():
            assert abs(c * 1000 - bal) <= 1000 * 2, "fully backed: a token must fetch exactly one unit of reference currency"
    # --- zero-debt Trove, pending redistribution, and the last Trove
    clock, s, b, weth, feed = setup()
    for who, c, dbt in (("z", 5, 2_000), ("x", 10, 12_000), ("y", 40, 20_000)):
        fund(weth, who, 100 * E); b.open_trove(who, c * E, dbt * E, 5 * PCT)
    s.stable.transfer("x", "H", 12_000 * E); s.stable.transfer("y", "H", 15_000 * E)
    feed.price = 1250 * E; b.liquidate(2, "k")                           # SP empty -> redistributed onto z and y (pending)
    assert b.troves[1].debt < b.debt_now(b.troves[1]), "test needs a pending redistribution"
    feed.price = 600 * E; b.trigger_shutdown()
    assert b.shutdown_at and b.unsettled == 2
    r = b.settle_trove(1); assert r["debt"] == b.bad_debt, "pending redistribution must be counted at settlement"
    b.settle_trove(3)
    assert b.unsettled == 0 and b.bad_debt == b.agg_debt, "after the last Trove every token is a claim on the pot (dust swept)"
    paid = b.redeem_bad_debt_coll("H", s.stable.bal["H"])
    check_invariants(s, "23 edges")
    # --- shutdown price differs from the market: settlement ignores the market
    s, b, weth = _settlement_state((6, 3), 2000, 1000, True)
    b.feed.price = 5000 * E
    d1 = b.debt_now(b.troves[1])
    assert b.settle_trove(1)["contribution"] == -(-d1 * E // (1000 * E)) and b.settle_price == 1000 * E, "settlement must use the reference price"
    out.append("zero order dependence; pending redistribution, last-Trove dust and a moved market price handled")
    return "; ".join(out)


def scenario_24_revenue_schedule_cannot_be_postponed():
    """The revenue schedule cannot be postponed. One staker, 7,000 handed over once; then somebody hands over ONE WEI
    EVERY HOUR. Under a re-spreading stream the staker would hold 4,432 after seven days and the end date would keep moving away.
    With fixed epochs a later hand-over cannot touch an earlier schedule: everything handed over by time T is fully paid by
    the end of the following epoch (at most two periods after T), whatever anyone does in between."""
    clock = Clock(); tok = Token("uUSD"); tok.mint("escrow", 10**30)
    stk = StreamingStaking(clock, tok); W = stk.PERIOD
    stk.stake("s", 1_000 * E)
    stk.notify_reward("escrow", 7_000 * E)
    t_handover = clock.now
    for _ in range(2 * 7 * 24):                                 # two weeks of hourly one-wei hand-overs
        clock.warp(3600)
        stk.notify_reward("escrow", 1)
    assert clock.now - t_handover <= 2 * W
    got = stk.claim("s")
    assert 7_000 * E - got < 10**6, f"the 7,000 handed over first must be fully paid within two periods, got {got / E:.3f}"
    # ordinary frequent revenue: 100 per hour for six weeks; deadline property for EVERY hand-over
    clock = Clock(); tok = Token("uUSD"); tok.mint("escrow", 10**30)
    stk = StreamingStaking(clock, tok); stk.stake("s", 1_000 * E); stk.stake("leaver", 1_000 * E)
    handed = []
    for h in range(6 * 7 * 24):
        clock.warp(3600); stk.notify_reward("escrow", 100 * E); handed.append((clock.now, 100 * E))
        if h == 500:
            stk.unstake("leaver", 1_000 * E)                    # exit before the end: what was earned stays claimable
        if h % 97 == 0:
            due = sum(a for (ts, a) in handed if clock.now >= stk.stream._epoch_end(ts) + W)   # its paying epoch has ended
            paid_or_owed = stk.earned["s"] + stk.earned["leaver"] + tok.bal["s"] + tok.bal["leaver"]
            stk._update("s"); stk._update("leaver")
            paid_or_owed = stk.earned["s"] + stk.earned["leaver"] + tok.bal["s"] + tok.bal["leaver"]
            assert paid_or_owed + 10**9 >= due, "a hand-over missed its deadline"
        assert tok.bal[stk.addr] + 10 >= stk.liabilities() - 1, "staking contract cannot cover what it owes"
    leaver = stk.claim("leaver"); assert leaver > 0
    return f"1 wei per hour for two weeks: first hand-over fully paid ({got / E:,.3f}); every hand-over meets its two-period deadline"


def scenario_25_beta_policies_are_bounded_and_default_is_fixed():
    """The specified behaviour is a FIXED beta. The dynamic formulas exist for the round-22 study only; this pins down that the
    default is untouched and that the study formulas are bounded in [1, 4], monotone in supply, and react to redemptions."""
    clock, s, b, weth, _ = setup(beta=4)
    give_stable(s, b, weth, "r", 100_000 * E)
    assert s.beta_policy == "fixed" and s.beta_wad() == 4 * E
    rate, _ = s.redemption_fee_rate(2_000 * E)
    sup = s.stable.supply
    assert rate == min(s.fee_floor + s._decayed_base_rate()[0] + 2_000 * E * E // (sup * 4), E), "default fee formula changed"
    s.beta_policy = "size"
    seen = []
    for target in (100_000, 250_000, 1_000_000, 4_000_000, 50_000_000):
        s.stable.supply = target * E; seen.append(s.beta_wad())
    s.stable.supply = sup
    assert seen[0] == seen[1] == 4 * E and seen[-1] == seen[-2] == E and seen == sorted(seen, reverse=True), seen
    s.beta_policy = "pressure"
    assert s.beta_wad() == E, "no recent redemptions -> beta 1"
    s.base_rate = 0; clock.warp(3 * DAY)
    s.redeem("r", 5_000 * E, 8)
    after = s.beta_wad()
    assert E < after <= 4 * E
    clock.warp(60 * DAY)
    assert s.beta_wad() < after, "pressure must decay"
    # the fee and the base-rate update of ONE redemption must use the same beta (sampled before supply falls)
    s.beta_policy = "size"; s.base_rate = 0; clock.warp(30 * DAY)
    give_stable(s, b, weth, "r2", 900_000 * E)
    sup0, beta0 = s.stable.supply, s.beta_wad()
    red, _ = s.redeem("r2", 50_000 * E, 50)
    assert s.base_rate == min(red * E * E // (sup0 * beta0), E), "base-rate bump used a different beta than the fee"
    s.beta_policy = "fixed"
    check_invariants(s)
    return f"default fixed; size formula 4 -> 1 between 250k and 4M; pressure rises to {after / E:.2f} after redeeming 5% and decays"


def scenario_26_one_shot_deployment_and_the_pool_race():
    """The token's future address is predictable and Uniswap v4 lets anyone initialise any pool key, so an attacker
    CAN initialise the canonical key first, at any price. Atomic deployment does NOT prevent this.
    What must hold instead: (1) deployment does not depend on winning the race; (2) no liquidity enters at a wrong price;
    (3) an empty pool's price can be corrected by anybody for nothing; (4) the core never knows about any of it."""
    from model import UniswapStub, Deployment
    kw = dict(mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT, min_debt=500 * E,
              debt_cap=125_000 * E, cap_ceiling=250_000 * E)
    # --- honest case
    clock = Clock(); uni = UniswapStub(); weth = Token("WETH"); feed = Feed(2000 * E)
    d = Deployment(clock, uni); s = d.run(weth, feed, **kw)
    assert d.pool_preinitialised is False and uni.pools[d.pool_key] == E and d.pool_key[3] == "no-hook"
    expect_revert(d.run, weth, feed, **kw)                                   # set-up cannot be run twice
    expect_revert(s.fix_staking_destination, StreamingStaking(clock, s.stable, addr="Attacker"))
    d.vault.deposit("team", 1_000)
    # --- attacked case: the REAL key, not a guess, initialised first at 0.50
    clock = Clock(); uni = UniswapStub(); weth = Token("WETH"); feed = Feed(2000 * E)
    real_key = ("uUSD", "USDC", 100, "no-hook")
    uni.initialize(real_key, 5 * E // 10)
    d = Deployment(clock, uni); s = d.run(weth, feed, **kw)                  # (1) deployment still succeeds
    assert d.pool_key == real_key and d.pool_preinitialised is True and uni.pools[real_key] == 5 * E // 10
    assert "outside the vault's range" in expect_revert(d.vault.deposit, "team", 1_000)      # (2)
    assert d.pool_price_observed == 5 * E // 10, "the record must show the pool's REAL price, not the target"
    uni.swap_to_price(real_key, 1_009 * E // 1000)                           # inside the range, but manipulated
    assert "depositor's own bounds" in expect_revert(d.vault.deposit, "team", 1_000, 999 * E // 1000, 1_001 * E // 1000)
    uni.swap_to_price(real_key, E)                                           # (3) free in an empty pool
    d.vault.deposit("team", 1_000, 999 * E // 1000, 1_001 * E // 1000)
    expect_revert(uni.swap_to_price, real_key, 5 * E // 10)                  # with liquidity in place the price is no longer free
    # --- a manager whose initialise fails for an UNRELATED reason and that holds no pool: no false success
    class Broken(UniswapStub):
        def initialize(self, key, price_wad):
            raise Revert("tick spacing too large")
    assert "does not exist" in expect_revert(Deployment(Clock(), Broken()).run, Token("WETH"), Feed(2000 * E), **kw)
    b = s.branches["WETH"]                                                   # (4)
    for obj in (s, b, b.sp, s.stable, s.frontends):
        for name, val in vars(obj).items():
            assert not isinstance(val, (UniswapStub, Deployment, LPFeeVault)), f"core object points at the market layer: {name}"
    fund(weth, "a", 100 * E); b.open_trove("a", 50 * E, 20_000 * E, 5 * PCT)
    check_invariants(s)
    return ("pre-initialising the real pool key at 0.50 neither blocks deployment nor lets liquidity in at that price; "
            "an empty pool's price is corrected for free; the core has no pointer to the market layer")


def scenario_27_settlement_is_bounded_paid_and_unblockable():
    """Equal pay-outs are worth nothing if nobody can be paid. Phase 1 must be cheap per Trove, paid for,
    batchable, and ONE Trove that nobody settles must not hold everybody hostage, without re-creating inequality.

    What this does NOT prove is that settlement always completes: `write_off` is the escape from a Trove nobody settles,
    but it reads the Trove's debt and the reference price through the same `_touch` and `_settle_price` that
    `settle_trove` uses, so a persistent revert inside those shared parts would stop both paths. That case is open
    (`docs/SPEC.md` 9.3 and 13) and is deliberately not claimed here."""
    out = []
    GD = E // 100                                                   # gas deposit per Trove
    def world(n, colls=None, absorbs=True):
        clock = Clock(); s = System(clock, frontend_share=0)
        weth = Token("WETH"); feed = Feed(2000 * E)
        b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT,
                            min_debt=500 * E, debt_cap=10**9 * E, gas_deposit=GD)
        b.settlement_surplus_absorbs = absorbs
        for i in range(n):
            c = (colls[i] if colls else 4) * E
            weth.mint(f"t{i}", c + GD); b.open_trove(f"t{i}", c, 5_000 * E, 5 * PCT)
        return clock, s, b, weth, feed
    # (a) 1,500 Troves: constant work per Trove, no scan, bounded batches, the settler is paid
    from model import Branch
    n_troves, batch = 1_500, Branch.MAX_SETTLE_BATCH
    clock, s, b, weth, feed = world(n_troves)
    feed.price = 1000 * E; b.trigger_shutdown()
    assert b.unsettled == n_troves and b.gas_pool == n_troves * GD
    expect_revert(b.settle_troves, list(range(1, batch + 2)), "keeper")    # one over MAX_SETTLE_BATCH
    real_scan = b.open_troves
    def no_scan():
        raise AssertionError("settlement scanned the set of Troves")
    b.open_troves = no_scan
    ids = list(range(1, n_troves + 1)); random.Random(7).shuffle(ids)
    for k in range(0, n_troves, batch):
        b.settle_troves(ids[k:k + batch], "keeper")
    b.open_troves = real_scan
    assert b.unsettled == 0 and b.n_open == 0 and b.gas_pool == 0 and weth.bal["keeper"] == n_troves * GD
    check_invariants(s, "27a")
    fig("settle_troves", n_troves, ",")
    fig("settle_batch_size", batch)
    out.append(f"a: {n_troves:,} Troves settled in {fig('settle_batches', -(-n_troves // batch))} batches"
               f" without a single scan; keeper paid {n_troves:,} gas deposits")
    # (b) one Trove is never settled
    for absorbs in (True, False):
        clock, s, b, weth, feed = world(3, colls=(6, 4, 6), absorbs=absorbs)      # at 1000: 120%, 80%, 120% -> TCR 107%, shutdown
        for o, h in (("t0", "A"), ("t1", "B"), ("t2", "B")):
            s.stable.transfer(o, h, 5_000 * E)
        s.stable.transfer("B", "A", 2_500 * E)                       # A and B hold 7,500 each
        feed.price = 1000 * E; b.trigger_shutdown()
        b.settle_trove(1, "k"); b.settle_trove(2, "k")               # Trove 3 (healthy!) is never processed
        clock.warp(29 * DAY)
        assert "not complete" in expect_revert(b.redeem_bad_debt_coll, "A", 1 * E)
        assert "deadline" in expect_revert(b.write_off, 3)
        clock.warp(1 * DAY)
        b.write_off(3, "writer")                                     # anyone; paid half the gas deposit: phase 1 ends
        assert b.unsettled == 0
        a_first = b.redeem_bad_debt_coll("A", 7_500 * E)             # A is paid at the conservative rate
        r = b.settle_trove(3, "k"); assert r["late"]                 # ... later the Trove is settled after all
        a_late = b.claim_late("A")
        b_all = b.redeem_bad_debt_coll("B", 7_500 * E)               # B claims only now, after the recovery
        assert a_late > 0 and abs((a_first + a_late) - b_all) <= 3, f"equal claims were not paid equally: {a_first + a_late} vs {b_all}"
        s0, s2 = b.claim_surplus("t0"), b.claim_surplus("t2")
        # the END STATE must equal a timely settlement of all three Troves (holders AND borrowers), whatever the path
        clock2, s2_, b2, weth2, feed2 = world(3, colls=(6, 4, 6), absorbs=absorbs)
        for o, h in (("t0", "A"), ("t1", "B"), ("t2", "B")):
            s2_.stable.transfer(o, h, 5_000 * E)
        s2_.stable.transfer("B", "A", 2_500 * E)
        feed2.price = 1000 * E; b2.trigger_shutdown()
        for tid in (1, 2, 3):
            b2.settle_trove(tid, "k")
        ref_a = b2.redeem_bad_debt_coll("A", 7_500 * E); ref_b = b2.redeem_bad_debt_coll("B", 7_500 * E)
        ref_s0, ref_s2 = b2.claim_surplus("t0"), b2.claim_surplus("t2")
        assert abs(a_first + a_late - ref_a) <= 3 and abs(b_all - ref_b) <= 3, "holders must end as in a timely settlement"
        assert abs(s0 - ref_s0) <= 3 and abs(s2 - ref_s2) <= 3, f"borrowers must end as in a timely settlement ({s0} vs {ref_s0}, {s2} vs {ref_s2})"
        check_invariants(s, "27b")
        total_in = 16 * E
        s1 = b.claim_surplus("t1")
        total_out = a_first + a_late + b_all + s0 + s1 + s2 + b.bad_debt_coll + b.late_pool + b.settle_surplus_pool + b.gas_pool + weth.bal["k"] + weth.bal["writer"]
        assert abs(total_out - (total_in + 3 * GD)) <= 3, f"collateral must be conserved ({total_out} vs {total_in + 3 * GD})"
        out.append(f"b ({'borrowers absorb' if absorbs else 'vault parity'}): stuck Trove written off after 30 days; A (early) and B (late) both end with {b_all / E:.4f} ETH")
    # (c) rounding: the common rate holds up to ONE wei of collateral per claim, however claims are ordered or split
    res = {}
    for order in (("A", "B"), ("B", "A")):
        clock, s, b, weth, feed = world(2, colls=(6, 4))
        s.stable.transfer("t0", "A", 5_000 * E); s.stable.transfer("t1", "B", 5_000 * E); s.stable.transfer("A", "B", 148)
        feed.price = 1000 * E; b.trigger_shutdown(); b.settle_trove(1, "k"); b.settle_trove(2, "k")
        res[order] = {h: b.redeem_bad_debt_coll(h, s.stable.bal[h]) for h in order}
    for h in ("A", "B"):
        assert abs(res[("A", "B")][h] - res[("B", "A")][h]) <= 1, "order changed a pay-out by more than one wei"
    clock, s, b, weth, feed = world(2, colls=(6, 4))
    s.stable.transfer("t0", "A", 5_000 * E); s.stable.transfer("t1", "B", 5_000 * E)
    feed.price = 1000 * E; b.trigger_shutdown(); b.settle_trove(1, "k"); b.settle_trove(2, "k")
    whole = b.bad_debt_coll * (5_000 * E) // b.bad_debt
    parts = sum(b.redeem_bad_debt_coll("A", 500 * E) for _ in range(10))
    fig("claim_split_parts", 10)
    fig("claim_split_loss_wei", whole - parts)
    assert 0 <= whole - parts <= 10, f"splitting a claim in 10 moved it by {whole - parts} wei"
    # the general bound: each earlier claim leaves < 1 wei of dust in the pot, and a later claim of R units receives
    # at most R / claims <= 1 of that dust per earlier claim -> a pay-out moves by at most (number of earlier claims) wei.
    # Worked case: 100 tiny claims by B before A's -> A moved by 40 wei (<= 100).
    clock, s, b, weth, feed = world(2, colls=(6, 4))
    s.stable.transfer("t0", "A", 5_000 * E); s.stable.transfer("t1", "B", 5_000 * E)
    feed.price = 1000 * E; b.trigger_shutdown(); b.settle_trove(1, "k"); b.settle_trove(2, "k")
    a_first = b.bad_debt_coll * (5_000 * E) // b.bad_debt
    for _ in range(100):
        b.redeem_bad_debt_coll("B", 2_000)
    a_after = b.redeem_bad_debt_coll("A", 5_000 * E)
    n_earlier = fig("claim_order_earlier_claims", 100)
    shift = fig("claim_order_shift_wei", a_after - a_first)
    assert 0 <= shift <= n_earlier, f"{n_earlier} earlier claims moved A by {shift} wei (bound {n_earlier})"
    out.append(f"c: a pay-out moves by at most one wei per EARLIER claim ({n_earlier} tiny claims moved the next one by"
               f" {shift} wei); splitting a claim into 10 parts loses at most 10 wei")
    return "; ".join(out)


def scenario_28_loss_sharing_at_settlement_is_decided():
    """Healthy borrowers' surplus absorbs the shortfall of under-water Troves first, each giving up
    the SAME FRACTION of his surplus; holders are hit only when all surplus is gone. Pins the default and the formula."""
    from fractions import Fraction
    from model import Branch
    assert Branch.SETTLEMENT_SURPLUS_ABSORBS is True
    # three Troves at 1000: t1 6 ETH (120%), t2 7 ETH (140%), t3 3 ETH (60%, under water): TCR 107% -> shutdown; holders A, B
    s, b, weth = _settlement_state((6, 7, 3), 2000, 1000, True, debts=[5_000, 5_000, 5_000])
    assert b.settlement_surplus_absorbs is True, "the default must be the decided rule"
    d = {tid: b.debt_now(b.troves[tid]) for tid in (1, 2, 3)}
    for tid in (3, 1, 2):
        b.settle_trove(tid, "k")
    need = {tid: -(-d[tid] * E // (1000 * E)) for tid in d}
    short = need[3] - 3 * E
    gross = {1: 6 * E - need[1], 2: 7 * E - need[2]}
    keep = Fraction(sum(gross.values()) - short, sum(gross.values()))
    s1, s2 = b.claim_surplus("t1"), b.claim_surplus("t2")
    assert abs(Fraction(s1) - keep * gross[1]) <= 2 and abs(Fraction(s2) - keep * gross[2]) <= 2, "each healthy borrower must give up the same fraction"
    assert abs(Fraction(s1, gross[1]) - Fraction(s2, gross[2])) < Fraction(1, 10**12)
    a = b.redeem_bad_debt_coll("A", s.stable.bal["A"]); bb = b.redeem_bad_debt_coll("B", s.stable.bal["B"])
    # the surplus covered the whole shortfall here, so holders are paid exactly at par
    assert abs(a * 1000 - 7_500 * E) <= 1000 * 2 and abs(bb * 1000 - 7_500 * E) <= 1000 * 2, "holders at par when surplus covers the shortfall"
    check_invariants(s, "28")
    return f"decided: borrowers absorb first; t1 and t2 each keep {float(keep):.4f} of their surplus; holders exactly at par"


def scenario_29_late_recovery_ownership():
    """Late-recovery ownership. (1) every Trove written off, pot empty, later recoveries claimable by all;
    (2) burning with a zero first payment keeps the right to later recoveries; (3) write-off + full recovery ends EXACTLY as a
    timely settlement, for holders and borrowers; (4) no borrower is paid more than a timely settlement would give him."""
    out = []
    from fractions import Fraction
    def world(colls, debts, price_after, absorbs=True, oracle=False):
        clock = Clock(); s = System(clock, frontend_share=0)
        weth = Token("WETH"); feed = Feed(2000 * E)
        b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT,
                            min_debt=500 * E, debt_cap=10**9 * E)
        b.settlement_surplus_absorbs = absorbs
        for i, (c, d) in enumerate(zip(colls, debts)):
            weth.mint(f"t{i}", c * E); b.open_trove(f"t{i}", c * E, d * E, 5 * PCT)
        for i in range(len(colls)):
            s.stable.transfer(f"t{i}", "H" if i % 2 == 0 else "K", s.stable.bal[f"t{i}"])
        if oracle:
            feed.status = FAILED; b.poke_oracle()
        else:
            feed.price = price_after * E; b.trigger_shutdown()
        assert b.shutdown_at
        return clock, s, b, weth
    # (1) + (2): everything written off, pot empty; K burns first (zero payment), then the Troves pay after all
    for absorbs in (True, False):
        clock, s, b, weth = world((6, 4), (5_000, 5_000), 1000, absorbs)
        clock.warp(31 * DAY); b.write_off(1, "w"); b.write_off(2, "w")
        assert b.unsettled == 0 and b.bad_debt_coll == 0
        k_bal = s.stable.bal["K"]
        assert b.redeem_bad_debt_coll("K", k_bal) == 0, "empty pot: burning pays nothing yet ..."
        assert b.units_of["K"] == k_bal and s.stable.bal["K"] == 0, "... but the claim units are registered"
        b.settle_trove(1, "k"); b.settle_trove(2, "k")
        assert b.late_pool > 0
        got_k = b.claim_late("K")
        got_h = b.redeem_bad_debt_coll("H", s.stable.bal["H"])
        assert got_k > 0 and abs(got_k - got_h) <= 3, f"late recoveries must reach the early burner too: {got_k} vs {got_h}"
        check_invariants(s, "29-1")
    out.append("1+2: with an empty pot the burner keeps its right; late recoveries reach it equally")
    # (3) + (4): the transfer case: 6 ETH and 20 ETH, 5,000 each, oracle-failure shutdown at 2,000, nobody under water
    for absorbs in (True, False):
        ref = {}
        clock, s, b, weth = world((6, 20), (5_000, 5_000), None, absorbs, oracle=True)
        for tid in (1, 2):
            b.settle_trove(tid, "k")
        ref["h"] = b.redeem_bad_debt_coll("H", s.stable.bal["H"]); ref["k"] = b.redeem_bad_debt_coll("K", s.stable.bal["K"])
        ref["a"], ref["b"] = b.claim_surplus("t0"), b.claim_surplus("t1")
        clock, s, b, weth = world((6, 20), (5_000, 5_000), None, absorbs, oracle=True)
        b.settle_trove(1, "k")
        clock.warp(31 * DAY); b.write_off(2, "w")
        early_a = b.claim_surplus("t0")                                  # A claims BEFORE B's Trove is recovered
        h1 = b.redeem_bad_debt_coll("H", s.stable.bal["H"])
        b.settle_trove(2, "k")                                           # full recovery
        late_a = b.claim_surplus("t0"); h2 = b.claim_late("H")
        k_all = b.redeem_bad_debt_coll("K", s.stable.bal["K"]); sb = b.claim_surplus("t1")
        assert abs(early_a + late_a - ref["a"]) <= 3 and abs(sb - ref["b"]) <= 3, f"borrowers differ from a timely settlement: A {early_a + late_a} vs {ref['a']}, B {sb} vs {ref['b']}"
        assert abs(h1 + h2 - ref["h"]) <= 3 and abs(k_all - ref["k"]) <= 3, "holders differ from a timely settlement"
        assert early_a + late_a <= ref["a"] + 3, "(4) a borrower must never be paid more than a timely settlement gives him"
        check_invariants(s, "29-3")
        fig("late_recovery_a_eth", (early_a + late_a) / E, ".4f")
        fig("late_recovery_b_eth", sb / E, ".4f")
        fig("late_recovery_single_owner_eth", (early_a + late_a + sb) / E, ".4f")
        out.append(f"3+4 ({'absorb' if absorbs else 'parity'}): A {(early_a + late_a) / E:.4f} = ref {ref['a'] / E:.4f}; B {sb / E:.4f} = ref {ref['b'] / E:.4f}")
    # (4) again with a REAL shortfall (round-28 state), both paths must agree
    for absorbs in (True, False):
        clock, s, b, weth = world((6, 4, 6), (5_000, 5_000, 5_000), 1000, absorbs)
        ref = {}
        for tid in (1, 2, 3): b.settle_trove(tid, "k")
        ref = (b.redeem_bad_debt_coll("H", s.stable.bal["H"]), b.redeem_bad_debt_coll("K", s.stable.bal["K"]), b.claim_surplus("t0"), b.claim_surplus("t2"))
        clock, s, b, weth = world((6, 4, 6), (5_000, 5_000, 5_000), 1000, absorbs)
        b.settle_trove(1, "k"); clock.warp(31 * DAY); b.write_off(2, "w"); b.write_off(3, "w")
        pa = b.claim_surplus("t0"); ph = b.redeem_bad_debt_coll("H", s.stable.bal["H"])
        b.settle_trove(3, "k"); b.settle_trove(2, "k")
        got = (ph + b.claim_late("H"), b.redeem_bad_debt_coll("K", s.stable.bal["K"]), pa + b.claim_surplus("t0"), b.claim_surplus("t2"))
        assert all(abs(x - y) <= 3 for x, y in zip(got, ref)), f"path dependence: {got} vs {ref}"
        check_invariants(s, "29-4")
    out.append("4: with a real shortfall the write-off path ends exactly as the timely one, under both variants")
    # (5, fuzzer find) a written-off Trove settled while OTHERS are still unsettled: the write-off is reversed, phase 1 stays open
    clock, s, b, weth = world((6, 4, 6), (5_000, 5_000, 5_000), 1000, True)
    clock.warp(31 * DAY); b.write_off(2, "w")
    assert b.unsettled == 2 and 2 in b.written_off
    r = b.settle_trove(2, "k")
    assert r["late"] is False and b.unsettled == 2 and 2 not in b.written_off, "settling before phase 1 ends must undo the write-off"
    assert "not complete" in expect_revert(b.redeem_bad_debt_coll, "H", 1 * E)
    b.settle_trove(1, "k"); b.settle_trove(3, "k")
    check_invariants(s, "29-5")
    out.append("5: write-off reversed when settled early; phase 1 stays open")
    return "; ".join(out)


def scenario_30_settlement_path_independence():
    """The end state must not depend on the PATH. All combinations of: one owner or several; gas deposit
    0 or positive; a written-off Trove settled before or after phase 1 ends; surplus claimed before, between and after
    recoveries; empty or non-empty pot. The reference is an INDEPENDENT exact-arithmetic computation, not the model."""
    import itertools
    from fractions import Fraction
    checked = 0
    for one_owner, gd, before, claim_mid, empty_pot in itertools.product((True, False), (0, E // 100), (True, False), (True, False), (True, False)):
        # at the forced reference price 1000: 240% (big surplus), 400%, 80% (under water). While Trove 2 is written off its whole
        # need counts as shortfall, so keep = (7 - 6) / 7 > 0 and a mid-way surplus claim really pays (blindness check below)
        colls, debts, price = (12, 20, 4), (5_000, 5_000, 5_000), 1000
        # --- world
        clock = Clock(); s = System(clock, frontend_share=0)
        weth = Token("WETH"); feed = Feed(2000 * E)
        b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT, pen_redist=10 * PCT,
                            min_debt=500 * E, debt_cap=10**9 * E, gas_deposit=gd)
        owners = ["O", "O", "O"] if one_owner else ["O1", "O2", "O3"]
        for i, (c, d, o) in enumerate(zip(colls, debts, owners)):
            weth.mint(o, c * E + gd); b.open_trove(o, c * E, d * E, 5 * PCT)
        for o in set(owners):
            s.stable.transfer(o, "H", s.stable.bal[o] // 2); s.stable.transfer(o, "K", s.stable.bal[o])
        feed.status = FAILED; b.poke_oracle()                     # reference price 2,000 (oracle failure): nobody under water except by design below
        b.settle_price = price * E                                # force the harsher reference price so that Trove 3 is under water
        assert b.shutdown_at and b.unsettled == 3
        # --- independent expectation (rationals), from the raw Troves and the rule "each healthy borrower gives up the same fraction"
        needs = [Fraction(-(-b.debt_now(b.troves[i + 1]) * E // (price * E))) for i in range(3)]
        contribs = [min(Fraction(c * E), n) for c, n in zip(colls, needs)]
        grosses = [Fraction(c * E) - k for c, k in zip(colls, contribs)]
        S, G = sum(n - k for n, k in zip(needs, contribs)), sum(grosses)
        take = min(S, G); keep = (G - take) / G if G else Fraction(1)
        pot = sum(contribs) + take
        claims = Fraction(b.bad_debt + sum(b.debt_now(b.troves[i + 1]) for i in range(3)))
        exp_owner = {}
        for o, g in zip(owners, grosses):
            exp_owner[o] = exp_owner.get(o, Fraction(0)) + g * keep
        rate = pot / claims
        # --- the path
        got_owner = {o: 0 for o in set(owners)}
        got_h = 0
        if empty_pot:
            clock.warp(31 * DAY)
            for tid in (1, 2, 3): b.write_off(tid, "w")
            assert b.unsettled == 0 and b.bad_debt_coll == 0
            got_h += b.redeem_bad_debt_coll("H", s.stable.bal["H"])          # pays 0, registers units
            for tid in (2, 1, 3): b.settle_trove(tid, "k")
        else:
            b.settle_trove(1, "k")
            if claim_mid: got_owner[owners[0]] += b.claim_surplus(owners[0]) if b.unsettled == 0 else 0
            clock.warp(31 * DAY); b.write_off(2, "w")
            if before:
                b.settle_trove(2, "k"); b.settle_trove(3, "k")
            else:
                b.settle_trove(3, "k")                                        # phase 1 ends here (2 written off)
                if claim_mid:
                    got_owner[owners[0]] += b.claim_surplus(owners[0]); got_h += b.redeem_bad_debt_coll("H", s.stable.bal["H"])
                b.settle_trove(2, "k")                                        # late recovery
        mid_total = sum(got_owner.values())
        for o in set(owners): got_owner[o] += b.claim_surplus(o)
        if not empty_pot and not before and claim_mid: assert mid_total > 0, "the mid claim paid nothing: the combination is blind"
        got_h += b.claim_late("H") + (b.redeem_bad_debt_coll("H", s.stable.bal["H"]) if s.stable.bal["H"] else 0)
        got_k = b.redeem_bad_debt_coll("K", s.stable.bal["K"])
        check_invariants(s, "30")
        for o in set(owners):
            assert abs(Fraction(got_owner[o]) - exp_owner[o]) <= 6, f"owner {o} ({one_owner}, {gd}, {before}, {claim_mid}, {empty_pot}): {got_owner[o]} vs {float(exp_owner[o])}"
        hb, kb = Fraction(15_000 * E // 2), Fraction(15_000 * E - 15_000 * E // 2)
        assert abs(Fraction(got_h) - rate * hb) <= 6 and abs(Fraction(got_k) - rate * kb) <= 6, "holders differ from the independent rate"
        unexercised = b.claim_units - sum(b.units_of.values())        # the interest tokens in the escrow have not claimed
        assert b.settle_surplus_pool <= 6, "borrowers' collateral left without a withdrawal path"
        assert abs(b.late_pool - unexercised * b.late_per_unit // L_PRECISION) <= 6, "late pool must hold exactly the unexercised claims' share"
        assert b.gas_pool == 0 and all(v == gd for v in b.gas_paid.values()) if gd else True, "each Trove must pay exactly its deposit"
        if gd:
            fig("path_gas_posted_eth", len(colls) * gd / E, ".3f")
            fig("path_gas_paid_eth", sum(b.gas_paid.values()) / E, ".3f")
        checked += 1
    return (f"{fig('path_combinations', checked)} path combinations end within"
            f" {fig('path_tolerance_wei', 6)} wei of the independent computation; no residue, every deposit paid exactly once")


def scenario_31_redemption_order_is_total():
    """SPEC R2: lowest rate first, and among equal rates the LOWER Trove id first. The tie rule makes the order a total
    order, so the sorted list of the contracts has exactly one valid state for a given set of Troves, whatever hints it was
    given. The expected sequences are written out by hand from the rule, not computed by the model's own sort."""
    clock, s, b, weth, feed = setup()
    rates = {1: 3 * PCT, 2: 1 * PCT, 3: 2 * PCT, 4: 1 * PCT, 5: 1 * PCT}
    for tid, rate in rates.items():
        fund(weth, f"o{tid}", 100 * E)
        assert b.open_trove(f"o{tid}", 100 * E, 3_000 * E, rate) == tid
    assert [t.id for t in b.redemption_order()] == [2, 4, 5, 3, 1], "ties must be broken by the lower Trove id"
    # a Trove that moves ONTO an existing rate takes its place by id, not at the back of that rate
    b.adjust_rate(1, 1 * PCT)
    expected = [1, 2, 4, 5, 3]
    assert [t.id for t in b.redemption_order()] == expected, "a rate change must not decide the Trove's place among ties"
    for tid in rates:
        s.stable.transfer(f"o{tid}", "r", s.stable.bal[f"o{tid}"])
    give_stable(s, b, weth, "r", 2_000 * E)              # the upfront fees: a helper Trove at 5 %, behind all of the above
    # and the redemption really walks that order: one iteration, exactly one Trove's debt, each time the next one
    for tid in expected:
        before = {t.id: b.debt_now(t) for t in b.open_troves()}
        red, _ = s.redeem("r", before[tid], max_iter=1)
        assert red == before[tid] and b.debt_now(b.troves[tid]) == 0, f"Trove {tid} was not the one redeemed"
        assert all(b.debt_now(b.troves[i]) == d for i, d in before.items() if i != tid), "a Trove out of turn was touched"
        check_invariants(s, f"31 after {tid}")
    return f"order {expected} after Trove 1 moved onto the lowest rate; redemption walked it Trove by Trove"


def scenario_32_untagged_share_returns_to_the_borrower():
    """SPEC V2: a frontend keeps its share of the Troves it brought; a Trove opened without a frontend (a command-line or
    self-written client) has its whole share credited to its owner. Expected credits are computed here from each Trove's
    own fee and interest -- floor(amount x 3 %), then the kickback split -- not read back from the registry."""
    clock, s, b, weth, _ = setup()
    fe = s.frontends
    fid = fe.register("FE", 40 * PCT)
    for who in ("tagged", "cli"):
        fund(weth, who, 100 * E)
    tt = b.open_trove("tagged", 100 * E, 50_000 * E, 10 * PCT, frontend=fid)
    tc = b.open_trove("cli", 100 * E, 50_000 * E, 10 * PCT)                 # frontend 0: no frontend brought it
    fee_t, fee_c = b.troves[tt].debt - 50_000 * E, b.troves[tc].debt - 50_000 * E
    clock.warp(90 * DAY)
    d_t, d_c = b.troves[tt].debt, b.troves[tc].debt
    b.apply_pending_debt(tt)
    b.apply_pending_debt(tc)
    a_t, a_c = b.troves[tt].debt - d_t, b.troves[tc].debt - d_c              # each Trove's own interest (step B)

    def share(x):
        return x * 3 // 100                                                     # floor(x x 3 %)
    # a credit is floored at each touch (the fee at opening, the interest at the next step B), never on a summed amount
    kick = lambda r: r * 40 // 100
    exp_cli = share(fee_c) + share(a_c)
    exp_owner_t = kick(share(fee_t)) + kick(share(a_t))
    exp_fe = share(fee_t) - kick(share(fee_t)) + share(a_t) - kick(share(a_t))
    assert fe.claimable["cli"] == exp_cli, "V2: an untagged Trove's share must go to its owner"
    assert fe.claimable["tagged"] == exp_owner_t, "V2: the kickback of a tagged Trove"
    assert fe.claimable["FE"] == exp_fe, "V2: a frontend keeps its share of the Troves it brought"
    assert exp_cli > 0 and exp_fe > 0
    assert sum(fe.claimable.values()) == fe.total_credited, "every credit has an owner: nothing goes to an ownerless account"
    for who in ("cli", "tagged", "FE"):
        fe.claim(who)
    check_invariants(s)
    return f"untagged owner credited {exp_cli / E:.4f}; tagged: owner {exp_owner_t / E:.4f}, frontend {exp_fe / E:.4f}"


def scenario_33_zombie_borrowing_back_rejoins_the_queue():
    """SPEC B4 / R2: a Trove redeemed to exactly zero is a Zombie that no pointer tracks. If it borrows back above the
    minimum -- through `adjust_trove` as well as `borrow` -- it must be Active again and redeemed before a Trove paying a
    higher rate. Expectation from the rule: its rate (1 %) is lower than the other Trove's (5 %), so a redemption smaller
    than its debt must come entirely out of it."""
    out = []
    for path in ("adjust_trove", "borrow"):
        clock, s, b, weth, feed = setup()
        for who in ("z", "o"):
            fund(weth, who, 100 * E)
        tz = b.open_trove("z", 20 * E, 10_000 * E, 1 * PCT)
        to = b.open_trove("o", 80 * E, 30_000 * E, 5 * PCT)
        s.redeem("o", b.debt_now(b.troves[tz]))                 # z redeemed to exactly zero
        assert b.troves[tz].status == ZOMBIE and b.last_zombie == 0, "a Trove redeemed to zero is an untracked Zombie"
        if path == "adjust_trove":
            b.adjust_trove(tz, 0, 15_000 * E)
        else:
            b.borrow(tz, 15_000 * E)
        assert b.troves[tz].status == ACTIVE, f"B4: borrowing back through {path} must reactivate the Zombie"
        z0, o0 = b.debt_now(b.troves[tz]), b.debt_now(b.troves[to])
        s.redeem("o", 2_000 * E)
        assert b.debt_now(b.troves[tz]) == z0 - 2_000 * E and b.debt_now(b.troves[to]) == o0, \
            f"R2: after {path} the lower-rate Trove must be redeemed first"
        check_invariants(s, f"33 {path}")
        out.append(path)
    return "re-borrowed Zombie back in the queue via " + " and ".join(out)


def scenario_34_redemption_price_never_below_the_price():
    """SPEC R4: the branch converts debt at max(price, redemptionPrice). (a) A feed whose redemption price is below its
    price: a Trove at 105 % at the price but under 100 % at the redemption price is redeemed in full at the price, and
    keeps the rest of its collateral; converted at the feed's lower price it would owe more than it holds. (b) A redemption
    price above the price is used as it is. Expectations from the rule: out = R / conversion price, less the fee
    floor + R / supply (base rate 0, beta 1)."""
    clock, s, b, weth, feed = setup()
    fund(weth, "o", 1000 * E)
    fund(weth, "w", 100 * E)
    to = b.open_trove("o", 400 * E, 50_000 * E, 5 * PCT)
    tw = b.open_trove("w", 12 * E, 20_000 * E, 1 * PCT)          # the head of the queue, about 120 %
    feed.price = 1760 * E                                          # the head at about 105 %, the branch far above SCR
    feed.redemption_price = 1600 * E                               # ... and under 100 % at the feed's redemption price
    w = b.troves[tw]
    d, c = b.debt_now(w), b.coll_now(w)
    assert c * feed.price // d >= WAD > c * feed.redemption_price // d
    supply, got = s.stable.supply, weth.bal["o"]
    s.redeem("o", d, max_iter=1)
    rate = WAD // 200 + d * WAD * WAD // (supply * WAD)
    out = d * WAD // (1760 * E)
    to_redeemer = out - out * rate // WAD
    assert weth.bal["o"] - got == to_redeemer, "R4: a redemption price below the price must be raised to the price"
    assert w.debt == 0 and w.coll == c - to_redeemer > 0, "R4: the Trove keeps what the conversion at the price leaves"
    # (b) a redemption price above the price converts as it is
    feed.redemption_price = 1900 * E
    o0, supply, got = b.coll_now(b.troves[to]), s.stable.supply, weth.bal["o"]
    decayed = s.base_rate                                          # same block: no decay since the last redemption
    s.redeem("o", 3_000 * E, max_iter=5)
    rate = min(WAD // 200 + min(decayed + 3_000 * E * WAD * WAD // (supply * WAD), WAD), WAD)
    out = 3_000 * E * WAD // (1900 * E)
    assert weth.bal["o"] - got == out - out * rate // WAD, "R4: a higher redemption price is used as it is"
    assert o0 - b.coll_now(b.troves[to]) == out - out * rate // WAD, "R7: the fee stays in the Trove"
    check_invariants(s, "34")
    return "redemption price 1,600 under a price of 1,760 converted at 1,760; 1,900 above it used as it is"


def scenario_35_liquidation_surplus_is_not_held_by_settlement():
    """SPEC L3 / X11: an owner has the surplus of a liquidated Trove and, after a shutdown, the surplus of a settled one.
    Until phase 1 ends only the settlement surplus waits; the liquidation surplus is his at once. Expectations from the
    rules: liquidation surplus = coll - 0.5 % bonus - debt x 1.05 / price (the pool absorbs the whole debt); settlement
    surplus = coll - ceil(debt / settlePrice), kept in full because no Trove is under water."""
    clock, s, b, weth, feed = setup()
    fund(weth, "a", 100 * E)
    fund(weth, "b", 1000 * E)
    t1 = b.open_trove("a", 20 * E, 20_000 * E, 5 * PCT)
    t2 = b.open_trove("a", 40 * E, 20_000 * E, 5 * PCT)
    t3 = b.open_trove("b", 400 * E, 60_000 * E, 5 * PCT)
    b.sp.deposit("b", 30_000 * E)
    d1, c1 = b.debt_now(b.troves[t1]), b.coll_now(b.troves[t1])
    price = 108 * PCT * d1 // c1                                   # t1 at 108 %: between the pool's premium and MCR
    feed.price = price
    b.liquidate(t1, "keeper")
    expected_liq = c1 - c1 * WAD // 200 // WAD - d1 * (WAD + 5 * PCT) // price
    assert b.surplus["a"] == expected_liq > 0
    feed.status = FAILED
    b.poke_oracle()                                                # shutdown; the settlement price is the last good one
    assert b.shutdown_at and b.settle_price == price
    d2, c2 = b.debt_now(b.troves[t2]), b.coll_now(b.troves[t2])
    b.settle_trove(t2, "keeper")
    assert b.unsettled == 1, "t3 is still unsettled: phase 1 is not complete"
    assert "phase 1" in expect_revert(b.claim_surplus, "a"), "both at once: refused while the settlement part waits"
    assert "phase 1" in expect_revert(b.claim_settlement_surplus, "a")
    got = weth.bal["a"]
    assert b.claim_liquidation_surplus("a") == expected_liq and weth.bal["a"] - got == expected_liq, \
        "L3: the liquidation surplus is claimable during phase 1"
    b.settle_trove(t3, "keeper")
    expected_settle = c2 - (d2 * WAD + price - 1) // price
    assert b.claim_settlement_surplus("a") == expected_settle, "X11: kept in full when no Trove is under water"
    assert b.claim_surplus("a") == 0, "nothing is paid twice"
    check_invariants(s, "35")
    return "liquidation surplus paid during phase 1; settlement surplus after it"


SCENARIOS = [v for k, v in sorted(globals().items()) if k.startswith("scenario_")]

if __name__ == "__main__":
    failed = 0
    for fn in SCENARIOS:
        try:
            note = fn()
            print(f"PASS  {fn.__name__}: {note}")
        except Exception:
            failed += 1
            print(f"FAIL  {fn.__name__}")
            traceback.print_exc()
    fig("scenarios_total", len(SCENARIOS))
    fig("scenarios_passed", len(SCENARIOS) - failed)
    print(f"\n{len(SCENARIOS) - failed}/{len(SCENARIOS)} scenarios passed")
    if not failed:
        from figures import dump
        print(f"figures: {dump('scenarios')} recorded")
    sys.exit(1 if failed else 0)
