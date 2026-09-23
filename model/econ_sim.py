"""
Economic simulation (whitepaper appendix C). Accounting, fees, redemption ordering, liquidation and the Stability Pool are
the REAL reference model (model.py); only behaviour and the market are assumptions, all listed in `Params`.

Scope of the question: does the rate / redemption feedback loop hold the peg for a SMALL launch (100k) on a deep chain
(Base), with automated (AI / MCP) keepers, and which parameters matter?

    python3 econ_sim.py            -> prints the sensitivity table and writes econ_results.json

What this is NOT: a forecast. Behavioural rules are stylised; read the results as "which assumption moves the outcome".
"""
import copy
import json
import math
import random
import statistics
import sys
from dataclasses import dataclass, asdict, replace

from model import WAD, DAY, YEAR, VALID, ACTIVE, ZOMBIE, Clock, Token, Feed, System, Revert, atomic

E = WAD
HOUR = 3600
DAILY_HOOK = None           # set by test_econ_sim.py to check the simulator's own bookkeeping every simulated day


@dataclass
class Params:
    # --- facts / decisions supplied for the launch
    launch_debt: float = 100_000        # first issuance, USD
    avg_trove: float = 4_000            # typical loan; MIN_DEBT stays 2000 unless min_debt is changed
    min_debt: float = 2_000
    eth_sell_slippage: float = 0.0005   # Base: >1bn USD/day DEX volume, redeemed ETH sells with ~5 bps
    gas_usd: float = 0.05               # Base gas per keeper transaction
    keeper_min_profit: float = 1.0      # AI / MCP keepers act on tiny edges, every hour
    mint_arb: bool = True               # keepers also work the UPPER side: open a trove, mint, sell above 1, close near 1
    # --- protocol parameters under test
    beta: int = 1
    # --- LP economics study: liquidity enters and leaves with its return (virtual pool model only)
    hook_fee_k: float = 0.0             # Uniswap v4 beforeSwap hook (study): a trade that pushes the price AWAY from 1 pays
                                        # base fee + k * |1 - price| (capped); a trade TOWARD 1 pays the base fee. 0 = no hook
    hook_fee_cap: float = 0.02
    lp_dynamic: bool = False
    lp_share: float = 0.0               # share of interest paid to the liquidity vault (taken from the stakers' 25%)
    lp_required_return: float = 0.08    # annual return at which outside LPs are indifferent (assumption; swept)
    lp_team_floor: float = 10_000       # capital the team keeps in the pool whatever the return
    beta_policy: str = "fixed"          # "fixed" | "size" | "pressure" | "both"  (dynamic-beta study)
    half_life_h: int = 6
    initial_base_rate: float = 1.0
    fee_floor: float = 0.005
    sp_share: float = 0.72
    frontend_share: float = 0.03
    # --- the stablecoin's own market (the real bottleneck at this size)
    pool_usd: float = 30_000            # LP capital in the stable pool (both sides together)
    concentration: float = 20.0         # 1 = full range; 20 ~ a +-2.5% band
    pool_fee: float = 0.0005
    pool_model: str = "virtual"         # "virtual": constant product on virtual reserves (no range exit)
                                        # "range":   ONE real Uniswap concentrated position [1-w, 1+w]; outside it there is NO liquidity
    range_width: float = 0.01
    self_redeem_max_fee: float = 0.02   # sellers the pool cannot serve redeem directly if the fee is at most this
    feed_outage_hours: int = 0          # feed dead while the NETWORK runs: price-dependent ops blocked, everything else works
    grace_hours: int = 1                # after a sequencer outage: liquidation / redemption / borrowing wait, the rest runs
    # --- pilot budget: finite capital instead of unlimited minting
    cap_initial: float = 0.0            # 0 = unlimited branch cap
    cap_ceiling: float = 0.0            # the built-in schedule doubles cap_initial every 30 days up to this
    sp_seed: float = 0.0                # team deposit into the Stability Pool at t0
    team_collateral_usd: float = 0.0    # 0 = LP trove at 300%
    upper_keeper_budget_usd: float = 1e12
    topup_reserve_frac: float = 1e9     # borrower's spare ETH as a fraction of the initial collateral
    # --- collateral variant (comparison study): the branch's collateral is a SHARE of a full-range ETH/USDC Uniswap position,
    # wrapped outside the core and priced by the fair-LP formula  value = 2*sqrt(k * pETH * pUSDC)  ->  proportional to
    # sqrt(pETH * pUSDC), plus swap fees that accrue to the share. The core is unchanged: it just sees another collateral token.
    oracle_twap_hours: int = 1          # pool-only oracle study: price = mean of the last N hourly observations (1 = no lag)
    oracle_depeg_overstate: float = 0.0 # pool-only oracle quoted in stablecoins: peak overstatement during a 60h quote-asset depeg
    mcr: float = 1.10                   # branch ratios (comparison study: higher MCR with plain ETH)
    ccr: float = 1.50
    scr: float = 1.10
    icr_target_scale: float = 1.0       # borrowers' target ratios are multiplied by this (1.0 = the same 170-280% as before)
    collateral_mode: str = "eth"        # "eth" | "lp"
    lp_fee_apr: float = 0.05            # assumption; swept
    usdc_shock: float = 0.0             # USDC loses this much of its value at the crash (custodial-asset risk enters the backing)
    lp_unwind_cost: float = 0.003       # cost of pulling liquidity out when collateral is paid out; applied to keepers' proceeds
    keep_state: bool = False            # keep a deep copy of the world at shutdown (settlement-order study)
    settlement_surplus_absorbs: bool = True   # who absorbs under-water Troves at settlement: healthy borrowers first (True) or holders only (False)
    outage_hours: int = 0               # sequencer outage that starts with the crash: no liquidations / redemptions meanwhile
    # --- behaviour (assumptions; every one is swept in the sensitivity runs)
    active_frac: float = 0.4            # borrowers who manage their rate
    r_alt: float = 0.06                 # what borrowing costs elsewhere
    y_alt: float = 0.05                 # what holding a dollar earns elsewhere
    k_demand: float = 5.0               # SP demand elasticity to the yield spread
    sell_frac: float = 0.8              # share of fresh debt that is sold (leverage / spending)
    noise: float = 0.002                # hourly random flow, share of supply (std)
    eth_vol: float = 0.7
    # --- scenario
    days: int = 180
    dump_day: int = 60                  # a holder dumps `dump_size` of the supply at once
    dump_size: float = 0.10
    crash_day: int = 0                  # 0 = none
    crash_size: float = 0.40            # spread over `crash_hours`
    crash_hours: int = 24
    seed: int = 0


