"""
Property fuzzer for oracle failure detection (`docs/SPEC.md` 7).   python3 fuzz_oracle.py [seeds] [steps] [first_seed]
Random feed behaviour, sequencer flaps, pokes with random gas, borrower ops that revert.
Checked after every step:
  F1  Failed never while the sequencer is down / has been up for less than TIMEOUT.
  F2  Failed never sooner than TIMEOUT - max(staleness) after the last persisted Valid observation.
  F3  a truly healthy feed is never observed as anything but Valid, whatever gas the caller supplies
      (the call may revert, it may not lie).
  F4  liveness: truly healthy + ample gas -> Valid.
  F5  liveness: a source dead for > TIMEOUT with the sequencer up for >= TIMEOUT -> Failed (ample gas).
  F6  a reverted transaction leaves marker, lastGoodPrice and the latch untouched.
  F7  the latch is permanent and the shutdown price is the last persisted good price.
  F8  soundness: Valid is only ever reported for a truly healthy feed (fresh, positive, not from the future, network fine).
  F9  sequencer down or inside the grace period -> NetworkUnstable, whatever the sources say.
With a pool source (SPEC O7, O8), in most seeds:
  F10 never Valid while the primary is truly healthy and the pool source is available and outside MAX_DEVIATION.
  F11 a Valid price is the primary's when the primary is truly healthy, the pool source's otherwise.
  F12 Failed only after the pool source was last seen available a timeout ago, or after the last Valid lies a
      timeout back while the sources disagree.
  F13 liveness of the fallback: a primary readable but older than the timeout, or malformed at observations a
      timeout apart, the pool source available, the sequencer up for the timeout and ample gas -> Valid at the pool
      source's price.
Coverage: every outcome the second source adds (fallback, disagreement, both kinds of Failed) must occur.
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import random
import sys

from model import (WAD, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED, Clock, Token, System, Revert, atomic,
                   OracleFeed, Source, PoolSource, Sequencer, check_invariants)

E, PCT, HOUR = WAD, WAD // 100, 3600


def run(seed, steps):
    rng = random.Random(seed)
    clock = Clock()
    s = System(clock)
    l2 = rng.random() < 0.7
    n = rng.choice([1, 1, 2])
    seq = Sequencer(clock) if l2 else None
    stale = [rng.choice([1, 3, 6]) * HOUR for _ in range(n)]
    timeout = rng.choice([12, 24, 48]) * HOUR
    srcs = [Source(clock, 2000 * E, gas_cost=rng.choice([60_000, 900_000]), nested=rng.random() < 0.5)] + \
           [Source(clock, E) for _ in range(n - 1)]
    pool = PoolSource(clock, 2000 * E, gas_cost=rng.choice([150_000, 700_000])) if rng.random() < 0.7 else None
    dev = rng.choice([2, 5, 10]) * PCT
    feed = OracleFeed(clock, srcs, stale, timeout, sequencer=seq, grace=HOUR,
                      combine="single" if n == 1 else "ratio", max_skew=None if n == 1 else 4 * HOUR,
                      feed_gas_limit=1_200_000, pool_source=pool, max_deviation=dev if pool else None,
                      pool_gas_limit=800_000)
    weth = Token("WETH")
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT,
                        pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=10**7 * E)
    weth.mint("u", 10**4 * E)
    b.open_trove("u", 100 * E, 20_000 * E, 5 * PCT)
    counts = {VALID: 0, PRICE_INVALID: 0, NETWORK_UNSTABLE: 0, FAILED: 0, "revert": 0, "fallback": 0,
              "crosschecked": 0, "disagreement": 0, "failed_both_dead": 0, "failed_disagreement": 0}
    latched_price = None
    pool_seen_ok_at = clock.now                              # the last successful observation with the pool available

    def primary_price():
        if any(x.value <= 0 for x in srcs):
            return 2000 * E                                  # a broken primary: aim the pools at its healthy value
        return srcs[0].value if n == 1 else srcs[0].value * WAD // srcs[1].value

    def pool_available():
        return pool is not None and pool.available and not pool.reverts and not pool.burns_all_gas and pool.value > 0

    def disagree():
        a, b_ = primary_price(), pool.value
        return max(a, b_) * WAD > min(a, b_) * (WAD + dev)

    def primary_readable_but_dead():
        return all(not x.reverts and not x.burns_all_gas and x.value > 0 and x.updated_at <= clock.now for x in srcs) \
            and any(clock.now - x.updated_at > timeout for x in srcs)

    hold = 0                                                 # steps left in a held disagreement
    mal_seen = None                                          # first successful poke that saw the primary malformed

    def primary_malformed():
        return any(x.reverts or x.burns_all_gas or x.value <= 0 or x.updated_at > clock.now for x in srcs)

    def primary_fresh():
        return all(clock.now - x.updated_at <= st for x, st in zip(srcs, stale))
    for i in range(steps):
        if hold:
            # a held disagreement: the primary kept fresh, the pools kept far, a quarter timeout per step, a poke each
            hold -= 1
            for x in srcs:
                x.push()
            pool.value = primary_price() * 3 // 2
            clock.warp(timeout // 4)
            op = "poke"
        ops = ["warp", "warp", "push", "push", "push", "break", "heal", "seq", "poke", "poke", "poke", "lowgas", "borrow",
               "dead"]
        if pool is not None:
            ops += ["pool_near", "pool_far", "pool_off", "pool_on", "pool_break", "pool_heal", "hold_disagreement"]
        if not hold:
            op = rng.choice(ops)
        if op == "hold_disagreement":
            hold, op = 6, "dead"
        src = rng.choice(srcs)
        if op == "warp":
            clock.warp(rng.choice([60, 600, HOUR, 5 * HOUR, 30 * HOUR]))
        elif op == "push":
            src.push()
        elif op == "break":
            k = rng.randint(0, 3)
            if k == 0: src.value = rng.choice([0, -1])
            elif k == 1: src.reverts = True
            elif k == 2: src.updated_at = clock.now + rng.randint(1, 10**5)
            else: src.burns_all_gas = True
        elif op == "heal":
            src.reverts = src.burns_all_gas = False
            src.value = (2000 if src is srcs[0] else 1) * E
            src.push()
        elif op == "seq" and seq is not None:
            seq.set(not seq.is_up)
        elif op == "dead":
            pass                                             # nobody updates: staleness accumulates
        elif op == "pool_near":
            pool.value = primary_price() * rng.randint(10_000 - dev // 10**14, 10_000 + dev // 10**14) // 10_000
        elif op == "pool_far":
            pool.value = primary_price() * rng.choice([70, 80, 125, 150]) // 100
        elif op == "pool_off":
            pool.available = False
        elif op == "pool_on":
            pool.available = True
        elif op == "pool_break":
            if rng.random() < 0.5:
                pool.reverts = True
            else:
                pool.burns_all_gas = True
        elif op == "pool_heal":
            pool.reverts = pool.burns_all_gas = False
        elif op in ("poke", "lowgas", "borrow"):
            primary_healthy = feed.truly_healthy()           # the primary alone, and the network
            pool_ok = pool_available()
            healthy = primary_healthy and not (pool_ok and disagree())      # the combined truth: Valid expected
            before = (feed.invalid_since, feed.pool_invalid_since, feed.disagree_since, feed.last_good, b.oracle_failed,
                      b.shutdown_at)
            if op != "lowgas":
                gas = 10**7
            elif rng.random() < 0.5:                         # aim at the narrow window around the feed's real cost
                gas = int(srcs[0].gas_cost * rng.uniform(0.80, 1.12))
            else:
                gas = rng.randint(1_000, 2_000_000)
            try:
                if op == "borrow":
                    atomic(s, b.borrow, 1, 100 * E)
                    st = VALID
                else:
                    st = atomic(s, b.poke_oracle, gas)
                counts[st] += 1
            except Revert:
                counts["revert"] += 1
                after = (feed.invalid_since, feed.pool_invalid_since, feed.disagree_since, feed.last_good,
                         b.oracle_failed, b.shutdown_at)
                assert after == before, f"F6 reverted tx changed oracle state (seed {seed} step {i})"
                continue
            if latched_price is not None:
                assert st in (FAILED, VALID) and b.oracle_failed, f"F7 (seed {seed} step {i})"
                continue
            if healthy:
                assert st == VALID, f"F3/F4 healthy feed observed as {st} with gas {gas} (seed {seed} step {i})"
            if pool is not None and pool_ok:
                pool_seen_ok_at = clock.now
            if op != "borrow" and st != NETWORK_UNSTABLE:
                was_mal = mal_seen
                if primary_malformed():
                    mal_seen = mal_seen if mal_seen is not None else clock.now
                elif primary_fresh():
                    mal_seen = None
                net_long = seq is None or (seq.is_up and clock.now - seq.since >= timeout)
                if pool_ok and primary_malformed() and was_mal is not None and clock.now - was_mal >= timeout and net_long \
                        and latched_price is None:
                    assert st == VALID and feed.last_good == pool.value, \
                        f"F13 no fallback for a primary malformed a timeout long: {st} (seed {seed} step {i})"
            if st == VALID and op != "borrow":
                net_fine = seq is None or (seq.is_up and clock.now - seq.since >= HOUR)
                if pool is None:
                    assert healthy, f"F8 Valid reported for an unhealthy feed (seed {seed} step {i})"
                else:
                    assert net_fine and (healthy or (pool_ok and not primary_healthy)), f"F8/F10 (seed {seed} step {i})"
                    assert not (primary_healthy and pool_ok and disagree()), f"F10 Valid despite disagreement (seed {seed} step {i})"
                    want = primary_price() if primary_healthy else pool.value
                    assert feed.last_good == want, f"F11 Valid at {feed.last_good}, expected {want} (seed {seed} step {i})"
                    counts["fallback" if not primary_healthy else "crosschecked"] += 1
            if st == PRICE_INVALID and pool is not None and primary_healthy and pool_ok and disagree():
                counts["disagreement"] += 1
            if seq is not None and not (seq.is_up and clock.now - seq.since >= HOUR):
                assert st == NETWORK_UNSTABLE, f"F9 got {st} while the network is unstable (seed {seed} step {i})"
            if st == FAILED:
                assert seq is None or (seq.is_up and clock.now - seq.since >= timeout), f"F1 (seed {seed} step {i})"
                assert clock.now - feed.last_valid_at >= timeout - max(stale), f"F2 (seed {seed} step {i})"
                latched_price = feed.last_good
                assert b.shutdown_at == clock.now and b._shutdown_price() == latched_price, "F7"
                if pool is not None:
                    by_death = not pool_ok and clock.now - pool_seen_ok_at >= timeout
                    by_disagreement = primary_healthy and pool_ok and disagree() and clock.now - feed.last_valid_at >= timeout
                    assert by_death or by_disagreement, f"F12 Failed without cause (seed {seed} step {i})"
                    counts["failed_both_dead" if by_death else "failed_disagreement"] += 1
            elif op == "poke":
                dead = any(clock.now - x.updated_at > timeout and x.updated_at <= clock.now
                           and not x.reverts and not x.burns_all_gas and x.value > 0 for x in srcs)
                all_readable = all(not x.reverts and not x.burns_all_gas and x.value > 0 and x.updated_at <= clock.now
                                   for x in srcs)
                net_ok = seq is None or (seq.is_up and clock.now - seq.since >= timeout)
                if dead and all_readable and net_ok and pool is None:
                    raise AssertionError(f"F5 dead feed not reported as Failed (seed {seed} step {i})")
                if pool_ok and primary_readable_but_dead() and net_ok:
                    assert st == VALID and feed.last_good == pool.value, f"F13 no fallback: {st} (seed {seed} step {i})"
        if latched_price is not None:
            assert b._shutdown_price() == latched_price and b.shutdown_at, "F7 latch must be permanent"
        check_invariants(s, f"oracle fuzz seed {seed} step {i}")
    return counts


def _main():

        seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 200
        steps = int(sys.argv[2]) if len(sys.argv) > 2 else 150
        first = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        tot = {}
        for seed in range(first, first + seeds):
            for k, v in run(seed, steps).items():
                tot[k] = tot.get(k, 0) + v
        print(f"{seeds} seeds x {steps} steps from seed {first}: properties F1-F13 held after every step")
        print(tot)
        # coverage: the outcomes the pool source adds must actually occur, or nothing notices when one stops
        missing = [k for k in ("fallback", "crosschecked", "disagreement", "failed_both_dead", "failed_disagreement")
                   if tot.get(k, 0) == 0]
        assert not missing, f"coverage: never reached {missing}"
        if (seeds, steps, first) == (200, 150, 0):       # the configuration docs/RESULTS.md records
            from figures import fig, dump
            fig("fuzz_oracle_stats", tot)
            print(f"figures: {dump('fuzz_oracle')} recorded")


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
