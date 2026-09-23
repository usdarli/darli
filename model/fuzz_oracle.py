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
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import random
import sys

from model import (WAD, VALID, PRICE_INVALID, NETWORK_UNSTABLE, FAILED, Clock, Token, System, Revert, atomic,
                   OracleFeed, Source, Sequencer, check_invariants)

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
    feed = OracleFeed(clock, srcs, stale, timeout, sequencer=seq, grace=HOUR,
                      combine="single" if n == 1 else "ratio", max_skew=None if n == 1 else 4 * HOUR,
                      feed_gas_limit=1_200_000)
    weth = Token("WETH")
    b = s.create_branch("WETH", weth, feed, mcr=110 * PCT, ccr=150 * PCT, scr=110 * PCT, pen_sp=5 * PCT,
                        pen_redist=10 * PCT, min_debt=2000 * E, debt_cap=10**7 * E)
    weth.mint("u", 10**4 * E)
    b.open_trove("u", 100 * E, 20_000 * E, 5 * PCT)
    counts = {VALID: 0, PRICE_INVALID: 0, NETWORK_UNSTABLE: 0, FAILED: 0, "revert": 0}
    latched_price = None
    for i in range(steps):
        op = rng.choice(["warp", "warp", "push", "push", "push", "break", "heal", "seq", "poke", "poke", "poke",
                         "lowgas", "borrow", "dead"])
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
        elif op in ("poke", "lowgas", "borrow"):
            healthy = feed.truly_healthy()
            before = (feed.invalid_since, feed.last_good, b.oracle_failed, b.shutdown_at)
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
                after = (feed.invalid_since, feed.last_good, b.oracle_failed, b.shutdown_at)
                assert after == before, f"F6 reverted tx changed oracle state (seed {seed} step {i})"
                continue
            if latched_price is not None:
                assert st in (FAILED, VALID) and b.oracle_failed, f"F7 (seed {seed} step {i})"
                continue
            if healthy:
                assert st == VALID, f"F3/F4 healthy feed observed as {st} with gas {gas} (seed {seed} step {i})"
            if st == VALID and op != "borrow":
                assert healthy, f"F8 Valid reported for an unhealthy feed (seed {seed} step {i})"
            if seq is not None and not (seq.is_up and clock.now - seq.since >= HOUR):
                assert st == NETWORK_UNSTABLE, f"F9 got {st} while the network is unstable (seed {seed} step {i})"
            if st == FAILED:
                assert seq is None or (seq.is_up and clock.now - seq.since >= timeout), f"F1 (seed {seed} step {i})"
                assert clock.now - feed.last_valid_at >= timeout - max(stale), f"F2 (seed {seed} step {i})"
                latched_price = feed.last_good
                assert b.shutdown_at == clock.now and b._shutdown_price() == latched_price, "F7"
            elif op == "poke":
                dead = any(clock.now - x.updated_at > timeout and x.updated_at <= clock.now
                           and not x.reverts and not x.burns_all_gas and x.value > 0 for x in srcs)
                all_readable = all(not x.reverts and not x.burns_all_gas and x.value > 0 and x.updated_at <= clock.now
                                   for x in srcs)
                net_ok = seq is None or (seq.is_up and clock.now - seq.since >= timeout)
                if dead and all_readable and net_ok:
                    raise AssertionError(f"F5 dead feed not reported as Failed (seed {seed} step {i})")
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
        print(f"{seeds} seeds x {steps} steps from seed {first}: properties F1-F9 held after every step")
        print(tot)
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