class Pool:
    """Constant product on virtual reserves (concentration), real inventory tracked separately."""

    def __init__(self, stable, usd_each_side, conc, fee):
        self.stable, self.fee = stable, fee
        self.X = self.Y = usd_each_side * conc   # virtual uUSD / USD
        self.addr = "POOL"

    @property
    def price(self):
        return self.Y / self.X

    def real_stable(self):
        return self.stable.bal[self.addr] / E

    fees_usd = 0.0
    hook_k = 0.0
    hook_cap = 0.02

    def fee_for(self, selling_stable):
        """Asymmetric dynamic fee of the hook. Selling the stable below 1, or buying it above 1, moves the price away from the peg."""
        p = self.price
        away = (selling_stable and p <= 1.0) or ((not selling_stable) and p >= 1.0)
        return min(self.fee + self.hook_k * abs(1 - p), self.hook_cap) if (away and self.hook_k) else self.fee

    def quote_sell(self, a):
        eff = a * (1 - self.fee_for(True))
        return self.Y - self.X * self.Y / (self.X + eff)

    def quote_buy(self, a):                      # USD needed to buy `a` uUSD
        if a >= self.X * 0.98:
            return math.inf
        return (self.X * self.Y / (self.X - a) - self.Y) / (1 - self.fee_for(False))

    def buy(self, who, a):                       # returns USD paid
        a = min(a, self.real_stable() * 0.999, self.X * 0.9)
        if a <= 0:
            return 0.0, 0.0
        f = self.fee_for(False)
        cost = self.quote_buy(a)
        self.fees_usd += cost * f
        self.Y += cost * (1 - f)
        self.X -= a
        self.stable.transfer(self.addr, who, min(int(a * E), self.stable.bal[self.addr]))
        return a, cost

    def sell(self, who, a):                      # returns USD received
        a = min(a, self.stable.bal[who] / E)
        if a <= 0:
            return 0.0
        f = self.fee_for(True)
        eff = a * (1 - f)
        out = self.Y - self.X * self.Y / (self.X + eff)
        self.fees_usd += a * f * self.price
        self.X += eff
        self.Y -= out
        self.stable.transfer(who, self.addr, min(int(a * E), self.stable.bal[who]))
        return out


class RangePool:
    """One Uniswap v3/v4 position on [pa, pb], price = USD per stable. L is constant; fees are kept aside.
    x = L (1/sqrt(p) - 1/sqrt(pb))   stable held        y = L (sqrt(p) - sqrt(pa))   USD held
    At pa the position is 100% stable, at pb 100% USD. Beyond the range nothing can trade here."""

    def __init__(self, stable, capital, width, fee):
        self.stable, self.fee, self.addr = stable, fee, "POOL"
        self.sa, self.sb = math.sqrt(1 - width), math.sqrt(1 + width)
        self.sp = 1.0
        self.L = capital / ((1 - 1 / self.sb) + (1 - self.sa))
        self.capital0 = capital
        self.fees_usd = 0.0
        self.unfilled_sell = self.tried_sell = 0.0

    @property
    def price(self):
        return self.sp ** 2

    @property
    def x(self):
        return self.L * (1 / self.sp - 1 / self.sb)

    @property
    def y(self):
        return self.L * (self.sp - self.sa)

    def initial_stable(self):
        return self.L * (1 - 1 / self.sb)

    def real_stable(self):
        return min(self.x, self.stable.bal[self.addr] / E)

    def at_boundary(self):
        return self.sp <= self.sa * 1.00001 or self.sp >= self.sb * 0.99999

    def quote_sell(self, a):
        room = self.L * (1 / self.sa - 1 / self.sp) / (1 - self.fee)
        if a > room:
            return -math.inf                      # the range cannot absorb it: not executable
        return self.L * (self.sp - 1 / (1 / self.sp + a * (1 - self.fee) / self.L))

    def quote_buy(self, a):
        if a >= self.x * 0.999:
            return math.inf
        inv = 1 / self.sp - a / self.L
        return self.L * (1 / inv - self.sp) / (1 - self.fee)

    def buy(self, who, a):
        a = min(a, self.real_stable() * 0.99)
        if a <= 0:
            return 0.0, 0.0
        cost = self.quote_buy(a)
        if not math.isfinite(cost):
            return 0.0, 0.0
        self.fees_usd += cost * self.fee
        self.sp = 1 / (1 / self.sp - a / self.L)
        self.stable.transfer(self.addr, who, min(int(a * E), self.stable.bal[self.addr]))
        return a, cost

    def sell(self, who, a):
        a = min(a, self.stable.bal[who] / E)
        if a <= 0:
            return 0.0
        self.tried_sell += a
        room = self.L * (1 / self.sa - 1 / self.sp) / (1 - self.fee)      # stable the range can still absorb
        fill = min(a, max(room, 0.0))
        self.unfilled_sell += a - fill
        if fill <= 0:
            return 0.0
        eff = fill * (1 - self.fee)
        new_sp = 1 / (1 / self.sp + eff / self.L)
        out = self.L * (self.sp - new_sp)
        self.fees_usd += fill * self.fee * self.price
        self.sp = max(new_sp, self.sa)
        self.stable.transfer(who, self.addr, min(int(fill * E), self.stable.bal[who]))
        return out

    def lp_value(self):
        return self.x * 1.0 + self.y + self.fees_usd     # stable marked at 1 (it is redeemable), fees included


