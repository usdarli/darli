"""
Self-tests of the economic simulator. The accounting core has scenarios, fuzzers and mutants; the simulator had none, and
three review rounds in a row found bugs in it. These tests pin down its own bookkeeping.      python3 test_econ_sim.py
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import math
import random
import sys
import traceback
from dataclasses import replace

import econ_sim as es
from econ_sim import E, Params, RangePool, run, settle_system
from model import Clock, Token, Feed, System, check_invariants, WAD
from pilot_sweep import PILOT

PCT = WAD // 100


def test_01_range_pool_maths():
    tok = Token("uUSD"); tok.mint("POOL", 10**30); tok.mint("a", 10**30)
    pool = RangePool(tok, 30_000, 0.01, 0.0)                  # no fee: exact identities
    L = pool.L
    assert abs(pool.x + pool.y - 30_000) < 1e-6 and abs(pool.price - 1) < 1e-12
    k0 = (pool.x + L / pool.sb) * (pool.y + L * pool.sa)
    assert abs(k0 - L * L) / (L * L) < 1e-12, "virtual-reserve identity of a concentrated position"
    cap = L * (1 / pool.sa - 1)                               # stable the range can absorb from price 1
    out = pool.sell("a", 5_000)
    assert abs((pool.x + L / pool.sb) * (pool.y + L * pool.sa) - L * L) / (L * L) < 1e-12
    back, cost = pool.buy("a", 5_000 * 0.99)
    assert cost < out and pool.price < 1, "buying back less than was sold cannot cost more or lift the price above 1"
    pool.sell("a", 10**9)                                     # far beyond capacity
    assert abs(pool.price - (1 - 0.01)) < 1e-9 and pool.y < 1e-6, "at the lower edge the position is 100% stable"
    assert pool.unfilled_sell > 10**9 - 2 * cap, "what the range cannot absorb must be reported as unfilled"
    assert pool.sell("a", 100) == 0.0, "no liquidity below the range"
    return f"capacity from par = {cap:,.0f} of a 30,000 position; edge behaviour exact"


def test_02_determinism():
    a = run(replace(Params(), seed=3, days=60, **PILOT))
    b = run(replace(Params(), seed=3, days=60, **PILOT))
    assert a == b, "same seed must give the same run"
    return "two runs with the same seed are identical"


def test_03_conservation_every_day():
    """Token supply = debt (model invariants), pool inventory covers its virtual stable, keeper ETH never negative,
    keeper collateral is exactly what the treasury paid. Checked through a hook on every simulated day."""
    seen = dict(days=0, max_gap=0.0)

    def hook(s, b, pool, K, borrowers, eth):
        check_invariants(s, "econ_sim hook")
        real = s.stable.bal[pool.addr] / E
        assert real + 1e-6 >= pool.x, f"pool owes more stable than it holds: {real} < {pool.x}"
        assert K["eth"] > -1e-9, "keeper treasury spent ETH it does not have"
        seen["days"] += 1
    es.DAILY_HOOK = hook
    try:
        for over in (dict(), dict(crash_day=30, crash_size=0.6, outage_hours=24), dict(crash_day=30, feed_outage_hours=12)):
            run(replace(Params(), seed=1, days=70, **{**PILOT, **over}))
    finally:
        es.DAILY_HOOK = None
    assert seen["days"] > 100
    return f"invariants held on {seen['days']} simulated days across calm, outage and feed-failure runs"


def test_04_budget_shortfall_stops_only_the_keeper():
    """Round-7 bug: a keeper-budget shortfall skipped the rest of the hour. With a zero budget the keeper can never trade,
    and everything else must behave exactly as with mint_arb switched off."""
    base = dict(seed=4, days=90, crash_day=30, sell_frac=0.5, **PILOT)     # a run in which the upper side IS needed (the blindness checks below guard the choice of seed)
    ample = run(replace(Params(), **base))
    assert ample["upper_keeper_collateral"] > 0, "test is blind: the keeper never traded in the reference run"
    a = run(replace(Params(), **{**base, "upper_keeper_budget_usd": 1e-9}))
    assert a["upper_blocked_hours"] > 0, "test is blind: the zero-budget keeper never wanted to trade"
    b = run(replace(Params(), **{**base, "mint_arb": False}))
    for k in ("final_supply", "exits", "opened", "redeemed_pct_supply", "liquidations"):
        assert abs(a[k] - b[k]) < 1e-6, f"{k}: zero budget {a[k]} != no keeper {b[k]}"
    return (f"zero keeper budget == keeper switched off on every user-side metric "
            f"(keeper wanted to trade for {a['upper_blocked_hours']} h; reference run used {ample['upper_keeper_collateral']:,.0f} of ETH)")


def _hand_state(absorbs=True):
    """Two Troves opened through the ordinary path at ETH = 2,000 (6 ETH and 3 ETH, 5,000 debt each); the price falls to 1,000 and the
    rules shut the branch down: one Trove is ~120% backed, the other ~60%."""
    clock = Clock(); s = System(clock, frontend_share=0)
    weth = Token("WETH"); feed = Feed(2000 * E)
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT,
                        pen_redist=10 * PCT, min_debt=500 * E, debt_cap=10**6 * E)
    b.settlement_surplus_absorbs = absorbs
    for who, coll in (("t1", 6), ("t2", 3)):
        weth.mint(who, coll * E); b.open_trove(who, coll * E, 5_000 * E, 5 * PCT)
    s.stable.transfer("t1", "A", 5_000 * E); s.stable.transfer("t2", "B", 5_000 * E)
    feed.price = 1000 * E; b.trigger_shutdown()

    class B:
        def __init__(self, name, tid): self.name, self.tid = name, tid
    return s, b, RangePool(s.stable, 1, 0.01, 0.0), feed, [B("t1", 1), B("t2", 2)]


def test_05_settlement_pays_everyone_the_same_rate():
    """The simulator's settlement IS the core's staged settlement: whatever the order, A and B get the same per token."""
    seen = set()
    for order in (["A", "B", "protocol_recipients"], ["B", "protocol_recipients", "A"]):
        for seed in (0, 1, 2):
            s, b, pool, feed, bws = _hand_state()
            r = settle_system(s, b, pool, feed, 1000.0, bws, 500, random.Random(seed), order=order)
            rec = r["per_account"]
            assert abs(rec["A"] - rec["B"]) < 1e-9 and r["worst_holder_recovery"] == r["best_holder_recovery"]
            seen.add(round(rec["A"], 9))
    assert len(seen) == 1, f"recovery depends on the order: {seen}"
    return f"A and B both recover {seen.pop():.4f} per token in every order of settling and claiming"


def test_06_who_absorbs_the_shortfall_is_a_parameter_not_an_accident():
    res = {}
    for absorbs in (True, False):
        s, b, pool, feed, bws = _hand_state(absorbs)
        r = settle_system(s, b, pool, feed, 1000.0, bws, 500, random.Random(0), order=["A", "B"])
        res[absorbs] = (r["holder_recovery"], r["borrowers_surplus_value"])
        assert abs(r["value_out"] + r["borrowers_surplus_value"] + (b.bad_debt_coll + b.settle_surplus_pool) / E * 1000.0 - 9_000.0) < 1e-6, \
            "all 9 ETH must be accounted for: holders + borrowers + what is still in the pot"
    assert res[True][0] > res[False][0] and res[True][1] < res[False][1]
    return (f"borrowers absorb: holders {res[True][0]:.4f}, healthy borrower keeps {res[True][1]:,.0f}; "
            f"vault parity: holders {res[False][0]:.4f}, healthy borrower keeps {res[False][1]:,.0f}")


def test_07_unfunded_keeper_purchase_changes_nothing():
    from econ_sim import keeper_buy
    tok = Token("uUSD"); tok.mint("POOL", 20_000 * E)
    pool = RangePool(tok, 30_000, 0.01, 0.0005)
    K = dict(eth=0.0, cash=0.0)
    before = (pool.sp, pool.fees_usd, tok.bal["POOL"], tok.bal["keeper"], dict(K))
    assert keeper_buy(pool, K, "keeper", 2_002, 1000.0, 0.0005) is False
    assert (pool.sp, pool.fees_usd, tok.bal["POOL"], tok.bal["keeper"], dict(K)) == before, "an unfunded purchase moved something"
    # funded partly from cash, partly by selling free ETH: every leg is booked
    K = dict(eth=3.0, cash=500.0)
    cost = pool.quote_buy(2_002)
    assert keeper_buy(pool, K, "keeper", 2_002, 1000.0, 0.0005) is True
    assert tok.bal["keeper"] == 2_002 * E and abs(K["cash"]) < 1e-9
    assert abs((3.0 - K["eth"]) * 1000.0 * (1 - 0.0005) - (cost - 500.0)) < 1e-6, "ETH sold must equal the cash shortfall"
    return "unfunded: pool, balances and treasury untouched; funded: cash and ETH legs reconcile to the quote"


def test_09_same_seed_same_eth_path_whatever_the_policy():
    """Policies must face the SAME market. The ETH path may not depend on how agents consume random numbers."""
    paths = []
    for over in (dict(beta=1), dict(beta=4), dict(beta_policy="pressure"), dict(keeper_min_profit=50.0)):
        seen = []
        es.DAILY_HOOK = lambda s, b, pool, K, borrowers, eth, seen=seen: seen.append(round(eth, 6))
        try:
            run(replace(Params(), seed=5, days=60, **{**PILOT, **over}))
        finally:
            es.DAILY_HOOK = None
        paths.append(seen)
    assert all(pth == paths[0] for pth in paths) and len(paths[0]) >= 59, "ETH path differs between policies under the same seed"
    return f"identical ETH path over {len(paths[0])} days for four different policies"


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
if __name__ == "__main__":
    bad = 0
    for fn in TESTS:
        try:
            print(f"PASS  {fn.__name__}: {fn()}")
        except Exception:
            bad += 1
            print(f"FAIL  {fn.__name__}"); traceback.print_exc()
    print(f"\n{len(TESTS) - bad}/{len(TESTS)} simulator self-tests passed")
    if not bad:
        from figures import fig, dump
        fig("econ_sim_total", len(TESTS))
        fig("econ_sim_passed", len(TESTS) - bad)
        print(f"figures: {dump('econ_sim')} recorded")
    sys.exit(1 if bad else 0)
