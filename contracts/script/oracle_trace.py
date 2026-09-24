"""
Two model-driven vector sets for the oracle (SPEC O2, O3, O7, O8), for OracleTrace.t.sol to replay.

1. A feed trace: the model's OracleFeed with a primary source, a pool source and a sequencer, driven through source
   answers (fresh, old, future-dated, non-positive, reverting, burning its stipend), pool answers (near, far,
   unavailable, reverting), sequencer outages and time. Scripted stretches make every seed meet what the second source
   is for: a disagreement held for a timeout (Failed), a primary that goes stale and then dead (the pools take over),
   a primary malformed for a timeout (the pools take over, its marker kept), both sources dead (Failed), pools dead
   under a live primary (no shutdown). After every step: lastGoodPrice, lastValidAt, the three markers, and for a
   poke the status and price returned.
2. The pool arithmetic of O7: single-pool quotes (tick delta, seconds-per-liquidity delta, window, orientation,
   decimals) and liquidity-weighted medians of up to four quotes against a depth floor.

Imported by export_vectors.py; `build(rng)` returns (feed trace, twap vectors, statistics).
"""
from model import (Clock, Source, PoolSource, Sequencer, OracleFeed, WAD, VALID, NETWORK_UNSTABLE, PRICE_INVALID,
                   FAILED, MAX_TICK, pool_twap_quote, pool_twap_price)

E = WAD
HOUR = 3600
STALE, TIMEOUT, GRACE, DEV = 3 * HOUR, 24 * HOUR, HOUR, 5 * E // 100
STATUS = {VALID: 0, NETWORK_UNSTABLE: 1, PRICE_INVALID: 2, FAILED: 3}
OPS = ["warp", "src_set", "src_mode", "pool_value", "pool_avail", "pool_mode", "seq", "poke"]
SEQ_AGE = 10**7                                   # the model's sequencer has been up this long at the start
LEDGER_LEN = 7
NONE = 9                                          # no status: the step was not a poke