class Borrower:
    def __init__(self, name, rng, p, passive=None):
        self.name = name
        self.active = (rng.random() < p.active_frac) if passive is None else not passive
        self.target_icr = rng.uniform(1.7, 2.8) * p.icr_target_scale
        self.r_max = p.r_alt + rng.uniform(0.02, 0.08)   # above this the loan is not worth keeping
        self.tid = None
        self.last_rate_change = 0


def keeper_buy(pool, K, who, amount, eth, slippage):
    """Buy `amount` stable for the keeper out of its treasury. Quote first, prove the purchase can be paid (cash, then free
    ETH sold at market minus slippage), and only then trade. A purchase that cannot be funded changes NOTHING."""
    amount = min(amount, pool.real_stable() * 0.99)
    if amount <= 0:
        return False
    cost = pool.quote_buy(amount)
    if not math.isfinite(cost):
        return False
    shortfall = max(cost - K["cash"], 0.0)
    eth_to_sell = shortfall / (eth * (1 - slippage)) if shortfall else 0.0
    if eth_to_sell > K["eth"] + 1e-12:
        return False
    K["eth"] -= eth_to_sell
    K["cash"] += shortfall
    _got, paid = pool.buy(who, amount)
    K["cash"] -= paid
    return True


def settle_system(s, b, pool, feed, eth, borrowers, min_debt, rng, order=None, **_ignored):
    """Staged settlement, exactly as the core specifies it: phase 1 settles every Trove at the reference price fixed at
    shutdown; phase 2 lets every holder claim the SAME fraction of the pot. The order of arrival is random and must not matter.
    `eth` is the market price at that time and is used only to VALUE what people receive."""
    out = {}
    if s.stable.bal[pool.addr]:
        out["lp_stable_at_exit"] = s.stable.bal[pool.addr] / E
        s.stable.transfer(pool.addr, "lp_exit", s.stable.bal[pool.addr])
    for w in list(b.sp.deps):
        b.sp.withdraw(w, 10**40)
        b.sp.claim(w)
    for who in list(s.frontends.claimable):
        if s.frontends.claimable[who]:
            s.frontends.claim(who)
    for c_addr in (s.ESCROW, s.frontends.ADDR):
        if s.stable.bal[c_addr]:
            s.stable.transfer(c_addr, "protocol_recipients", s.stable.bal[c_addr])
    tids = [t.id for t in b.open_troves()]
    rng.shuffle(tids)
    total_coll_value = (b.active_coll + b.default_coll + b.bad_debt_coll) / E * eth
    for tid in tids:
        b.settle_trove(tid, "settlement_keeper")
        for bw in borrowers:
            if bw.tid == tid:
                bw.tid = None
    start = {a: v for a, v in s.stable.bal.items() if v > 0}
    total0 = sum(start.values())
    holders = list(start) if order is None else [a for a in order if a in start] + [a for a in start if a not in order]
    if order is None:
        rng.shuffle(holders)
    got = {}
    for a in holders:
        v = min(s.stable.bal[a], b.bad_debt)
        try:                                   # a dust balance whose share rounds to zero cannot claim (and loses nothing measurable)
            got[a] = (b.redeem_bad_debt_coll(a, v) / E * eth) if (v > 0 and b.bad_debt_coll > 0) else 0.0
        except Revert:
            got[a] = 0.0
    rec = {a: got[a] / (v / E) for a, v in start.items()}
    big = {a: r for a, r in rec.items() if start[a] >= 100 * E}
    wsum = max(sum(start[a] for a in big), 1)
    surplus_value = sum(b.claim_surplus(o) for o in {bw.name for bw in borrowers} | {"lp"}) / E * eth
    out.update(
        holder_recovery=sum(got.values()) / (total0 / E) if total0 else 1.0,
        worst_holder_recovery=min(big.values()) if big else 1.0,
        best_holder_recovery=max(big.values()) if big else 1.0,
        share_losing=sum(start[a] for a in big if big[a] < 0.99) / wsum,
        share_zero=sum(start[a] for a in big if big[a] < 0.01) / wsum,
        lp_recovery=rec.get("lp_exit", 1.0), per_account=rec, start_balances={a: v / E for a, v in start.items()},
        borrowers_surplus_value=surplus_value, total_backing=total_coll_value / (total0 / E) if total0 else 9.9,
        value_out=sum(got.values()), tokens=total0 / E, settlement_liquidations=0,
        reference_vs_market=(b.settle_price / E) / eth if b.settle_price else 1.0)
    return out


