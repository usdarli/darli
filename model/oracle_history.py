"""
The oracle thresholds of SPEC O7/O8 against a year of Base history (their SPEC 2 values).   python3 oracle_history.py

For many past blocks it reads what the two-source feed would have read -- the Chainlink ETH/USD answer and, from the four
pools of the fork test, the pool source's weighted median for windows of 5, 10 and 30 minutes -- and records how far the
two were apart. The pool arithmetic is the model's own (`pool_twap_quote`, `pool_twap_price`), so the numbers are the
contract's. Samples: the hourly Chainlink answer over the year locates the fastest markets; every minute for three hours
around the sixteen fastest, and four hundred random blocks for the ordinary days.

Needs an archive RPC endpoint (network access; standard library only). The output is committed under results/ and hashed
in the manifest; study_figures.py turns it into the figures the documents quote. CI does not re-run it.
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import json  # noqa: E402
import random  # noqa: E402
import ssl  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
import urllib.request  # noqa: E402

from model import pool_twap_quote, pool_twap_price  # noqa: E402

END = 51_380_224                      # the fork tests' pinned block
GENESIS_TS, BLOCK_TIME = 1686789347, 2
DAYS = 365
HOUR_BLOCKS = 1800
FEED = "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70"          # Chainlink ETH/USD on Base, 8 decimals
POOLS = {                                                     # all WETH/6-decimal stablecoin, WETH is token0
    "uni_usdc_005": "0xd0b53D9277642d899DF5C87A3966A349A798F224",
    "uni_usdc_03": "0x6c561B446416E1A00E8E93E221854d6eA4171372",
    "aero_usdc": "0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59",
    "aero_usdt": "0x9785eF59E2b499fB741674ecf6fAF912Df7b3C1b",
}
WINDOWS = (1800, 600, 300)            # observe([1800, 600, 300, 0]) in one call
POOL_STALENESS = 3600                 # the fork test's placeholder
MIN_DEPTH = 10**6 * 10**18            # the fork test's placeholder: a million dollars of weight
EPISODES = 16
ENDPOINTS = ["https://base-mainnet.public.blastapi.io", "https://base.drpc.org", "https://base.meowrpc.com"]
OUT = "results/oracle_history.jsonl"

_ctx = ssl.create_default_context(cafile="/root/.ccr/ca-bundle.crt") if _os.path.exists("/root/.ccr/ca-bundle.crt") \
    else ssl.create_default_context()


def ts_of(block):
    return GENESIS_TS + BLOCK_TIME * block


def rpc_batch(calls):
    """[(method, params)] -> [result or None], trying each endpoint with backoff."""
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)]).encode()
    for attempt in range(30):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]
        try:
            req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "curl/8.5.0"})
            with urllib.request.urlopen(req, context=_ctx, timeout=90) as r:
                out = json.loads(r.read())
            if not isinstance(out, list):
                raise ValueError(str(out)[:200])
            got = {x["id"]: x for x in out}
            if len(got) != len(calls):
                raise ValueError("short batch")
            # a revert is an answer (the pool did not exist, or refused); any other error is the endpoint's, retried
            failed = [i for i in range(len(calls)) if "error" in got[i] and "revert" not in str(got[i]["error"]).lower()]
            if failed:
                raise ValueError(f"{len(failed)} calls failed: {str(got[failed[0]]['error'])[:100]}")
            return [got[i].get("result") for i in range(len(calls))]
        except Exception as e:                                # noqa: BLE001 -- any transport failure: next endpoint
            print(f"  rpc retry {attempt} on {url}: {str(e)[:120]}", file=sys.stderr)
            time.sleep(min(2 ** (attempt // len(ENDPOINTS)), 30))
    raise RuntimeError("every endpoint failed")


def run_calls(calls, chunk=100):
    res = []
    for i in range(0, len(calls), chunk):
        res += rpc_batch(calls[i:i + chunk])
    return res


def call(to, data, block):
    return ("eth_call", [{"to": to, "data": data}, hex(block)])


def words(hexdata):
    if not hexdata or hexdata == "0x":
        return None
    h = hexdata[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def signed(x):
    return x - 2**256 if x >= 2**255 else x


OBSERVE = "0x883bdbfd" + "".join(f"{x:064x}" for x in (0x20, 4, 1800, 600, 300, 0))


def sample(blocks):
    """Every block: Chainlink, and for every pool its last observation time and the three windows."""
    first = []
    for b in blocks:
        first.append(call(FEED, "0xfeaf968c", b))
        for p in POOLS.values():
            first.append(call(p, "0x3850c7bd", b))
            first.append(call(p, OBSERVE, b))
    r1 = run_calls(first)
    per = 1 + 2 * len(POOLS)
    second, index = [], []
    for k, b in enumerate(blocks):
        for j, p in enumerate(POOLS.values()):
            w = words(r1[k * per + 1 + 2 * j])
            if w and len(w) >= 3:
                second.append(call(p, "0x252c09d7" + f"{w[2]:064x}", b))
                index.append((k, j))
    r2 = dict(zip(index, run_calls(second)))
    rows = []
    for k, b in enumerate(blocks):
        now = ts_of(b)
        cl = words(r1[k * per])
        row = {"block": b, "ts": now, "chainlink": cl[1] * 10**10 if cl else None,
               "chainlink_age": now - cl[3] if cl else None, "pools": {}, "median": {}}
        for j, name in enumerate(POOLS):
            obs = words(r1[k * per + 2 + 2 * j])
            last = words(r2.get((k, j)))
            if not obs or len(obs) < 12 or not last:
                continue
            tc, spl = [signed(x) for x in obs[3:7]], obs[8:12]
            age = now - last[0]
            q = {}
            for i, win in enumerate(WINDOWS):
                out = pool_twap_quote(tc[3] - tc[i], spl[3] - spl[i], win, True, 6)
                q[str(win)] = [out[0], out[1]] if out else None
            row["pools"][name] = {"age": age, "q": q}
        for win in WINDOWS:
            quotes = [tuple(v["q"][str(win)]) for v in row["pools"].values()
                      if v["age"] <= POOL_STALENESS and v["q"][str(win)] is not None]
            row["median"][str(win)] = pool_twap_price(quotes, MIN_DEPTH)
        rows.append(row)
    return rows


def main():
    for b in (END, END - 10**7):
        blk = rpc_batch([("eth_getBlockByNumber", [hex(b), False])])[0]
        assert int(blk["timestamp"], 16) == ts_of(b), "Base block times are not what this study assumes"
    # 1. a year of hourly Chainlink answers: where were the fastest markets?
    hours = [END - k * HOUR_BLOCKS for k in range(DAYS * 24, -1, -1)]
    cl = run_calls([call(FEED, "0xfeaf968c", b) for b in hours], chunk=200)
    price = [words(x)[1] if words(x) else None for x in cl]
    moves = []
    for i in range(len(hours) - 1):
        if price[i] and price[i + 1]:
            moves.append((abs(price[i + 1] - price[i]) / price[i], hours[i]))
    moves.sort(reverse=True)
    starts = []
    for mv, b in moves:
        if all(abs(b - s) >= 12 * HOUR_BLOCKS for s in starts):
            starts.append(b)
        if len(starts) == EPISODES:
            break
    # 2. every minute for three hours around each, and random ordinary blocks
    rng = random.Random(20261004)
    plan = [(f"episode_{i}", b) for i, s in enumerate(sorted(starts)) for b in range(s - HOUR_BLOCKS, s + 2 * HOUR_BLOCKS + 1, 30)]
    plan += [("baseline", rng.randint(END - DAYS * 24 * HOUR_BLOCKS, END)) for _ in range(400)]
    rows = []
    for i in range(0, len(plan), 40):
        part = plan[i:i + 40]
        for (tag, _), row in zip(part, sample([b for _, b in part])):
            row["tag"] = tag
            rows.append(row)
        print(f"  {len(rows)}/{len(plan)} samples", file=sys.stderr)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(json.dumps({"meta": {"end": END, "days": DAYS, "windows": WINDOWS, "pools": POOLS,
                                     "pool_staleness": POOL_STALENESS, "min_depth": str(MIN_DEPTH),
                                     "hourly_moves_top": [[m, b] for m, b in moves[:EPISODES]]}}) + "\n")
        for row in rows:
            f.write(json.dumps(row) + "\n")
    print(f"wrote {OUT}: {len(rows)} samples, {EPISODES} episodes")


if __name__ == "__main__":
    main()