def build(rng):
    clock = Clock()
    start = clock.now
    seq = Sequencer(clock)
    assert seq.since == start - SEQ_AGE
    src = Source(clock, 2000 * E)
    pool = PoolSource(clock, 2010 * E)
    feed = OracleFeed(clock, [src], [STALE], TIMEOUT, sequencer=seq, grace=GRACE, pool_source=pool, max_deviation=DEV)
    ops = {k: [] for k in ("kind", "a", "b")}
    ledger = []
    st = dict(fallback=0, disagreement=0, failed_disagreement=0, failed_both_dead=0, network=0, crosschecked=0,
              pools_dead_primary_live=0)
    by_status = {s: 0 for s in STATUS}

    def record(kind, a=0, b=0, status=NONE, price=0):
        for key, x in zip(ops, (OPS.index(kind), a, b)):
            ops[key].append(x)
        ledger.extend([feed.last_good, feed.last_valid_at, feed.invalid_since, feed.pool_invalid_since,
                       feed.disagree_since, status, price])

    def warp(dt):
        clock.warp(dt)
        record("warp", dt)

    def src_set(value, ts):
        src.value, src.updated_at = value, ts
        record("src_set", value, ts)

    def push(value=None):
        src_set(src.value if value is None else value, clock.now)

    def src_mode(m):
        src.reverts, src.burns_all_gas = m == 1, m == 2
        record("src_mode", m)

    def pool_value(v):
        pool.value = v
        record("pool_value", v)

    def pool_avail(on):
        pool.available = bool(on)
        record("pool_avail", int(on))

    def pool_mode(m):
        pool.reverts, pool.burns_all_gas = m == 1, m == 2
        record("pool_mode", m)

    def seq_set(up):
        seq.set(bool(up))
        record("seq", int(up))

    def poke():
        primary_live = src_healthy()
        pool_live = pool.available and not pool.reverts and not pool.burns_all_gas and pool.value > 0
        price, status = feed.fetch()
        by_status[status] += 1
        if status == VALID:
            if primary_live:
                st["crosschecked" if pool_live else "pools_dead_primary_live"] += 1
            else:
                st["fallback"] += 1
        elif status == PRICE_INVALID and primary_live and pool_live and feed.disagree_since:
            st["disagreement"] += 1
        elif status == FAILED:
            st["failed_disagreement" if primary_live else "failed_both_dead"] += 1
        elif status == NETWORK_UNSTABLE:
            st["network"] += 1
        record("poke", status=STATUS[status], price=price)
        return status

    def src_healthy():
        return (not src.reverts and not src.burns_all_gas and src.value > 0 and src.updated_at <= clock.now
                and clock.now - src.updated_at <= STALE)

    # --- scripted stretches ----------------------------------------------------------------------------------------
    poke()                                                             # both answer and agree
    pool_value(2200 * E); poke()                                      # disagreement starts
    for _ in range(3):
        warp(8 * HOUR); push(); pool_value(2200 * E); poke()          # held a whole timeout: Failed
    pool_value(2000 * E); push(); poke()                              # agreement again: Valid, marker cleared
    warp(STALE + 1); pool_value(1990 * E); poke()                     # a stale primary: PriceInvalid, pools or not
    warp(TIMEOUT - STALE); poke()                                     # dead: the pools take over
    pool_avail(0); poke()                                             # ... until they go too
    warp(TIMEOUT); poke()                                             # both dead a timeout: Failed
    pool_avail(1); push(2000 * E); poke()
    src_mode(1); poke(); warp(TIMEOUT); poke(); warp(HOUR); poke()    # malformed a timeout: pools, marker kept
    src_mode(0); push(); poke()
    pool_mode(1); warp(TIMEOUT); push(); poke(); warp(TIMEOUT); push(); poke()   # pools dead, primary live: Valid
    pool_mode(0); seq_set(0); warp(HOUR); poke(); seq_set(1); warp(GRACE - 1); poke(); warp(1); push(); poke()
    pool_value(src.value * (E + DEV) // E); poke()                   # exactly MAX_DEVIATION apart: still Valid
    pool_value(src.value * (E + DEV) // E + 1); poke()               # one wei more: disagreement
    warp(10 * HOUR); seq_set(0); warp(10 * HOUR); seq_set(1)          # a sequencer outage inside the disagreement
    warp(5 * HOUR); push(); poke()                                    # a timeout on, but up 5h only: not Failed
    warp(TIMEOUT - 5 * HOUR); push(); poke()                          # up a whole timeout: Failed
    pool_value(src.value); poke()

    # --- random operations -----------------------------------------------------------------------------------------
    while len(ops["kind"]) < 420:
        r = rng.random()
        if r < 0.2:
            warp(rng.choice([1, 60, 600, HOUR, STALE, STALE + 1, 5 * HOUR, TIMEOUT - 1, TIMEOUT, TIMEOUT + 1]))
        elif r < 0.38:
            k = rng.random()
            if k < 0.7:
                push(2000 * E * rng.randint(90, 110) // 100)
            elif k < 0.85:
                src_set(rng.choice([0, 2000 * E]), clock.now + rng.choice([0, 1, HOUR]))      # zero or future-dated
            else:
                src_set(src.value, max(clock.now - rng.choice([STALE, TIMEOUT, TIMEOUT + 1]), 0))
        elif r < 0.44:
            src_mode(rng.choice([0, 0, 1, 2]))
        elif r < 0.56:
            base = src.value if src.value > 0 else 2000 * E
            pool_value(base * rng.choice([95, 96, 99, 100, 101, 104, 105, 106, 120, 70]) // 100
                       + rng.choice([0, 0, 1]))
        elif r < 0.62:
            pool_avail(rng.random() < 0.7)
        elif r < 0.66:
            pool_mode(rng.choice([0, 0, 1, 2]))
        elif r < 0.7:
            seq_set(rng.random() < 0.7)
        else:
            poke()
    assert len(ledger) == len(ops["kind"]) * LEDGER_LEN
    assert all(v > 0 for v in st.values()) and all(v > 0 for v in by_status.values()), (st, by_status)
    trace = {"ops": {k: [str(x) for x in v] for k, v in ops.items()}, "ledger": [str(x) for x in ledger],
             "ledgerLen": str(LEDGER_LEN),
             "config": {"start": str(start), "seqSince": str(start - SEQ_AGE), "stale": str(STALE),
                        "timeout": str(TIMEOUT), "grace": str(GRACE), "maxDeviation": str(DEV),
                        "price0": str(2000 * E), "pool0": str(2010 * E)}}
    return trace, twap_vectors(rng), dict(st, steps=len(ops["kind"]), **{f"status_{k}": v for k, v in by_status.items()})


def twap_vectors(rng):
    """O7 arithmetic: single quotes, then weighted medians with a depth floor."""
    q = {k: [] for k in ("tickDelta", "splDelta", "window", "wethIs0", "decimals", "ok", "price", "weight")}
    quotes = []
    for i in range(400):
        window = rng.choice([1, 2, 60, 600, 1800, 3600, 86_400])
        tick = rng.choice([0, 1, -1, rng.randint(-200_000, -195_000), rng.randint(195_000, 200_000),
                           rng.randint(75_000, 80_000), rng.randint(-MAX_TICK, MAX_TICK), MAX_TICK, -MAX_TICK,
                           MAX_TICK + 1, -MAX_TICK - 1])
        tick_delta = tick * window + (rng.randint(-(window - 1), window - 1) if window > 1 else 0)
        spl = rng.choice([0, 1, 1 << 100, rng.randint(1, 2**160 - 1), 2**160 - 1, rng.randint(1, 1 << 90),
                          rng.randint(1 << 60, 1 << 110)])
        weth_is_0 = rng.random() < 0.5
        dec = rng.choice([6, 6, 18, 8])
        out = pool_twap_quote(tick_delta, spl, window, weth_is_0, dec)
        for k, v in zip(q, (tick_delta, spl, window, int(weth_is_0), dec, int(out is not None),
                            out[0] if out else 0, out[1] if out else 0)):
            q[k].append(v)
        quotes.append(out)
    c = {k: [] for k in ("idx", "count", "minDepth", "price")}
    for i in range(200):
        n = rng.randint(1, 4)
        idx = [rng.randrange(len(quotes)) for _ in range(n)]
        chosen = [quotes[j] for j in idx]
        total = sum(x[1] for x in chosen if x)
        min_depth = rng.choice([0, 1, total, total + 1, total // 2, 10**24])
        price = pool_twap_price(chosen, min_depth)
        c["idx"].extend(idx + [0] * (4 - n))
        c["count"].append(n)
        c["minDepth"].append(min_depth)
        c["price"].append(price)
    # crafted medians: equal and near-equal weights in shuffled order, exact half splits (explicit prices and weights)
    m = {k: [] for k in ("prices", "weights", "count", "minDepth", "price")}
    for i in range(120):
        n = rng.randint(1, 4)
        prices = [rng.choice([1, 2, 3, 2000 * E, 2001 * E, rng.randint(1, 10**30)]) for _ in range(n)]
        weights = [rng.choice([1, 1, 2, 3, 10**24, rng.randint(1, 10**24)]) for _ in range(n)]
        min_depth = rng.choice([0, 0, sum(weights), sum(weights) + 1])
        m["prices"].extend(prices + [0] * (4 - n))
        m["weights"].extend(weights + [0] * (4 - n))
        m["count"].append(n)
        m["minDepth"].append(min_depth)
        m["price"].append(pool_twap_price(list(zip(prices, weights)), min_depth))
    assert sum(q["ok"]) > 100 and len(q["ok"]) - sum(q["ok"]) > 20
    assert sum(1 for p in c["price"] if p) > 50 and sum(1 for p in c["price"] if not p) > 20
    as_str = lambda d: {k: [str(x) for x in v] for k, v in d.items()}   # noqa: E731
    return {"quotes": as_str(q), "combos": as_str(c), "medians": as_str(m)}