def run(p: Params):
    rng = random.Random(p.seed)
    rng_eth = random.Random(p.seed * 7919 + 17)   # the ETH path has its OWN stream: the same seed gives the same market to every policy,
                                                  # whatever the agents do with the behavioural stream (controlled comparisons)
    clock = Clock()
    s = System(clock, fee_floor=int(p.fee_floor * E), sp_share=int(p.sp_share * E), frontend_share=int(p.frontend_share * E), beta=p.beta,
               half_life_hours=p.half_life_h, initial_base_rate=int(p.initial_base_rate * E),
               )
    s.beta_policy = p.beta_policy
    weth = Token("WETH")
    eth = 2000.0                                 # price of ONE UNIT OF COLLATERAL (ETH, or one LP share)
    _hist = []
    under = 2000.0                               # the underlying ETH price path, identical in both collateral modes
    feed = Feed(int(eth * E))
    b = s.create_branch("WETH", weth, feed, mcr=int(p.mcr * E), ccr=int(p.ccr * E), scr=int(p.scr * E),
                        pen_sp=5 * E // 100, pen_redist=10 * E // 100, min_debt=int(p.min_debt * E),
                        debt_cap=int(p.cap_initial * E) if p.cap_initial else 10**12 * E,
                        cap_ceiling=int(p.cap_ceiling * E) if p.cap_initial else None)
    b.settlement_surplus_absorbs = p.settlement_surplus_absorbs
    if p.pool_model == "range":
        pool = RangePool(s.stable, p.pool_usd, p.range_width, p.pool_fee)
    else:
        pool = Pool(s.stable, p.pool_usd / 2, p.concentration, p.pool_fee)
        pool.hook_k, pool.hook_cap = p.hook_fee_k, p.hook_fee_cap
    borrowers, m = [], dict(exits=0, redeemed=0.0, liq=0, arb_profit=0.0, rate_moves=0, opened=0)
    prices, rates, sp_shares, supply_path = [], [], [], []
    lpx = dict(fees=[], last_fees=0.0, cap=[], apr=[])
    # upper-side keeper treasury: a real ledger. ETH is locked as collateral and comes back on close; selling USDarli adds
    # cash, buying it back spends cash; a liquidated keeper trove loses its ETH.
    K = dict(eth=min(p.upper_keeper_budget_usd, 1e15) / eth, cash=0.0, eth0=min(p.upper_keeper_budget_usd, 1e15) / eth)
    x = dict(sp_liq_pnl=0.0, sp_burned=0.0, redistributed=0.0, min_tcr=99.0, boundary_h=0, hours=0,
             max_upper_debt=0.0, first3d_min=9.0, first3d_redeemed=0.0)

    def supply():
        return s.stable.supply / E

    def sell_or_redeem(who, amt):
        """Sell into the pool; what the range cannot absorb is redeemed directly by the seller if the fee is tolerable
        (a holder facing a saturated pool is better off redeeming at 1 - fee than not exiting at all)."""
        out = pool.sell(who, amt)
        if p.pool_model != "range":
            return out
        left = min(amt, s.stable.bal[who] / E) if out == 0 else max(amt - out / max(pool.price, 1e-9), 0)
        left = min(left, s.stable.bal[who] / E)
        if left > 50 and not b.shutdown_at and feed.status == VALID:
            fee, _ = s.redemption_fee_rate(int(left * E))
            if fee / E <= p.self_redeem_max_fee:
                try:
                    red, _ = atomic(s, s.redeem, who, int(left * E), 8)
                    m["self_redeemed"] = m.get("self_redeemed", 0.0) + red / E
                    m["redeemed"] += red / E
                except Revert:
                    pass
        return out

    def open_trove(bw, debt, rate, sell=True):
        coll = debt * bw.target_icr / eth
        weth.mint(bw.name, int(coll * E) + 10)      # token plumbing; for keepers the ETH is debited from the treasury K
        bw.reserve_eth = coll * p.topup_reserve_frac
        try:
            bw.tid = atomic(s, b.open_trove, bw.name, int(coll * E), int(debt * E), int(rate * E))
        except Revert:
            return False
        bw.last_rate_change = clock.now
        m["opened"] += 1
        if sell:
            sell_or_redeem(bw.name, debt * p.sell_frac)
        return True

    def market_rate():
        ts = [t for t in b.open_troves() if t.status == ACTIVE]
        if not ts:
            return p.r_alt
        tot = sum(t.debt for t in ts)
        return sum(t.rate * t.debt for t in ts) / tot / E if tot else p.r_alt

    def percentile_rate(q):
        ts = sorted((t for t in b.open_troves() if t.status == ACTIVE), key=lambda t: t.rate)
        if not ts:
            return p.r_alt
        tot, acc = sum(t.debt for t in ts), 0
        for t in ts:
            acc += t.debt
            if acc >= q * tot:
                return t.rate / E
        return ts[-1].rate / E

    def settle():
        if p.keep_state:
            x["state"] = copy.deepcopy((s, pool, feed, borrowers))   # frozen world at shutdown, for the order study
        x.update(settle_system(s, b, pool, feed, eth, borrowers, p.min_debt, rng))

    def close(bw):
        t = b.troves[bw.tid]
        need = b.debt_now(t) / E * 1.0005 + 1
        have = s.stable.bal[bw.name] / E
        is_keeper = getattr(bw, "keeper", False)
        if have < need:
            if is_keeper:
                if not keeper_buy(pool, K, bw.name, need - have, eth, p.eth_sell_slippage):
                    return                                # cannot fund the buy-back: nothing was traded
            else:
                pool.buy(bw.name, need - have)            # exiting borrowers BUY the stablecoin: this lifts the price
        try:
            coll_back = atomic(s, b.close_trove, bw.tid)
            if is_keeper:
                K["eth"] += coll_back / E
                K["cash"] -= 2 * p.gas_usd
            m["exits"] += 1
            bw.tid = None
            left = s.stable.bal[bw.name] / E
            if left > 1:
                sell_or_redeem(bw.name, left)
        except Revert:
            pass

    # --- launch: the LP seeds the pool, then borrowers arrive during the first week
    lp = Borrower("lp", rng, p, passive=True)
    lp.target_icr = 3.0
    seed = pool.initial_stable() if p.pool_model == "range" else p.pool_usd / 2
    team_debt = max((seed + p.sp_seed) * 1.01, p.min_debt * 1.05)
    if p.team_collateral_usd:
        lp.target_icr = p.team_collateral_usd / team_debt
    open_trove(lp, team_debt, p.r_alt + (0.06 if p.lp_dynamic else 0.0), sell=False)   # LPs keep their Trove away from redemption
    s.stable.transfer("lp", pool.addr, min(s.stable.bal["lp"], int(seed * E)))
    if p.sp_seed:
        b.sp.deposit("lp", min(int(p.sp_seed * E), s.stable.bal["lp"]))
    borrowers.append(lp)
    n0 = max(int(p.launch_debt / p.avg_trove), 3)
    arrivals = sorted(rng.uniform(0, 7 * 24) for _ in range(n0))
    sp_holders = ["h0", "h1", "h2"]
    dumped = False

    for h in range(p.days * 24):
        clock.warp(HOUR)
        # ETH price path
        shock = 0.0
        if p.crash_day and p.crash_day * 24 <= h < p.crash_day * 24 + p.crash_hours:
            shock = math.log(1 - p.crash_size) / p.crash_hours
        under *= math.exp(rng_eth.gauss(0, p.eth_vol / math.sqrt(365 * 24)) + shock)
        if p.collateral_mode == "lp":
            usdc = 1 - p.usdc_shock if (p.crash_day and h >= p.crash_day * 24) else 1.0
            eth = 2000.0 * math.sqrt(under / 2000.0 * usdc) * math.exp(p.lp_fee_apr * h / (365 * 24))
        else:
            eth = under
        _hist.append(eth)
        _seen = sum(_hist[-p.oracle_twap_hours:]) / len(_hist[-p.oracle_twap_hours:])
        if p.oracle_depeg_overstate and p.crash_day and 0 <= h - p.crash_day * 24 <= 60:
            k = h - p.crash_day * 24                       # shape of 11 March 2023: trough after 8h, mostly healed after 46h
            shape = k / 8 if k <= 8 else (1 - 0.69 * (k - 8) / 38 if k <= 46 else 0.31 * (60 - k) / 14)
            _seen *= 1 + p.oracle_depeg_overstate * max(shape, 0.0)
        feed.price = int(_seen * E)                        # what the PROTOCOL believes; `eth` stays the true market value
        t0 = p.crash_day * 24
        in_outage = bool(p.crash_day and p.outage_hours and t0 <= h < t0 + p.outage_hours)
        in_grace = bool(p.crash_day and p.outage_hours and t0 + p.outage_hours <= h < t0 + p.outage_hours + p.grace_hours)
        feed_dead = bool(p.crash_day and p.feed_outage_hours and t0 <= h < t0 + p.feed_outage_hours)
        feed.status = "NetworkUnstable" if (in_outage or in_grace) else ("PriceInvalid" if feed_dead else VALID)
        if b.agg_debt:
            econ = (b.active_coll + b.default_coll + b.bad_debt_coll) / E * eth / ((b.agg_debt + b.pending_agg_interest()) / E)
            x["min_econ_backing"] = min(x.get("min_econ_backing", 99.0), econ)
        if in_outage:
            x["outage_h"] = x.get("outage_h", 0) + 1
            continue                              # sequencer down: the price moves, nobody can transact
        if b.shutdown_at:
            x["shutdown_day"] = h / 24
            x["state_at_shutdown"] = dict(tcr=b.tcr(feed.price) / E, supply=supply(), sp=b.sp.total / E,
                                          bad_debt=b.bad_debt / E, pool_price=pool.price)
            settle()
            break
        # arrivals at launch
        while arrivals and arrivals[0] <= h:
            arrivals.pop(0)
            bw = Borrower(f"b{len(borrowers)}", rng, p)
            if open_trove(bw, max(p.min_debt * 1.05, rng.uniform(0.6, 1.4) * p.avg_trove), max(0.005, rng.gauss(p.r_alt, 0.015))):
                borrowers.append(bw)
        price = pool.price
        # exogenous flow + the one-off dump
        flow = rng.gauss(0, p.noise) * supply()
        if flow > 0:
            pool.buy("noise", flow)
        else:
            sell_or_redeem("noise", -flow)
        if not dumped and h >= p.dump_day * 24:
            dumped = True
            amt = p.dump_size * supply()
            who = max(sp_holders, key=lambda w: b.sp.compounded(w))
            got = b.sp.withdraw(who, int(amt * E)) / E
            sell_or_redeem(who, got)
        # keepers (hourly, automated): liquidations, then redemption arbitrage
        for t in list(b.open_troves()):
            if t.debt > 0 and b.icr(t, feed.price) < b.mcr:
                try:
                    r = atomic(s, b.liquidate, t.id, "keeper")
                    m["liq"] += 1
                    x["sp_burned"] += r["X"] / E
                    x["sp_liq_pnl"] += r["coll_x"] / E * eth - r["X"] / E     # what depositors got minus what they burned
                    x["redistributed"] += 0 if r["bad"] else r["Y"] / E
                    for bw in borrowers:
                        if bw.tid == t.id:
                            bw.tid = None
                except Revert:
                    pass
        price = pool.price
        if price < 1:
            best, best_a = p.keeper_min_profit, 0
            for a in (100, 250, 500, 1000, 2000, 4000, 8000, 15000):
                a = min(a * max(p.launch_debt / 100_000, 0.25), pool.real_stable() * 0.99)
                if a < 50:
                    continue
                fee, _ = s.redemption_fee_rate(int(a * E))
                true_ratio = eth / (feed.price / E)                 # redeemed ETH is worth this much of what the oracle says
                profit = a * (1 - fee / E) * true_ratio * (1 - p.eth_sell_slippage) - pool.quote_buy(a) - 2 * p.gas_usd
                if profit > best:
                    best, best_a = profit, a
            if best_a:
                got, _cost = pool.buy("arb", best_a)
                try:
                    red, _ = atomic(s, s.redeem, "arb", int(got * E), 8)
                    m["redeemed"] += red / E
                    m["arb_profit"] += best
                    left = s.stable.bal["arb"] / E
                    if left > 0.01:
                        sell_or_redeem("arb", left)
                except Revert:
                    sell_or_redeem("arb", s.stable.bal["arb"] / E)
        elif p.mint_arb and price > 1.004 and h % 4 == 0:
            # upper side: no hard ceiling exists, only this capital-intensive trade
            best, best_a = p.keeper_min_profit, 0
            mr_now = market_rate()
            for a_ in [max(p.min_debt * 1.05, x * max(p.launch_debt / 100_000, 0.25)) for x in (2100, 3000, 5000, 8000, 12000, 20000)]:
                out = pool.quote_sell(a_)
                upfront = a_ * mr_now * 7 / 365
                carry = a_ * mr_now * 14 / 365                 # expects to hold ~two weeks
                profit = out - a_ * 1.001 - upfront - carry - 4 * p.gas_usd
                if profit > best:
                    best, best_a = profit, a_
            if best_a:
                need_eth = best_a * 2.2 / eth
                if need_eth > K["eth"]:
                    x["upper_blocked_hours"] = x.get("upper_blocked_hours", 0) + 4     # this branch runs every 4th hour
                else:
                    kb = Borrower(f"mintarb{len(borrowers)}", rng, p, passive=True)
                    kb.target_icr, kb.keeper = 2.2, True
                    if open_trove(kb, best_a, percentile_rate(0.6) + 0.002, sell=False):
                        K["eth"] -= need_eth                      # the keeper's own ETH is locked, nothing is minted for it
                        kb.locked_eth = need_eth
                        K["cash"] += sell_or_redeem(kb.name, best_a)
                        K["cash"] -= 2 * p.gas_usd
                        borrowers.append(kb)
                        m["mint_arb"] = m.get("mint_arb", 0) + 1
        # daily decisions
        if h % 24 == 0:
            if DAILY_HOOK:
                DAILY_HOOK(s, b, pool, K, borrowers, eth)
            price = pool.price
            mr = market_rate()
            # 1. borrowers: zombies, rate management, exits, fresh demand above the peg
            for bw in list(borrowers):
                if bw.tid is None:
                    continue
                t = b.troves[bw.tid]
                if t.status not in (ACTIVE, ZOMBIE):
                    bw.tid = None
                    continue
                if t.status == ZOMBIE:
                    close(bw)
                    continue
                if getattr(bw, "keeper", False):
                    if pool.price <= 1.001:
                        close(bw)
                    continue
                if bw is lp:
                    continue
                # collateral management: active borrowers top up before the liquidation line, passive ones never do
                if bw.active and b.icr(t, feed.price) < int((p.mcr + 0.20) * E) and rng.random() < 0.7:
                    add = (b.debt_now(t) / E * bw.target_icr / eth) - b.coll_now(t) / E
                    if add > 0:
                        add = min(add, getattr(bw, "reserve_eth", 1e18))
                        bw.reserve_eth = getattr(bw, "reserve_eth", 1e18) - add
                        if add <= 0:
                            continue
                        weth.mint(bw.name, int(add * E))
                        b.add_coll(bw.tid, int(add * E))
                        m["topups"] = m.get("topups", 0) + 1
                if not bw.active:
                    continue
                cooled = clock.now - bw.last_rate_change >= 7 * DAY
                my = t.rate / E
                if price < 0.995 and my <= percentile_rate(0.30) and cooled:
                    new = percentile_rate(0.45) + 0.005
                    if new > bw.r_max:
                        close(bw)
                    elif new > my:
                        try:
                            atomic(s, b.adjust_rate, bw.tid, int(new * E))
                            bw.last_rate_change = clock.now
                            m["rate_moves"] += 1
                        except Revert:
                            pass
                elif price > 1.003 and my > max(mr, 0.01) and cooled:
                    try:
                        atomic(s, b.adjust_rate, bw.tid, int(max(my - 0.005, 0.005) * E))
                        bw.last_rate_change = clock.now
                        m["rate_moves"] += 1
                    except Revert:
                        pass
            if price > 1.004 or (price > 0.997 and mr < p.r_alt + 0.01 and rng.random() < 0.15):
                bw = Borrower(f"b{len(borrowers)}", rng, p)
                rate = max(0.005, min(mr, p.r_alt) + rng.uniform(-0.01, 0.01))
                if open_trove(bw, max(p.min_debt * 1.05, rng.uniform(0.6, 1.5) * p.avg_trove) * (3 if price > 1.01 else 1), rate):
                    borrowers.append(bw)
            # 2. holders: Stability Pool demand follows the yield spread
            sup = supply()
            sp_tot = b.sp.total / E
            sp_yield = mr * (b.agg_debt / E) * p.sp_share / max(sp_tot, 1)
            target = sup * min(max(0.25 + p.k_demand * (min(sp_yield, 0.5) - p.y_alt), 0.05), 0.85)
            delta = 0.15 * (target - sp_tot)
            who = rng.choice(sp_holders)
            if delta > 50:
                got, _ = pool.buy(who, delta)
                if got > 1:
                    b.sp.deposit(who, int(got * E))
            elif delta < -50:
                w = max(sp_holders, key=lambda x: b.sp.compounded(x))
                got = b.sp.withdraw(w, int(-delta * E)) / E
                sell_or_redeem(w, got)
            if p.lp_dynamic and p.pool_model == "virtual" and not b.shutdown_at:
                cap = 2 * math.sqrt(pool.X * pool.Y) / p.concentration                # LP capital at par implied by the pool's invariant
                lpx["fees"].append(pool.fees_usd - lpx["last_fees"]); lpx["last_fees"] = pool.fees_usd
                fee_yr = sum(lpx["fees"][-30:]) / max(len(lpx["fees"][-30:]), 1) * 365
                income_yr = p.lp_share * mr * (b.agg_debt / E) + fee_yr
                target = max(p.lp_team_floor, income_yr / p.lp_required_return)
                new_cap = max(cap + 0.05 * (target - cap), 1_000.0)
                scale = new_cap / cap
                need = (scale - 1) * pool.real_stable()                              # LPs bring (or take back) the stable side
                try:
                    if need > 50:                                   # LPs bring stable: first what they hold, then they mint it
                        short = int(need * E) - s.stable.bal["lp"]
                        if short > 0 and lp.tid and b.troves[lp.tid].status == ACTIVE:
                            weth.mint("lp", int(short / E * 3 / eth * E)); b.add_coll(lp.tid, int(short / E * 3 / eth * E))
                            atomic(s, b.borrow, lp.tid, short)
                        have = min(int(need * E), s.stable.bal["lp"])
                        scale = 1 + (have / E) / max(pool.real_stable(), 1)
                        s.stable.transfer("lp", pool.addr, have)
                    elif need < -50:                                # LPs leave: they take their stable side back and hold it
                        s.stable.transfer(pool.addr, "lp", min(int(-need * E), s.stable.bal[pool.addr]))
                    pool.X *= scale; pool.Y *= scale
                except Revert:
                    pass
                lpx["cap"].append(2 * math.sqrt(pool.X * pool.Y) / p.concentration); lpx["apr"].append(income_yr / max(cap, 1))
            rates.append(mr)
            sp_shares.append(sp_tot / max(sup, 1))
            supply_path.append(sup)
        if not b.shutdown_at and b.agg_debt and b.open_troves():
            x["min_tcr"] = min(x["min_tcr"], b.tcr(feed.price) / E)
        x["max_upper_debt"] = max(x["max_upper_debt"], sum(b.debt_now(b.troves[k.tid]) / E for k in borrowers
                                                        if getattr(k, "keeper", False) and k.tid))
        if h < 72:
            x["first3d_min"] = min(x["first3d_min"], pool.price)
            x["first3d_redeemed"] = m["redeemed"]
        if h >= 14 * 24:                          # skip the launch fortnight in the peg statistics
            prices.append(pool.price)
            x["hours"] += 1
            if p.pool_model == "range" and pool.at_boundary():
                x["boundary_h"] += 1

    def lp_pnl(stable_value):
        if p.pool_model != "range":
            return -1
        # the LP's stable is marked three ways: at 1 (nominal), at the pool price (market), and at what it can actually be
        # turned into: 1 - fee floor by redemption in normal times, the realised recovery after a shutdown
        held = x.get("lp_stable_at_exit", pool.x)
        return 100 * ((held * stable_value + pool.y + pool.fees_usd) / pool.capital0 - 1)

    dev = [abs(x - 1) for x in prices] or [0]
    post = prices[(p.dump_day - 14) * 24:] if p.dump_day > 14 else prices
    rec = next((i for i, x in enumerate(post) if i > 2 and abs(x - 1) < 0.005), None)
    return dict(
        mean_dev_pct=100 * statistics.mean(dev),
        within_05=100 * sum(d < 0.005 for d in dev) / len(dev),
        within_1=100 * sum(d < 0.01 for d in dev) / len(dev),
        min_price=min(prices or [1]), max_price=max(prices or [1]),
        dump_recovery_h=rec if rec is not None else -1,
        redeemed_pct_supply=100 * m["redeemed"] / max(statistics.mean(supply_path or [1]), 1),
        exits=m["exits"], opened=m["opened"], liquidations=m["liq"], rate_moves=m["rate_moves"],
        avg_rate_pct=100 * statistics.mean(rates or [0]), sp_share_pct=100 * statistics.mean(sp_shares or [0]),
        final_supply=supply(), bad_debt=b.bad_debt / E,
        # bad debt that its own collateral bucket does NOT cover at the final price = the real loss to holders
        uncovered_bad_debt=max(0.0, b.bad_debt / E - b.bad_debt_coll / E * eth),
        shutdown=bool(b.shutdown_at),
        arb_profit=m["arb_profit"], self_redeemed=m.get("self_redeemed", 0.0),
        lp_capital_mean=statistics.mean(lpx["cap"][60:] or [0]), lp_capital_end=(lpx["cap"] or [0])[-1],
        lp_apr_mean=100 * statistics.mean(lpx["apr"][60:] or [0]),
        # --- loss allocation and capital (asked for by the external review)
        sp_liq_pnl=x["sp_liq_pnl"], sp_burned=x["sp_burned"], redistributed=x["redistributed"],
        min_tcr=x["min_tcr"], upper_keeper_collateral=x["max_upper_debt"] * 2.2,
        first3d_min_price=x["first3d_min"], first3d_redeemed=x["first3d_redeemed"],
        pct_time_at_range_edge=100 * x["boundary_h"] / max(x["hours"], 1) if p.pool_model == "range" else -1,
        unfilled_sell_pct=100 * pool.unfilled_sell / max(pool.tried_sell, 1) if p.pool_model == "range" else -1,
        lp_pnl_nominal_pct=lp_pnl(1.0), lp_pnl_market_pct=lp_pnl(pool.price),
        lp_pnl_settlement_pct=lp_pnl(x.get("lp_recovery", 1 - p.fee_floor)),
        shutdown_day=x.get("shutdown_day", -1.0), holder_recovery=x.get("holder_recovery", 1.0),
        worst_holder_recovery=x.get("worst_holder_recovery", 1.0),
        tcr_at_shutdown=x.get("state_at_shutdown", {}).get("tcr", -1.0),
        upper_blocked_hours=x.get("upper_blocked_hours", 0), 
        min_econ_backing=x.get("min_econ_backing", 99.0), share_losing=x.get("share_losing", 0.0),
        share_zero=x.get("share_zero", 0.0), best_holder_recovery=x.get("best_holder_recovery", 1.0),
        borrowers_surplus_value=x.get("borrowers_surplus_value", 0.0), total_backing_at_settlement=x.get("total_backing", -1.0),
        reference_vs_market=x.get("reference_vs_market", 1.0),
        keeper_pnl_usd=(K["eth"] + sum(getattr(k, "locked_eth", 0) for k in borrowers if getattr(k, "keeper", False) and k.tid)
                        - K["eth0"]) * eth + K["cash"] if p.upper_keeper_budget_usd < 1e11 else 0.0,
        lp_stable_share_end=100 * pool.x / max(pool.x + pool.y, 1) if p.pool_model == "range" else -1,
    )


def avg(results):
    keys = results[0].keys()
    out = {}
    for k in keys:
        vals = [r[k] for r in results]
        out[k] = (sum(vals) / len(vals)) if not isinstance(vals[0], bool) else sum(vals)
    return out


CASES = {
    "BASE: 100k, pool 30k conc x20, beta 1, hl 6h": {},
    "pool full-range (conc x1), same capital": dict(concentration=1.0),
    "pool 10k conc x20 (thin)": dict(pool_usd=10_000),
    "pool 60k conc x50 (deep)": dict(pool_usd=60_000, concentration=50.0),
    "beta 4 (cheaper large redemptions)": dict(beta=4),
    "half-life 2h": dict(half_life_h=2),
    "beta 4 + half-life 2h": dict(beta=4, half_life_h=2),
    "passive borrowers (10% active)": dict(active_frac=0.1),
    "very active borrowers (80%)": dict(active_frac=0.8),
    "weak SP demand (k=1)": dict(k_demand=1.0),
    "strong SP demand (k=12)": dict(k_demand=12.0),
    "slow keepers (min profit 50 USD)": dict(keeper_min_profit=50.0),
    "launch 1M, pool 300k": dict(launch_debt=1_000_000, pool_usd=300_000),
    "ETH crash -40% in 24h (day 90)": dict(crash_day=90),
    "ETH crash + thin pool": dict(crash_day=90, pool_usd=10_000),
    "dump 30% of supply": dict(dump_size=0.30),
    "redemption fee floor 0.25%": dict(fee_floor=0.0025),
    "less selling of fresh debt (50%)": dict(sell_frac=0.5),
    "no upper-side keepers, less selling (50%)": dict(sell_frac=0.5, mint_arb=False),
    "no upper-side keepers, base": dict(mint_arb=False),
    "RECOMMENDED: beta 4, pool 30k conc x50": dict(beta=4, concentration=50.0),
    "RECOMMENDED + ETH crash -40%": dict(beta=4, concentration=50.0, crash_day=90),
    "RECOMMENDED + dump 30%": dict(beta=4, concentration=50.0, dump_size=0.30),
}

if __name__ == "__main__":
    # python3 econ_sim.py <seeds> [first_case] [last_case]   -> appends to econ_results.jsonl (resumable)
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else len(CASES)
    for name, over in list(CASES.items())[lo:hi]:
        res = avg([run(replace(Params(), seed=sd, **over)) for sd in range(seeds)])
        with open("econ_results.jsonl", "a") as f:
            f.write(json.dumps(dict(case=name, seeds=seeds, overrides=over, result=res)) + "\n")
        print(f"{name:46s} mean_dev={res['mean_dev_pct']:.2f}% within1={res['within_1']:.1f}%", flush=True)
