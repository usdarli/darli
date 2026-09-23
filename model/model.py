"""
Reference model for the Darli core accounting. `docs/SPEC.md` is the reference for the rules.

Exact integer arithmetic only. Every rounding direction is explicit.
Scope, by the rule identifiers of `docs/SPEC.md`: both debt ledgers and the upfront fee (B1-B7), the risk gate (B8, B9),
the built-in debt cap (B11), redemption (R1-R7), the Stability Pool with scale (SP1-SP4), liquidation, redistribution and
bad debt (L1-L5), shutdown (L6, L7), the oracle decision procedure (O1-O6), revenue, frontends and staking (V1-V6),
staged settlement after a shutdown (X1-X12) and the one-shot deployment (D1-D4).

Not modelled (out of v1 accounting scope or pure plumbing): sorted linked list
(a Python sort stands in for it), batch managers, gas deposit in wrapped native,
collateral decimals != 18, governance voting, DEX layer.

Where `docs/SPEC.md` is silent or ambiguous, the choice made here is tagged
with  # SPEC-GAP <n>  at the line that makes the choice; the open ones are listed in `docs/SPEC.md` 13.
"""
import copy
from collections import defaultdict
from decimal import Decimal, getcontext

WAD = 10**18
YEAR = 365 * 24 * 3600
DAY = 24 * 3600

P_PRECISION = 10**36
SCALE_FACTOR = 10**9
P_FLOOR = 10**27
MAX_SCALE_DIFF = 8               # 1e9**8 is the largest divisor that fits in 256 bits
SCALE_SPAN = MAX_SCALE_DIFF      # gains are read over every scale in which the deposit is alive
L_PRECISION = 10**36             # redistribution accumulators
MIN_SP_RESIDUAL = 10**18
MAX_SP_DEPOSITS = 10**30
CAP_PERIOD = 30 * 24 * 3600      # the built-in cap doubles at most once per period
DUST_THRESHOLD = 10**12          # raw units; SPEC-GAP 7: value not given in the paper

VALID, NETWORK_UNSTABLE, PRICE_INVALID, FAILED = "Valid", "NetworkUnstable", "PriceInvalid", "Failed"
ACTIVE, ZOMBIE, CLOSED_OWNER, CLOSED_LIQ = "Active", "Zombie", "ClosedByOwner", "ClosedByLiquidation"
CLOSED_SETTLED = "ClosedBySettlement"


CURRENT_SYSTEM = None


class Revert(Exception):
    pass


def require(cond, msg):
    if not cond:
        raise Revert(msg)


def ceil_div(a, b):
    return -(-a // b)


class Clock:
    def __init__(self):
        self.now = 1_700_000_000

    def warp(self, dt):
        assert dt >= 0
        self.now += dt


class Token:
    def __init__(self, name):
        self.name = name
        self.bal = defaultdict(int)
        self.supply = 0

    def mint(self, to, amt):
        assert amt >= 0
        self.bal[to] += amt
        self.supply += amt

    def burn(self, frm, amt):
        assert amt >= 0
        require(self.bal[frm] >= amt, f"{self.name}: burn exceeds balance of {frm}")
        self.bal[frm] -= amt
        self.supply -= amt

    def transfer(self, frm, to, amt):
        assert amt >= 0
        require(self.bal[frm] >= amt, f"{self.name}: transfer exceeds balance of {frm}")
        self.bal[frm] -= amt
        self.bal[to] += amt


class Feed:
    """Mock IPriceFeed. lastGoodPrice exists from construction (SPEC O1)."""

    def __init__(self, price):
        self.price = price
        self.status = VALID
        self.last_good = price

    def fetch(self):
        if self.status == VALID:
            self.last_good = self.price
        return self.price, self.status



# --------------------------------------------------------------------------- #
# Oracle failure DETECTION (7). The mock `Feed` above only injects outcomes;
# this class implements the decision procedure itself.
# --------------------------------------------------------------------------- #
class OutOfGas(Exception):
    pass


class SourceRevert(Exception):
    """A revert that hands `returned` gas back to the caller (0 = cheap, immediate revert not modelled)."""

    def __init__(self, returned=None):
        self.returned = returned


CALL_OVERHEAD = 2_600            # cold account access paid by the caller before anything is forwarded
REST_OF_TX_GAS = 25_000          # what the transaction still needs after the read (at least one storage write)


class Sequencer:
    """L2 sequencer uptime feed: `is_up` and the time of the last status change."""

    def __init__(self, clock):
        self.clock, self.is_up, self.since = clock, True, clock.now - 10**7

    def set(self, up):
        if up != self.is_up:
            self.is_up, self.since = up, self.clock.now


class Source:
    """One external price source. `gas_cost` is what an honest read needs."""

    def __init__(self, clock, value, gas_cost=60_000, nested=False):
        self.clock, self.value, self.updated_at = clock, value, clock.now
        self.nested = nested                    # proxy -> aggregator: the proxy forwards 63/64 and bubbles a failure up
        self.reverts = False
        self.burns_all_gas = False              # e.g. aggregator replaced by code that loops / INVALID opcode
        self.gas_cost = gas_cost

    def push(self, value=None):
        if value is not None:
            self.value = value
        self.updated_at = self.clock.now

    def read(self, gas):
        if self.nested and not self.burns_all_gas:
            inner = (gas - CALL_OVERHEAD) * 63 // 64
            if inner < self.gas_cost:
                # the aggregator runs out of gas, the proxy still holds ~1/64 of ITS gas and reverts with it
                raise SourceRevert(returned=max(gas - CALL_OVERHEAD - inner - 500, 0))
        if self.burns_all_gas or gas < self.gas_cost:
            raise OutOfGas()
        if self.reverts:
            raise SourceRevert()
        return self.value, self.updated_at


class OracleFeed:
    """
    gas_mode:
      "stipend"     (the specification) - every source call gets a fixed FEED_GAS_LIMIT and the transaction must
                    prove up front that it can afford it. An out-of-gas inside the call is then the feed's fault.
      "heuristic64" (the common guard) - forward 63/64 of what is left; in the catch branch revert if
                    gasleft <= gasBefore/64.
      "none"        (mutant) - no guard at all.
    """
    GAS_BUFFER = 20_000

    def __init__(self, clock, sources, staleness, timeout, *, sequencer=None, grace=3600,
                 combine="single", max_skew=None, gas_mode="stipend", feed_gas_limit=200_000):
        self.FEED_GAS_LIMIT = feed_gas_limit    # immutable per feed; must sit well above the honest cost
        assert len(sources) == len(staleness)
        assert all(st < timeout for st in staleness), "stalenessThreshold < ORACLE_FAILURE_TIMEOUT (strict)"
        self.clock, self.sources, self.staleness, self.timeout = clock, sources, staleness, timeout
        self.seq, self.grace, self.combine, self.max_skew, self.gas_mode = sequencer, grace, combine, max_skew, gas_mode
        self.invalid_since = 0
        self.last_valid_at = clock.now
        price, status = self.fetch()
        require(status == VALID, "feed must be healthy at creation")     # 7, item 5
        self.last_good = price

    # -- one guarded source read -> ("ok", value, updated_at) | ("malformed",)
    def _read(self, src):
        gas = self._gas
        if self.gas_mode == "stipend":
            require(gas >= (self.FEED_GAS_LIMIT + CALL_OVERHEAD) * 64 // 63 + self.GAS_BUFFER,
                    "insufficient gas for oracle call")
            forwarded = self.FEED_GAS_LIMIT
        else:
            require(gas > CALL_OVERHEAD, "out of gas")
            forwarded = (gas - CALL_OVERHEAD) * 63 // 64
        try:
            value, updated_at = src.read(forwarded)
            self._gas = gas - CALL_OVERHEAD - min(src.gas_cost, forwarded)
        except (SourceRevert, OutOfGas) as e:
            returned = e.returned if isinstance(e, SourceRevert) and e.returned is not None else (
                forwarded - 5_000 if isinstance(e, SourceRevert) else 0)
            self._gas = gas - CALL_OVERHEAD - forwarded + returned
            if self.gas_mode == "heuristic64":
                require(self._gas > gas // 64, "insufficient gas for external call")
            return ("malformed",)
        if value <= 0 or updated_at > self.clock.now:        # non-positive value or timestamp in the future
            return ("malformed",)
        return ("ok", value, updated_at)

    def _sequencer_ok_for(self, duration):
        return self.seq is None or (self.seq.is_up and self.clock.now - self.seq.since >= duration)

    def fetch(self, gas=10**7):
        now = self.clock.now
        # 1. network first: a sequencer outage makes every feed look stale
        if self.seq is not None and not self._sequencer_ok_for(self.grace):
            return getattr(self, "last_good", 0), NETWORK_UNSTABLE
        # 2. read every source
        self._gas = gas
        reads = [self._read(src) for src in self.sources]
        require(self._gas >= REST_OF_TX_GAS, "out of gas in the rest of the transaction")
        can_fail = self._sequencer_ok_for(self.timeout)
        if any(r[0] == "malformed" for r in reads):
            if self.invalid_since == 0:
                self.invalid_since = now                     # persists only if this transaction does not revert
                return self.last_good, PRICE_INVALID
            if now - self.invalid_since >= self.timeout and can_fail:
                return self.last_good, FAILED
            return self.last_good, PRICE_INVALID
        stamps = [r[2] for r in reads]
        stale = any(now - ts > st for ts, st in zip(stamps, self.staleness))
        skewed = self.max_skew is not None and max(stamps) - min(stamps) > self.max_skew
        if stale or skewed:
            # a well-formed but old answer neither sets nor clears the malformed marker
            if now - min(stamps) > self.timeout and can_fail:
                return self.last_good, FAILED
            return self.last_good, PRICE_INVALID
        values = [r[1] for r in reads]
        if self.combine == "single":
            price = values[0]
        elif self.combine == "ratio":                        # COLL/USD divided by REF/USD
            price = values[0] * WAD // values[1]
        else:                                                # "product": LST/ETH times ETH/USD
            price = values[0] * values[1] // WAD
        self.last_good, self.last_valid_at, self.invalid_since = price, now, 0
        return price, VALID

    # ground truth helpers for tests (not part of the contract)
    def truly_healthy(self):
        now = self.clock.now
        ok = all((not s.reverts) and (not s.burns_all_gas) and s.value > 0 and s.updated_at <= now
                 and now - s.updated_at <= st for s, st in zip(self.sources, self.staleness))
        if ok and self.max_skew is not None:
            stamps = [s.updated_at for s in self.sources]
            ok = max(stamps) - min(stamps) <= self.max_skew
        return ok and self._sequencer_ok_for(self.grace)

# --------------------------------------------------------------------------- #
# Frontend registry (SPEC V2)
# --------------------------------------------------------------------------- #
class FrontendRegistry:
    ADDR = "FrontendRegistry"

    def __init__(self, stable, share):
        self.stable = stable
        self.share = share                      # FRONTEND_SHARE, immutable
        self.frontends = {}                     # id -> dict(payout, kickback)
        self.claimable = defaultdict(int)
        self.next_id = 1
        self.total_deposited = 0
        self.total_credited = 0

    def register(self, payout, kickback):
        require(0 <= kickback <= WAD, "kickback range")
        fid = self.next_id
        self.next_id += 1
        self.frontends[fid] = dict(payout=payout, kickback=kickback)
        return fid

    def increase_kickback(self, fid, new):
        require(self.frontends[fid]["kickback"] <= new <= WAD, "kickback can only increase")
        self.frontends[fid]["kickback"] = new

    def deposit_part(self, x):
        """Called at mint time. Rounds UP so deposits always cover credits."""
        part = ceil_div(x * self.share, WAD)
        self.total_deposited += part
        return part

    def credit(self, fid, owner, x):
        reward = x * self.share // WAD          # rounds DOWN
        self.total_credited += reward
        if fid == 0:
            # SPEC V2: no frontend brought this Trove (a command-line or self-written client), so its share goes back to
            # the owner, exactly as a self-referral with full kickback would
            self.claimable[owner] += reward
            return
        fe = self.frontends[fid]
        to_owner = reward * fe["kickback"] // WAD
        self.claimable[owner] += to_owner
        self.claimable[fe["payout"]] += reward - to_owner

    def claim(self, who):
        amt = self.claimable[who]
        self.claimable[who] = 0
        self.stable.transfer(self.ADDR, who, amt)
        return amt


# --------------------------------------------------------------------------- #
# Stability Pool (SPEC 6.1)
# --------------------------------------------------------------------------- #
class StabilityPool:
    def __init__(self, branch):
        self.branch = branch
        self.addr = f"SP:{branch.name}"
        self.total = 0
        self.P = P_PRECISION
        self.scale = 0
        self.S = defaultdict(int)               # scale -> coll per unit deposit
        self.B = defaultdict(int)               # scale -> yield per unit deposit
        self.err_coll = 0
        self.err_yield = 0
        self.deps = {}                          # who -> dict(amount, P, scale, S, B)
        self.claim_coll = defaultdict(int)
        self.claim_yield = defaultdict(int)

    # -- views ---------------------------------------------------------------
    def _gain(self, acc, d, snap_key):
        s = d["scale"]
        total = acc[s] - d[snap_key]
        for i in range(1, min(SCALE_SPAN, self.scale - s) + 1):
            total += acc[s + i] // SCALE_FACTOR ** i
        return d["amount"] * total // d["P"]

    def compounded(self, who):
        d = self.deps.get(who)
        if not d or d["amount"] == 0:
            return 0
        diff = self.scale - d["scale"]
        if diff > MAX_SCALE_DIFF:
            return 0
        v = d["amount"] * self.P // d["P"]
        return v // (SCALE_FACTOR ** diff)

    def pending_coll(self, who):
        d = self.deps.get(who)
        return self._gain(self.S, d, "S") if d and d["amount"] else 0

    def pending_yield(self, who):
        d = self.deps.get(who)
        return self._gain(self.B, d, "B") if d and d["amount"] else 0

    # -- internal ------------------------------------------------------------
    def _settle(self, who):
        comp = self.compounded(who)
        self.claim_coll[who] += self.pending_coll(who)
        self.claim_yield[who] += self.pending_yield(who)
        return comp

    def _snapshot(self, who, amount):
        self.deps[who] = dict(amount=amount, P=self.P, scale=self.scale,
                              S=self.S[self.scale], B=self.B[self.scale])

    # -- user ops ------------------------------------------------------------
    def deposit(self, who, amt):
        br = self.branch
        require(amt > 0, "zero deposit")
        require(br.shutdown_at == 0, "after a shutdown the pool absorbs nothing any more: deposits are closed, withdrawals stay open")
        require(self.total + amt <= MAX_SP_DEPOSITS, "SP deposit domain")
        br._step_a()                            # yield up to now goes to existing depositors
        comp = self._settle(who)
        br.stable.transfer(who, self.addr, amt)
        self.total += amt
        self._snapshot(who, comp + amt)

    def withdraw(self, who, amt):
        self.branch._step_a()
        comp = self._settle(who)
        amt = min(amt, comp)
        self.branch.stable.transfer(self.addr, who, amt)
        self.total -= amt
        self._snapshot(who, comp - amt)
        return amt

    def claim(self, who):
        self.branch._step_a()
        comp = self._settle(who)
        self._snapshot(who, comp)
        c, y = self.claim_coll[who], self.claim_yield[who]
        self.claim_coll[who] = 0
        self.claim_yield[who] = 0
        self.branch.coll.transfer(self.addr, who, c)
        self.branch.stable.transfer(self.addr, who, y)
        return c, y

    # -- branch-only ---------------------------------------------------------
    def credit_yield(self, y):
        if y == 0:
            return
        assert self.total >= MIN_SP_RESIDUAL
        num = y * self.P + self.err_yield
        per = num // self.total
        self.err_yield = num - per * self.total
        self.B[self.scale] += per

    def offset(self, X, coll_x):
        assert 0 < X <= self.total - MIN_SP_RESIDUAL
        D = self.total
        num = coll_x * self.P + self.err_coll
        per = num // D
        self.err_coll = num - per * D
        self.S[self.scale] += per
        numerator = self.P * (D - X)
        new_p = numerator // D
        assert new_p > 0, "P reached zero"
        # loop, and re-divide the scaled numerator so no precision is lost to the first floor
        while new_p < P_FLOOR:
            numerator *= SCALE_FACTOR
            new_p = numerator // D
            self.scale += 1
        self.P = new_p
        self.total -= X
        self.branch.stable.burn(self.addr, X)


# --------------------------------------------------------------------------- #
# Branch (4, 6)
# --------------------------------------------------------------------------- #
class Trove:
    __slots__ = ("id", "owner", "coll", "debt", "rate", "last_debt_update", "last_rate_adjust",
                 "status", "frontend", "stake", "snap_lc", "snap_ld")

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


class Branch:
    def __init__(self, system, name, coll_token, feed, *, mcr, ccr, scr, pen_sp, pen_redist,
                 min_debt, debt_cap, min_rate=WAD // 200, max_rate=WAD * 5 // 2,
                 upfront_period=7 * DAY, cooldown=7 * DAY, urgent_bonus=WAD // 50,
                 liq_bonus=WAD // 200, liq_bonus_cap=2 * WAD, cap_ceiling=None, gas_deposit=0):
        require(scr <= mcr < ccr, "SCR <= MCR < CCR")
        require(pen_sp <= pen_redist <= mcr - WAD, "penalty constraints")
        self.sys, self.name, self.coll, self.feed = system, name, coll_token, feed
        self.stable, self.clock = system.stable, system.clock
        self.mcr, self.ccr, self.scr = mcr, ccr, scr
        self.pen_sp, self.pen_redist = pen_sp, pen_redist
        self.min_debt, self.min_rate, self.max_rate = min_debt, min_rate, max_rate
        self.upfront_period, self.cooldown = upfront_period, cooldown
        self.urgent_bonus, self.liq_bonus, self.liq_bonus_cap = urgent_bonus, liq_bonus, liq_bonus_cap
        self.settle_price = None                # reference price of the staged settlement, fixed once at shutdown
        self.n_open = 0                         # open Troves, maintained incrementally
        self.gas_deposit = gas_deposit          # collateral units posted per Trove; returned on close, paid to the liquidator or settler
        self.gas_pool = 0                       # named vault account holding those deposits
        self.written_off = {}                   # tid -> debt written off after the deadline (see write_off)
        self.claim_units = 0                    # total claims fixed at the end of phase 1
        self.take = 0                           # surplus absorbed into the pot (current)
        self.late_per_unit = 0                  # collateral per claim unit recovered AFTER phase 1 (L_PRECISION)
        self.late_paid = defaultdict(int)
        self.late_pool = 0                      # named vault account behind late_per_unit
        self.par_total = 0                      # collateral that would pay every claim at par (sum of `need`)
        self.holders_total = 0                  # collateral assigned to holders so far (pot + late recoveries)
        self.gas_left = {}                       # tid -> gas deposit still unpaid for that Trove (sum == gas_pool)
        self.gas_paid = defaultdict(int)         # tid -> reward paid out so far (never above the deposit)
        self.gross_of = defaultdict(int)         # each owner's gross surplus at settlement (kept: entitlement = gross * keep)
        self.surplus_paid_amt = defaultdict(int)  # collateral actually paid to each owner from his settlement surplus
        self.contrib_total = 0                   # collateral handed over by settled Troves
        self.units_of = defaultdict(int)        # claim units already exercised by each account
        self.unsettled = 0
        # WHO ABSORBS THE SHORTFALL OF UNDER-WATER TROVES AT SETTLEMENT. DECIDED (owner, 2026-09-22): the healthy borrowers'
        # surplus absorbs it first; every healthy borrower gives up the SAME FRACTION of his surplus; holders take a haircut only
        # when all surplus is used up; surplus is released when phase 1 is complete. This is a deployment constant, not a setting.
        # `False` ("vault parity": surplus protected, the whole shortfall on the holders) is kept ONLY so that tests
        # can show the difference; nothing in the protocol can select it.
        self.settlement_surplus_absorbs = self.SETTLEMENT_SURPLUS_ABSORBS
        self.settle_surplus_pool = 0             # named vault account behind surplus_pending
        self.settle_surplus_gross = 0
        self.settle_short_total = 0
        self.surplus_keep = None                 # fraction (L_PRECISION) of gross surplus that owners keep, fixed when phase 1 ends
        self.vault = f"Vault:{name}"
        self.sp = StabilityPool(self)
        self.created_at = self.clock.now
        self.graduated = False
        # IMMUTABLE SYSTEM: the debt cap raises itself. cap(t) = min(ceiling, cap0 * 2^floor((t - t0) / CAP_PERIOD)).
        # Nobody can raise, lower, pause or retire anything; `debt_cap` is the opening value, `cap_ceiling` the last one.
        self.cap0 = debt_cap
        self.cap_ceiling = cap_ceiling if cap_ceiling is not None else debt_cap
        # branch ledger
        self.agg_debt = 0
        self.agg_w = 0
        self.last_agg_update = self.clock.now
        self.bad_debt = 0
        self.bad_debt_coll = 0
        self.shutdown_at = 0
        self.oracle_failed = False
        # trove ledger
        self.troves = {}
        self.last_zombie = 0                    # at most one partially redeemed zombie is tracked
        self.next_id = 1
        self.vault_accounted = 0               # collateral moved in/out by the protocol itself
        self.active_coll = 0
        self.default_coll = 0
        self.surplus = defaultdict(int)
        # redistribution
        self.total_stakes = 0
        self.stakes_snap = 0
        self.coll_snap = 0
        self.L_coll = 0
        self.L_debt = 0
        self.err_lc = 0
        self.err_ld = 0
        # counters for the epsilon bound
        self.n_step_a = 0
        self.n_step_b = 0
        self.n_redist = 0

    # -- vault bookkeeping ---------------------------------------------------
    def _coll_in(self, frm, amt):
        self.coll.transfer(frm, self.vault, amt)
        self.vault_accounted += amt

    def _coll_out(self, to, amt):
        self.coll.transfer(self.vault, to, amt)
        self.vault_accounted -= amt

    def unaccounted_coll(self):
        return self.coll.bal[self.vault] - self.vault_accounted

    # There is NO skim. Collateral sent straight to the vault by mistake belongs to nobody and, in a system with no treasury and
    # no owner, has no legitimate destination: it simply stays in the vault, outside every ledger, for ever. A `skim` would
    # have to name a recipient, and naming one is a power this system does not have.

    # -- time / views --------------------------------------------------------
    @property
    def debt_cap(self):
        steps = (self.clock.now - self.created_at) // CAP_PERIOD
        return min(self.cap_ceiling, self.cap0 << min(steps, 64))

    def t_eff(self):
        return min(self.clock.now, self.shutdown_at) if self.shutdown_at else self.clock.now

    def pending_agg_interest(self):
        return ceil_div(self.agg_w * (self.t_eff() - self.last_agg_update), YEAR * WAD)

    def open_troves(self):
        return [t for t in self.troves.values() if t.status in (ACTIVE, ZOMBIE)]

    def pend_debt(self, t):
        return t.stake * (self.L_debt - t.snap_ld) // L_PRECISION

    def pend_coll(self, t):
        return t.stake * (self.L_coll - t.snap_lc) // L_PRECISION

    def accrued(self, t):
        return t.debt * t.rate * (self.t_eff() - t.last_debt_update) // (YEAR * WAD)

    def debt_now(self, t):
        return t.debt + self.accrued(t) + self.pend_debt(t)

    def coll_now(self, t):
        return t.coll + self.pend_coll(t)

    def icr(self, t, price):
        d = self.debt_now(t)
        return 10**40 if d == 0 else self.coll_now(t) * price // d

    def tcr(self, price):
        d = self.agg_debt + self.pending_agg_interest()
        return 10**40 if d == 0 else (self.active_coll + self.default_coll) * price // d

    # -- step A --------------------------------------------------------------
    def _mint_interest_split(self, amount):
        """Same three-way split for aggregate interest and for upfront fees (SPEC V1)."""
        if amount == 0:
            return
        fe = self.sys.frontends.deposit_part(amount)
        sp = amount * self.sys.sp_share // WAD if self.sp.total >= MIN_SP_RESIDUAL else 0
        rest = amount - fe - sp
        assert rest >= 0, "split exceeds amount"
        self.stable.mint(FrontendRegistry.ADDR, fe)
        self.stable.mint(self.sp.addr, sp)
        self.sp.credit_yield(sp)
        self.stable.mint(self.sys.ESCROW, rest)

    def _step_a(self):
        t = self.t_eff()
        p = ceil_div(self.agg_w * (t - self.last_agg_update), YEAR * WAD)
        self.agg_debt += p
        self.last_agg_update = t
        self.n_step_a += 1
        self._mint_interest_split(p)
        return p

    # -- step B --------------------------------------------------------------
    def _compute_stake(self, coll):
        if self.coll_snap == 0:
            return coll
        return coll * self.stakes_snap // self.coll_snap

    def _touch(self, t, d_debt=0, fee=0, new_rate=None, d_coll=0):
        new_rate = t.rate if new_rate is None else new_rate
        a = self.accrued(t)
        r = self.pend_debt(t)
        rc = self.pend_coll(t)
        old_w = t.debt * t.rate
        new_debt = t.debt + a + r + fee + d_debt
        require(new_debt >= 0, "repay exceeds debt")
        if self.shutdown_at == 0:
            self.agg_w += new_debt * new_rate - old_w
        t.debt, t.rate = new_debt, new_rate
        self.agg_debt += fee + d_debt
        t.last_debt_update = self.t_eff()
        # collateral: pending redistribution moves from default to active
        self.default_coll -= rc
        self.active_coll += rc + d_coll
        t.coll += rc + d_coll
        require(t.coll >= 0, "withdraw exceeds collateral")
        t.snap_lc, t.snap_ld = self.L_coll, self.L_debt
        self.total_stakes -= t.stake
        t.stake = self._compute_stake(t.coll)
        self.total_stakes += t.stake
        self.n_step_b += 1
        self.sys.frontends.credit(t.frontend, t.owner, a + fee)
        return a, r

    # -- checks --------------------------------------------------------------
    def _require_price_for_risk(self):
        price, status = self.feed.fetch()
        require(status == VALID, f"risk-increasing op needs valid price (status={status})")
        return price

    def _require_risk_increase_allowed(self, debt_up, coll_down):
        """Single gate for every entry point. Keyed on the effect of the operation:
        a debt increase and/or a collateral decrease."""
        if not (debt_up or coll_down):
            return
        require(self.shutdown_at == 0, "branch shut down")      # the ONLY stop that exists, and only the rules trigger it

    def _require_open_for_debt(self):
        self._require_risk_increase_allowed(True, False)

    def _upfront_fee(self, increase, rate, t=None):
        # avg = (aggW - oldWeight_i + newDebtBeforeFee_i * rate) / (aggDebt + increase)
        denom = self.agg_debt + increase
        if denom == 0:
            return 0
        old_w = t.debt * t.rate if t else 0
        new_debt = (self.debt_now(t) if t else 0) + increase
        avg = (self.agg_w - old_w + new_debt * rate) // denom
        return increase * avg * self.upfront_period // (YEAR * WAD)

    def _after_risk_op(self, t, price):
        require(self.icr(t, price) >= self.mcr, "ICR < MCR")
        require(self.tcr(price) >= self.ccr, "TCR < CCR")

    def _check_shutdown_tcr(self, price):
        if self.shutdown_at == 0 and self.tcr(price) < self.scr:
            self._shutdown()

    # -- borrower ops --------------------------------------------------------
    def open_trove(self, owner, coll, debt, rate, frontend=0, max_fee=None):
        self._require_open_for_debt()
        price = self._require_price_for_risk()
        require(self.min_rate <= rate <= self.max_rate, "rate out of range")
        self._step_a()
        fee = self._upfront_fee(debt, rate)
        require(max_fee is None or fee <= max_fee, "upfront fee > max")
        require(debt + fee >= self.min_debt, "debt < MIN_DEBT")
        require(self.agg_debt + debt + fee <= self.debt_cap, "debt cap")
        tid = self.next_id
        self.next_id += 1
        t = Trove(id=tid, owner=owner, coll=0, debt=0, rate=rate, last_debt_update=self.t_eff(),
                  last_rate_adjust=self.clock.now, status=ACTIVE, frontend=frontend, stake=0,
                  snap_lc=self.L_coll, snap_ld=self.L_debt)
        self.troves[tid] = t
        self.n_open += 1
        if self.gas_deposit:
            self._coll_in(owner, self.gas_deposit)          # posted at opening; pays whoever closes the position out
            self.gas_pool += self.gas_deposit
            self.gas_left[tid] = self.gas_deposit
        self._coll_in(owner, coll)
        self._touch(t, d_debt=debt, fee=fee, d_coll=coll)
        self.stable.mint(owner, debt)
        self._mint_interest_split(fee)
        self._after_risk_op(t, price)
        return tid

    def borrow(self, tid, amount, max_fee=None):
        t = self.troves[tid]
        self._require_open_for_debt()
        price = self._require_price_for_risk()
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        self._step_a()
        fee = self._upfront_fee(amount, t.rate, t)
        require(max_fee is None or fee <= max_fee, "upfront fee > max")
        require(self.agg_debt + amount + fee <= self.debt_cap, "debt cap")
        self._touch(t, d_debt=amount, fee=fee)
        require(t.debt >= self.min_debt, "debt < MIN_DEBT")
        if t.status == ZOMBIE:
            t.status = ACTIVE
            if self.last_zombie == t.id:
                self.last_zombie = 0
        self.stable.mint(t.owner, amount)
        self._mint_interest_split(fee)
        self._after_risk_op(t, price)

    def repay(self, tid, amount):
        """While the branch is live: always allowed, never needs a price (SPEC B9). After a shutdown: settle_trove."""
        require(self.shutdown_at == 0, "after a shutdown a Trove is settled, not repaid (settle_trove)")
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        self._step_a()
        before = self.debt_now(t)
        amount = min(amount, before)
        after = before - amount
        if before >= self.min_debt:
            require(after >= self.min_debt or after == 0, "repay would leave dust debt")
        require(after > 0, "use close_trove to repay in full")   # SPEC-GAP 2
        self.stable.burn(t.owner, amount)
        self._touch(t, d_debt=-amount)

    def add_coll(self, tid, amount):
        require(self.shutdown_at == 0, "after a shutdown a Trove is settled (settle_trove)")
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        self._step_a()
        self._coll_in(t.owner, amount)
        self._touch(t, d_coll=amount)

    def withdraw_coll(self, tid, amount):
        t = self.troves[tid]
        self._require_risk_increase_allowed(False, True)
        price = self._require_price_for_risk()
        self._step_a()
        self._touch(t, d_coll=-amount)
        self._coll_out(t.owner, amount)
        self._after_risk_op(t, price)

    def adjust_trove(self, tid, d_coll=0, d_debt=0, max_fee=None):
        """Combined collateral + debt change, checked once at the end (SPEC B8).
        Below CCR: borrowing only if the resulting TCR >= CCR; a collateral withdrawal only if
        it comes with a repayment worth at least as much."""
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        if d_coll >= 0 and d_debt <= 0:
            if d_coll:
                self.add_coll(tid, d_coll)
            if d_debt:
                self.repay(tid, -d_debt)
            return
        self._require_risk_increase_allowed(d_debt > 0, d_coll < 0)
        price = self._require_price_for_risk()
        self._step_a()
        below = self.tcr(price) < self.ccr
        fee = self._upfront_fee(d_debt, t.rate, t) if d_debt > 0 else 0
        require(max_fee is None or fee <= max_fee, "upfront fee > max")
        if d_debt > 0:
            require(self.agg_debt + d_debt + fee <= self.debt_cap, "debt cap")
        if d_coll > 0:
            self._coll_in(t.owner, d_coll)
        if d_debt < 0:
            self.stable.burn(t.owner, -d_debt)
        before = self.debt_now(t)
        self._touch(t, d_debt=d_debt, fee=fee, d_coll=d_coll)
        if d_debt > 0:
            self.stable.mint(t.owner, d_debt)
            self._mint_interest_split(fee)
            require(t.debt >= self.min_debt, "debt < MIN_DEBT")
        elif before >= self.min_debt:
            require(t.debt >= self.min_debt, "repay would leave dust debt")
        if d_coll < 0:
            self._coll_out(t.owner, -d_coll)
        require(self.icr(t, price) >= self.mcr, "ICR < MCR")
        if below:
            require(d_debt <= 0 or self.tcr(price) >= self.ccr, "TCR < CCR: no borrowing")
            if d_coll < 0:
                require(-d_debt * WAD >= -d_coll * price, "withdrawal not matched by repayment")
        else:
            require(self.tcr(price) >= self.ccr, "TCR < CCR")

    def adjust_rate(self, tid, new_rate, max_fee=None):
        t = self.troves[tid]
        require(self.shutdown_at == 0, "branch shut down")
        require(t.status == ACTIVE, "only active troves can change rate")
        require(new_rate != t.rate, "rate not new")
        require(self.min_rate <= new_rate <= self.max_rate, "rate out of range")
        self._step_a()
        fee = 0
        if self.clock.now < t.last_rate_adjust + self.cooldown:
            price = self._require_price_for_risk()          # fee raises debt -> needs price
            debt = self.debt_now(t)
            # SPEC-GAP 1b: fee on the whole debt at the branch average *after* the change
            extra = debt * new_rate - t.debt * t.rate
            denom = self.agg_debt
            avg = (self.agg_w + extra) // denom if denom else 0
            fee = debt * avg * self.upfront_period // (YEAR * WAD)
            require(max_fee is None or fee <= max_fee, "upfront fee > max")
        self._touch(t, fee=fee, new_rate=new_rate)
        t.last_rate_adjust = self.clock.now
        if fee:
            self._mint_interest_split(fee)
            require(self.icr(t, price) >= self.mcr, "ICR < MCR after fee")
            require(self.tcr(price) >= self.ccr, "TCR < CCR after fee")

    def apply_pending_debt(self, tid):
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        self._step_a()
        self._touch(t)
        if t.status == ZOMBIE and t.debt >= self.min_debt:
            t.status = ACTIVE                   # accrued interest / redistribution lifted it back
            if self.last_zombie == t.id:
                self.last_zombie = 0

    def close_trove(self, tid):
        """While the branch is live: always allowed, never needs a price (SPEC B9). After a shutdown: settle_trove."""
        require(self.shutdown_at == 0, "after a shutdown a Trove is settled, not closed (settle_trove)")
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        self._step_a()
        debt = self.debt_now(t)
        short = 0
        if self.n_open == 1:
            # the last trove of a branch may be short by rounding dust that is stuck in core
            # contracts; the shortfall is parked in badDebt
            short = max(debt - self.stable.bal[t.owner], 0)
            require(short <= DUST_THRESHOLD, "shortfall above dust threshold")
        self.stable.burn(t.owner, debt - short)
        self._touch(t, d_debt=-debt)
        self.agg_debt += short
        self.bad_debt += short
        assert t.debt == 0
        coll = t.coll
        self._remove(t, CLOSED_OWNER)
        self._pay_gas_deposit(tid, t.owner)
        self._coll_out(t.owner, coll)
        self._sweep_dust_if_empty()
        return coll

    def transfer_trove(self, tid, new_owner):
        """TroveNFT runs step B before every transfer (SPEC B1)."""
        t = self.troves[tid]
        self._step_a()
        self._touch(t)
        t.owner = new_owner

    def _remove(self, t, status):
        if self.last_zombie == t.id:
            self.last_zombie = 0
        if self.shutdown_at == 0:
            self.agg_w -= t.debt * t.rate
        self.total_stakes -= t.stake
        self.active_coll -= t.coll
        t.stake, t.coll, t.debt, t.status = 0, 0, 0, status
        self.n_open -= 1

    def _pay_gas_deposit(self, tid, to, part=None):
        """Pays from THIS Trove's remaining deposit only; a Trove can never pay more than it posted."""
        left = self.gas_left.get(tid, 0)
        amt = left if part is None else min(part, left)
        if amt > 0:
            self.gas_left[tid] = left - amt
            self.gas_paid[tid] += amt
            self.gas_pool -= amt
            self._coll_out(to, amt)
        if self.gas_left.get(tid, 0) == 0:
            self.gas_left.pop(tid, None)

    def _sweep_dust_if_empty(self):
        """4.2: when the last trove goes, the rounding remainder is parked in badDebt."""
        if self.n_open:                              # a COUNTER: nothing in the settlement path scans the Troves
            return
        residual = self.agg_debt - self.bad_debt
        assert residual >= 0
        if residual == 0:
            return
        self.bad_debt += residual
        if residual >= DUST_THRESHOLD and self.shutdown_at == 0:
            self._shutdown()

    # -- shutdown ------------------------------------------------------------
    def _shutdown(self):
        if self.shutdown_at:
            return
        self._step_a()
        self.shutdown_at = self.clock.now
        self.agg_w = 0
        # STAGED SETTLEMENT. From here on nobody is paid ahead of anybody else:
        #   phase 1  every open Trove is settled at ONE reference price, fixed now: it hands over collateral worth its debt
        #            (or all it has, if it is under water) to the common pot, and its owner keeps the surplus;
        #   phase 2  once NO Trove is left unsettled, every USDarli claims the same fraction of the pot, in any order.
        # Repaying, closing, liquidating and redeeming against single Troves all stop: each of them would let somebody leave
        # at a better rate than the rest.
        self.unsettled = self.n_open
        if self.unsettled == 0:
            self._end_phase_one()
        try:
            self._settle_price()
        except Revert:
            pass                                   # no definite oracle status yet: fixed by the first settlement instead

    def poke_oracle(self, gas=10**7):
        """Permissionless observation. It is the only path that reliably persists the `invalidSince` marker,
        because borrower operations that meet a bad price revert and take the marker with them."""
        if self.oracle_failed:
            return FAILED
        price, status = self.feed.fetch(gas) if isinstance(self.feed, OracleFeed) else self.feed.fetch()
        if status == FAILED:
            self.oracle_failed = True
            self._shutdown()
        return status

    def trigger_shutdown(self):
        """Permissionless, never reverts (SPEC L6)."""
        price, status = self.feed.fetch()
        if status == FAILED:
            self.oracle_failed = True
            self._shutdown()
        elif status == VALID and self.tcr(price) < self.scr:
            self._shutdown()
        elif self.bad_debt >= DUST_THRESHOLD:
            self._shutdown()

    def _settle_price(self):
        if self.settle_price is None:
            self.settle_price = self._shutdown_price()
        return self.settle_price

    SETTLEMENT_SURPLUS_ABSORBS = True     # the specified constant
    MAX_SETTLE_BATCH = 50
    WRITE_OFF_DELAY = 30 * DAY

    def settle_troves(self, tids, caller):
        """Bounded batch. Every element costs the same: no step of settlement scans the set of Troves."""
        require(0 < len(tids) <= self.MAX_SETTLE_BATCH, "batch size")
        return [self.settle_trove(tid, caller) for tid in tids]

    def settle_trove(self, tid, caller=None):
        """Phase 1, permissionless, constant work per Trove. The caller is paid the Trove's gas deposit. The owner's exit after a
        shutdown: par settlement out of his own collateral at the reference price; what is left is his."""
        require(self.shutdown_at != 0, "branch is live: repay or close instead")
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        price = self._settle_price()
        late = tid in self.written_off
        if late and self.surplus_keep is None:
            # written off, but phase 1 has NOT ended yet (others still unsettled): undo the write-off and settle normally
            # (found by the fuzzer)
            debt, need = self.written_off.pop(tid)
            self.bad_debt -= debt; self.agg_debt -= debt; self.par_total -= need
            if self.settlement_surplus_absorbs:
                self.settle_short_total -= need
            self._touch(t, d_debt=debt)
            self.unsettled += 1
            late = False
        if late:
            debt, need = self.written_off.pop(tid)
            coll, owner = t.coll, t.owner
        else:
            self._touch(t)                         # applies pending redistribution; interest stopped at shutdown
            debt, coll, owner = t.debt, t.coll, t.owner
            need = ceil_div(debt * WAD, price)     # rounded UP, in favour of the holders' pot
        contribution = min(coll, need)
        gross = coll - contribution
        self._remove(t, CLOSED_SETTLED)
        self._pay_gas_deposit(tid, caller if caller is not None else owner)      # whatever this Trove still holds, on every path
        if late:
            self._late_recovery(owner, contribution, gross)
        else:
            self.bad_debt += debt                  # the Trove's debt becomes a claim of ALL holders on the common pot
            self.bad_debt_coll += contribution
            self.par_total += need
            self.contrib_total += contribution
            if self.settlement_surplus_absorbs:
                self.gross_of[owner] += gross
                self.settle_surplus_pool += gross
                self.settle_surplus_gross += gross
                self.settle_short_total += need - contribution
            else:
                self.surplus[owner] += gross
            self.unsettled -= 1
        self._sweep_dust_if_empty()
        if self.unsettled == 0:
            self._end_phase_one()
        return dict(debt=debt, contribution=contribution, surplus=gross, shortfall=need - contribution, late=late)

    def write_off(self, tid, caller=None):
        """THE ONE TROVE THAT CANNOT BE SETTLED MUST NOT HOLD EVERYBODY HOSTAGE. After WRITE_OFF_DELAY anyone may write an
        unsettled Trove off: its debt becomes a claim like every other, its collateral is counted as ZERO for now, and phase 1 can
        end. Nothing is taken from anybody: the Trove can still be settled later, and whatever it then hands over is shared by all
        claim units alike, whether they have already claimed or not (late_per_unit), so equal claims stay equal."""
        require(self.shutdown_at != 0 and self.clock.now >= self.shutdown_at + self.WRITE_OFF_DELAY, "write-off only after the deadline")
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE) and tid not in self.written_off, "nothing to write off")
        debt = self.debt_now(t)
        need = ceil_div(debt * WAD, self._settle_price())
        self._touch(t, d_debt=-debt)               # the debt leaves the Trove ledger ...
        self.agg_debt += debt                      # ... no token was burned, so the branch's debt is unchanged ...
        self.bad_debt += debt                      # ... and it becomes a claim on the pot
        self.par_total += need
        if self.settlement_surplus_absorbs:
            self.settle_short_total += need        # worst case: it hands over nothing
        self.written_off[tid] = (debt, need)
        self.unsettled -= 1
        self._pay_gas_deposit(tid, caller if caller is not None else t.owner, self.gas_deposit // 2)   # half for this step
        if self.unsettled == 0:
            self._end_phase_one()

    def _late_recovery(self, owner, contribution, gross):
        """A written-off Trove is settled after phase 1. The final state must be EXACTLY what a timely settlement would have
        produced, so the totals are recomputed and only the difference is moved:
          holders   : pot' - pot  (pot = contributions + surplus absorbed, capped at par)  -> shared by every claim unit alike
          borrowers : each owner's entitlement is gross_i * keep', where keep' is the recomputed common fraction; owners who were
                      already paid at the old fraction receive the difference when they next claim
        Both are funded by this Trove's own collateral, to the wei (see scenario 29)."""
        coll = contribution + gross
        pot_before = self.contrib_total + self.take
        self.contrib_total += contribution
        if self.settlement_surplus_absorbs:
            self.settle_short_total -= contribution            # the write-off had assumed it hands over nothing
            self.settle_surplus_gross += gross
            self.gross_of[owner] += gross
            self.take = min(self.settle_short_total, self.settle_surplus_gross)
            g = self.settle_surplus_gross
            self.surplus_keep = (g - self.take) * L_PRECISION // g if g else L_PRECISION
        else:
            self.surplus[owner] += gross
        pot_after = self.contrib_total + self.take
        to_holders = pot_after - pot_before                     # >= 0 (proof in RESULTS.md)
        if not (0 <= to_holders <= coll):
            raise AssertionError(f"late recovery bookkeeping: to_holders={to_holders} coll={coll} contrib={contribution} gross={gross} "
                                 f"short={self.settle_short_total} sg={self.settle_surplus_gross} take={self.take} absorbs={self.settlement_surplus_absorbs} "
                                 f"pot_before={pot_before} pot_after={pot_after}")
        if to_holders and self.claim_units:
            self.late_per_unit += to_holders * L_PRECISION // self.claim_units
            self.late_pool += to_holders
        if self.settlement_surplus_absorbs:
            self.settle_surplus_pool += coll - to_holders

    def _end_phase_one(self):
        """All Troves are settled or written off: the totals are final, so the pot and every owner's surplus are fixed once."""
        if self.surplus_keep is not None:
            return
        take = min(self.settle_short_total, self.settle_surplus_gross) if self.settlement_surplus_absorbs else 0
        self.take = take
        self.bad_debt_coll += take
        self.settle_surplus_pool -= take
        gross = self.settle_surplus_gross
        self.surplus_keep = (gross - take) * L_PRECISION // gross if gross else L_PRECISION
        self.claim_units = self.bad_debt

    def _shutdown_price(self):
        if self.oracle_failed:
            return self.feed.last_good
        price, status = self.feed.fetch()
        if status == FAILED:
            self.oracle_failed = True
            return self.feed.last_good
        require(status == VALID, f"shutdown op waits for a definite oracle status ({status})")
        return price

    # -- liquidation (SPEC 6.2) ----------------------------------------------
    def liquidate(self, tid, liquidator):
        t = self.troves[tid]
        require(t.status in (ACTIVE, ZOMBIE), "trove not open")
        require(self.shutdown_at == 0, "after a shutdown Troves are settled, not liquidated (settle_trove)")
        price = self._require_price_for_risk()
        self._step_a()
        self._touch(t)
        debt, coll = t.debt, t.coll
        require(debt > 0, "zero-debt trove has infinite ICR")   # found by the fuzzer
        require(coll * price // debt < self.mcr, "ICR >= MCR")
        bonus = min(coll * self.liq_bonus // WAD, self.liq_bonus_cap)
        coll_avail = coll - bonus
        sp_avail = max(self.sp.total - MIN_SP_RESIDUAL, 0)
        X = min(debt, sp_avail)
        coll_x = min(X * (WAD + self.pen_sp) // price, coll_avail * X // debt)
        Y = debt - X
        coll_y = min(Y * (WAD + self.pen_redist) // price, coll_avail - coll_x)
        surplus = coll_avail - coll_x - coll_y
        owner = t.owner
        self._remove(t, CLOSED_LIQ)
        self._pay_gas_deposit(tid, liquidator)
        self._coll_out(liquidator, bonus)
        if X:
            self._coll_out(self.sp.addr, coll_x)
            self.sp.offset(X, coll_x)
            self.agg_debt -= X
        result = dict(X=X, coll_x=coll_x, Y=Y, coll_y=coll_y, surplus=surplus, bonus=bonus, bad=False)
        if Y:
            if self.total_stakes > 0:
                self._redistribute(Y, coll_y)
            else:
                self.bad_debt += Y
                self.bad_debt_coll += coll_y
                result["bad"] = True
                self._shutdown()
        else:
            surplus += coll_y
            result["surplus"] = surplus
        self.surplus[owner] += surplus
        self.stakes_snap = self.total_stakes
        self.coll_snap = self.active_coll + self.default_coll
        self._sweep_dust_if_empty()
        if self.shutdown_at == 0:
            self._check_shutdown_tcr(price)
        return result

    def _redistribute(self, debt, coll):
        nc = coll * L_PRECISION + self.err_lc
        nd = debt * L_PRECISION + self.err_ld
        pc, pd = nc // self.total_stakes, nd // self.total_stakes
        self.err_lc, self.err_ld = nc - pc * self.total_stakes, nd - pd * self.total_stakes
        self.L_coll += pc
        self.L_debt += pd
        self.default_coll += coll
        self.n_redist += 1

    def claim_surplus(self, who):
        amt = self.surplus[who]
        self.surplus[who] = 0
        if self.gross_of[who]:
            require(self.unsettled == 0 and self.surplus_keep is not None, "surplus is released when settlement phase 1 is complete")
            # entitlement = floor(gross * keep) - amount actually paid. gross only grows (a late Trove of the same owner) and keep
            # only grows (a late recovery lowers the absorbed shortfall), so the entitlement never falls: claiming early, between or
            # after recoveries ends at the same total
            part = self.gross_of[who] * self.surplus_keep // L_PRECISION - self.surplus_paid_amt[who]
            if part > 0:
                self.surplus_paid_amt[who] += part
                self.settle_surplus_pool -= part
                amt += part
        self._coll_out(who, amt)
        return amt

    # -- redemption inside the branch (SPEC 5) ------------------------------------
    def redemption_order(self):
        """SPEC R2: Active Troves, lowest rate first, ties by the lower Trove id. A total order, so the sorted list in
        contracts/ (RateSortedList) holds exactly this sequence whatever hints it was given; export_vectors.py checks it."""
        return sorted((t for t in self.troves.values() if t.status == ACTIVE), key=lambda t: (t.rate, t.id))

    def redeem_from_branch(self, redeemer, amount, price, fee_rate, max_iter, redemption_price=None):
        """`price` decides redeemability (ICR >= 100%); `redemption_price` converts debt to collateral."""
        redemption_price = redemption_price or price
        self._step_a()
        remaining, coll_total, it = amount, 0, 0
        first = [self.troves[self.last_zombie]] if self.last_zombie else []
        queue = first + self.redemption_order()
        for t in queue:
            if remaining == 0 or it >= max_iter:
                break
            it += 1
            if self.icr(t, price) < WAD:
                continue
            R = min(remaining, self.debt_now(t))
            coll_out = R * WAD // redemption_price
            coll_fee = coll_out * fee_rate // WAD
            to_redeemer = coll_out - coll_fee
            c0, d0 = self.coll_now(t), self.debt_now(t)
            self._touch(t, d_debt=-R, d_coll=-to_redeemer)
            # INV-8, checked exactly by cross-multiplication: (c0 - x) / (d0 - R) >= c0 / d0
            assert t.coll * d0 >= c0 * t.debt, "normal redemption lowered the ICR of a trove with ICR >= 100%"
            remaining -= R
            coll_total += to_redeemer
            if t.debt < self.min_debt:
                if t.status == ACTIVE:
                    t.status = ZOMBIE           # includes debt == 0
                    if t.debt > 0:
                        self.last_zombie = t.id  # redeemed first next time
                elif t.debt == 0 and self.last_zombie == t.id:
                    self.last_zombie = 0
        redeemed = amount - remaining
        self.stable.burn(redeemer, redeemed)
        self._coll_out(redeemer, coll_total)
        return redeemed, coll_total

    # -- claims against the bad-debt pot (SPEC X8) ---------------------------------------------
    def redeem_bad_debt_coll(self, who, R, min_coll_out=0):
        require(self.unsettled == 0, "settlement phase 1 is not complete: some Troves are still unsettled")
        require(0 < R <= self.bad_debt, "R out of range")
        # the pot MAY be empty (every Trove written off): burning still registers the claim units, which carry the right to
        # every later recovery
        out = self.bad_debt_coll if R == self.bad_debt else self.bad_debt_coll * R // self.bad_debt
        require(out >= min_coll_out, "minCollOut")
        self.stable.burn(who, R)
        self.bad_debt -= R
        self.agg_debt -= R
        self.bad_debt_coll -= out
        self.units_of[who] += R
        self._coll_out(who, out)
        return out + self.claim_late(who)

    def claim_late(self, who):
        """Whatever written-off Troves hand over later belongs to every claim unit alike, exercised or not."""
        due = self.units_of[who] * self.late_per_unit // L_PRECISION - self.late_paid[who]
        if due > 0:
            self.late_paid[who] += due
            self.late_pool -= due
            self._coll_out(who, due)
        return max(due, 0)

    def repay_bad_debt(self, who, R):
        """Same as redeem_bad_debt_coll with an empty pot (kept for the live-branch dust case)."""
        require(self.bad_debt_coll == 0, "bucket not empty: use redeem_bad_debt_coll")
        return self.redeem_bad_debt_coll(who, R)


# --------------------------------------------------------------------------- #
# Streaming rewards (SPEC 8.2; same model for the LP vault)
# --------------------------------------------------------------------------- #
class EpochStream:
    """Fixed weekly epochs. Whatever is handed over DURING epoch k waits in `queued` and is streamed, second by second, over
    epoch k + 1, at a rate fixed at the boundary. A later hand-over never touches the schedule of an earlier one, so nothing
    (not a one-wei payment every hour, not ordinary frequent revenue) can postpone a payout: everything handed over by time T
    is fully streamed by the end of the following epoch, at most two periods after T.
    Fixed epochs are the point: a stream that re-spreads its unpaid remainder over a fresh period on every hand-over (the
    well-known weakness of Synthetix-style reward streams) lets a permissionless one-wei hand-over postpone payouts for ever."""

    def __init__(self, clock, period):
        self.clock, self.period = clock, period
        self.t0 = self.last = clock.now
        self.rate = 0                 # per second, scaled by the owner's PREC
        self.queued = 0               # waits for the next boundary
        self.idle = 0                 # streamed while nobody held shares: joins the next epoch

    def _epoch_end(self, t):
        return self.t0 + ((t - self.t0) // self.period + 1) * self.period

    def accrue(self, total):
        """Advance to now; returns the per-share increment (scaled). Called before every change of shares, so `total` is
        constant over the interval. At most two loop turns do any work: after that the rate is zero and time is skipped."""
        inc, now = 0, self.clock.now
        while self.last < now:
            end = min(now, self._epoch_end(self.last))
            streamed = self.rate * (end - self.last)
            if total:
                inc += streamed // total
            else:
                self.idle += streamed
            self.last = end
            if (end - self.t0) % self.period == 0:                    # boundary: fix the next epoch's rate
                tot = self.queued + self.idle
                self.rate = tot // self.period
                self.queued, self.idle = tot - self.rate * self.period, 0
            if self.rate == 0 and self.queued == 0 and self.idle == 0:
                self.last = now
        return inc

    def add(self, amount_scaled):
        self.queued += amount_scaled

    def unstreamed(self):
        """Scaled amount not yet streamed: the rest of the running epoch + what waits for the next one."""
        return self.rate * (self._epoch_end(self.last) - self.last if self.rate else 0) + self.queued + self.idle


class StreamingStaking:
    PERIOD = 7 * DAY
    PREC = 10**36

    def __init__(self, clock, reward_token, addr="DarliStaking"):
        self.clock, self.reward, self.addr = clock, reward_token, addr
        self.total = 0
        self.stake_of = defaultdict(int)
        self.stream = EpochStream(clock, self.PERIOD)
        self.rpt = 0
        self.paid = defaultdict(int)
        self.earned = defaultdict(int)

    def _update(self, who=None):
        self.rpt += self.stream.accrue(self.total)
        if who is not None:
            self.earned[who] += self.stake_of[who] * (self.rpt - self.paid[who]) // self.PREC
            self.paid[who] = self.rpt

    def notify_reward(self, funder, amount):
        self._update()
        self.reward.transfer(funder, self.addr, amount)
        self.stream.add(amount * self.PREC)          # queued for the NEXT epoch; no earlier schedule is touched

    def stake(self, who, amt):
        self._update(who)
        self.stake_of[who] += amt
        self.total += amt

    def unstake(self, who, amt):
        """No external calls: exit can never be blocked, accrued reward stays claimable."""
        self._update(who)
        require(self.stake_of[who] >= amt, "unstake exceeds stake")
        self.stake_of[who] -= amt
        self.total -= amt

    def claim(self, who):
        self._update(who)
        amt = self.earned[who]
        self.earned[who] = 0
        self.reward.transfer(self.addr, who, amt)
        return amt

    def liabilities(self):
        """Upper bound of everything still owed: earned, accrued-but-unsettled, and not yet streamed."""
        self._update()
        accrued = sum(self.earned[w] + self.stake_of[w] * (self.rpt - self.paid[w]) // self.PREC for w in list(self.stake_of))
        return accrued + self.stream.unstreamed() // self.PREC + 1


# --------------------------------------------------------------------------- #
# LP vault fee accounting (8). Liquidity maths is out of scope: shares == liquidity units.
# --------------------------------------------------------------------------- #
class LPFeeVault:
    """Three independent per-share accumulators (fee token0, fee token1, protocol incentive).
    Every share change settles first, so history never leaks to newcomers and a leaver keeps what he earned.
    No management or performance fee in v1."""
    PREC = 10**36
    PERIOD = 7 * DAY

    def __init__(self, clock=None):
        self.clock = clock or Clock()
        self.stream = EpochStream(self.clock, self.PERIOD)   # reward tokens paid into the vault: fixed epochs, never re-spread
        self.total = 0
        self.shares = defaultdict(int)
        self.acc = [0, 0, 0]
        self.snap = defaultdict(lambda: [0, 0, 0])
        self.owed = defaultdict(lambda: [0, 0, 0])
        self.unassigned = [0, 0, 0]                 # arrives while total == 0: rolled into the next accrual
        self.principal_out = defaultdict(int)

    def _accrue(self, k, amount):
        amount += self.unassigned[k]
        if self.total == 0:
            self.unassigned[k] = amount
            return
        self.unassigned[k] = 0
        self.acc[k] += amount * self.PREC // self.total

    def _stream(self):
        self.acc[2] += self.stream.accrue(self.total)

    def _settle(self, who):
        self._stream()
        for k in range(3):
            self.owed[who][k] += self.shares[who] * (self.acc[k] - self.snap[who][k]) // self.PREC
            self.snap[who][k] = self.acc[k]

    def collect_fees(self, fee0, fee1):
        self._accrue(0, fee0)
        self._accrue(1, fee1)

    def notify_incentive(self, amount):
        self._stream()
        self.stream.add(amount * self.PREC)

    def deposit(self, who, liquidity, min_price=None, max_price=None):
        uni = getattr(self, "uniswap", None)
        if uni is not None:
            p = uni.pools[self.pool_key]
            # The range check is NOT protection against manipulation: a price pushed to 1.009 is inside the range. It only stops
            # liquidity entering outside the band. Protection is the DEPOSITOR'S OWN bounds, as for any swap: he states the prices
            # he accepts and the call fails otherwise. (Token amounts and the real position maths are not modelled.)
            require(self.range[0] <= p <= self.range[1], "pool price is outside the vault's range")
            require((min_price is None or p >= min_price) and (max_price is None or p <= max_price), "pool price is outside the depositor's own bounds")
            uni.liquidity[self.pool_key] = uni.liquidity.get(self.pool_key, 0) + liquidity
        self._settle(who)
        self.shares[who] += liquidity
        self.total += liquidity

    def withdraw(self, who, liquidity):
        require(self.shares[who] >= liquidity, "withdraw exceeds shares")
        self._settle(who)
        self.shares[who] -= liquidity
        self.total -= liquidity
        self.principal_out[who] += liquidity        # principal leaves on its own path, never mixed with fees

    def pending(self, who):
        self._stream()
        return tuple(self.owed[who][k] + self.shares[who] * (self.acc[k] - self.snap[who][k]) // self.PREC
                     for k in range(3))

    def claim(self, who):
        self._settle(who)
        out = tuple(self.owed[who])
        self.owed[who] = [0, 0, 0]
        return out


def route_revenue(system):
    """DARLI's ONLY role: stakers receive the protocol's share of fee revenue, pro rata to stake.
    Permissionless and stateless: whatever sits in the interest escrow is handed to the staking contract, which streams it
    over the next seven days. There is no vote, no destination list and no discretion anywhere."""
    require(getattr(system, "staking", None) is not None, "no staking destination was fixed at deployment")
    amount = system.stable.bal[system.ESCROW]
    if amount == 0:
        return 0
    system.staking.notify_reward(system.ESCROW, amount)      # the CALLER never chooses where revenue goes
    return amount


# --------------------------------------------------------------------------- #
# System (SPEC 5)
# --------------------------------------------------------------------------- #
def _minute_decay_factor(half_life_minutes):
    getcontext().prec = 60
    return int((Decimal(1) / Decimal(2)) ** (Decimal(1) / Decimal(half_life_minutes)) * WAD)


def dec_pow(base, n):
    """Fixed-point exponentiation by squaring, WAD, rounding half up per multiply."""
    n = min(n, 525_600_000)
    if n == 0:
        return WAD

    def mul(a, b):
        return (a * b + WAD // 2) // WAD
    y, x = WAD, base
    while n > 1:
        if n % 2:
            y = mul(x, y)
        x = mul(x, x)
        n //= 2
    return mul(x, y)


class System:
    ESCROW = "InterestEscrow"
    MAX_BRANCHES = 10

    def __init__(self, clock, *, sp_share=72 * WAD // 100, staker_share=0, frontend_share=3 * WAD // 100,
                 fee_floor=WAD // 200, half_life_hours=6, beta=1, initial_base_rate=0):
        require(sp_share + staker_share + frontend_share <= 90 * WAD // 100, "share constraint")
        global CURRENT_SYSTEM
        CURRENT_SYSTEM = self
        self.clock = clock
        self.stable = Token("uUSD")
        self.sp_share, self.staker_share = sp_share, staker_share
        self.frontends = FrontendRegistry(self.stable, frontend_share)
        self.fee_floor, self.beta = fee_floor, beta
        # --- dynamic beta (study). Policies use ONLY internal, hard-to-fake signals; never a market price.
        #   "fixed"    : beta                                   (the specified behaviour)
        #   "size"     : 4 while supply <= S_LOW, falling linearly (in log2 of supply) to 1 at S_HIGH
        #   "pressure" : 1 + 3 * min(1, R / (THETA * supply)),  R = redeemed volume decayed with a 7-day half-life
        #   "both"     : the larger of the two
        self.beta_policy = "fixed"
        self.redeemed_ema = 0
        self.redeemed_ema_at = clock.now
        self.decay = _minute_decay_factor(half_life_hours * 60)
        self.base_rate = initial_base_rate      # bootstrap protection: decays with the half-life
        self.last_fee_op = clock.now
        self.branches = {}

    def fix_staking_destination(self, staking):
        """Deployment-time wiring, ONCE. There is no way to change where the protocol's revenue goes afterwards."""
        require(getattr(self, "staking", None) is None, "the revenue destination is already fixed")
        self.staking = staking

    BETA_S_LOW, BETA_S_HIGH, BETA_THETA, BETA_EMA_HALFLIFE = 250_000 * WAD, 4_000_000 * WAD, WAD // 10, 7 * DAY

    def _ema_now(self):
        dt = self.clock.now - self.redeemed_ema_at
        return self.redeemed_ema * dec_pow(_minute_decay_factor(self.BETA_EMA_HALFLIFE // 3600 * 60), dt // 60) // WAD if dt else self.redeemed_ema

    def beta_wad(self):
        """beta scaled by WAD. Deterministic, no oracle, no vote."""
        if self.beta_policy == "fixed":
            return self.beta * WAD
        size = pressure = WAD
        sup = max(self.stable.supply, 1)
        if self.beta_policy in ("size", "both"):
            if sup <= self.BETA_S_LOW:
                size = 4 * WAD
            elif sup < self.BETA_S_HIGH:                        # linear in log2(supply): 250k -> 4, 4M -> 1
                import math
                frac = (math.log2(sup) - math.log2(self.BETA_S_LOW)) / (math.log2(self.BETA_S_HIGH) - math.log2(self.BETA_S_LOW))
                size = int((4 - 3 * frac) * WAD)
        if self.beta_policy in ("pressure", "both"):
            pressure = WAD + 3 * min(WAD, self._ema_now() * WAD // (self.BETA_THETA * sup // WAD))
        return max(size, pressure)

    def create_branch(self, name, coll_token, feed, **kw):
        require(len(self.branches) < self.MAX_BRANCHES, "too many branches")
        _, status = feed.fetch()
        require(status == VALID, "feed must be healthy at creation")
        b = Branch(self, name, coll_token, feed, **kw)
        self.branches[name] = b
        return b

    def _decayed_base_rate(self):
        minutes = (self.clock.now - self.last_fee_op) // 60
        return self.base_rate * dec_pow(self.decay, minutes) // WAD, minutes

    def redemption_fee_rate(self, amount):
        decayed, _ = self._decayed_base_rate()
        bumped = min(decayed + amount * WAD * WAD // (self.stable.supply * self.beta_wad()), WAD)
        return min(self.fee_floor + bumped, WAD), bumped

    def redeem(self, redeemer, amount, max_iter=20, max_fee_rate=WAD):
        require(amount > 0 and self.stable.supply > 0, "nothing to redeem")
        live = []
        for b in self.branches.values():
            if b.shutdown_at:
                continue
            price, status = b.feed.fetch()
            if status == VALID and b.tcr(price) >= b.scr:
                live.append((b, price))
        require(live, "no branch with a valid price")
        # SPEC-GAP 4: the fee is fixed from the *requested* amount before redeeming,
        # because the collateral fee of every trove needs the rate up front.
        supply_before = self.stable.supply
        beta_w = self.beta_wad()                 # sampled once: the fee and the base-rate update must use the SAME beta
        unbacked = [max(b.agg_debt - max(b.sp.total - MIN_SP_RESIDUAL, 0), 0) for b, _ in live]
        if sum(unbacked):
            weights = unbacked
            # never redeem more than the total unbacked in one call: beyond that point the
            # proportions would no longer reflect which branch lacks SP backing
            amount = min(amount, sum(unbacked))
        else:
            weights = [b.agg_debt for b, _ in live]
        require(sum(weights) > 0, "no debt to redeem against")
        fee_rate, _ = self.redemption_fee_rate(amount)
        require(fee_rate <= max_fee_rate, "fee rate > max")
        redeemed_total, out = 0, {}
        left_amt, left_w = amount, sum(weights)
        for (b, price), w in zip(live, weights):
            if w == 0:
                continue
            share = left_amt * w // left_w      # running remainder: shares add up to `amount` exactly
            left_amt -= share
            left_w -= w
            if share == 0:
                continue
            red, coll = b.redeem_from_branch(redeemer, share, price, fee_rate, max_iter)
            redeemed_total += red
            out[b.name] = coll
        decayed, minutes = self._decayed_base_rate()
        # state update uses what was *actually* redeemed; otherwise redeem(huge, max_iter=1)
        # would spike baseRate for free
        self.base_rate = min(decayed + redeemed_total * WAD * WAD // (supply_before * beta_w), WAD)
        self.redeemed_ema = self._ema_now() + redeemed_total
        self.redeemed_ema_at = self.clock.now
        if minutes > 0:
            self.last_fee_op = self.clock.now
        return redeemed_total, out


# --------------------------------------------------------------------------- #
# Transaction semantics: a Revert must leave no trace, exactly as on-chain.
# --------------------------------------------------------------------------- #
# --------------------------------------------------------------------------- #
# One-shot deployment. The DEPLOYER touches Uniswap; the core never does.
# --------------------------------------------------------------------------- #
class UniswapStub:
    """Just enough of a v4 PoolManager: anyone may initialise any pool key, once, at any price."""

    def __init__(self):
        self.pools = {}                     # key -> initial price (WAD, quote per stable)

    def initialize(self, key, price_wad):
        require(key not in self.pools, "pool already initialised")
        self.pools[key] = price_wad
        self.liquidity = getattr(self, "liquidity", {})
        self.liquidity.setdefault(key, 0)

    def swap_to_price(self, key, price_wad):
        """A pool with NO liquidity has no resistance: anyone can move its price anywhere for nothing."""
        require(getattr(self, "liquidity", {}).get(key, 0) == 0, "model covers only the empty-pool case")
        self.pools[key] = price_wad


class Deployment:
    """Everything that happens exactly once, in ONE transaction, and leaves nobody with any power afterwards:
       1. create the stablecoin and the branch(es);        2. fix the revenue destination (DARLI staking);
       3. initialise the canonical Uniswap pool USDarli / quote at price 1, no hook, and bind the fixed-range liquidity vault to it;
       4. seal. A second run is impossible, and the core holds no reference to the pool or the vault.
    Doing step 3 inside the deployment is what prevents front-running: before this transaction the token's address does not
    exist, so nobody can have initialised "its" pool at a wrong price."""

    pool_preinitialised = None

    def __init__(self, clock, uniswap, quote="USDC", fee_tier=100, range_bp=100):
        self.clock, self.uniswap, self.quote, self.fee_tier, self.range_bp = clock, uniswap, quote, fee_tier, range_bp
        self.sealed = False
        self.system = self.staking = self.vault = self.pool_key = None

    def run(self, coll_token, feed, **branch_kw):
        require(not self.sealed, "deployment can run only once")
        s = System(self.clock, **branch_kw.pop("system_kw", {}))
        s.create_branch("WETH", coll_token, feed, **branch_kw)
        staking = StreamingStaking(self.clock, s.stable)
        s.fix_staking_destination(staking)
        key = (s.stable.name, self.quote, self.fee_tier, "no-hook")
        # The token's future address is PREDICTABLE (CREATE: deployer address + nonce) and v4 lets anyone initialise any key,
        # so an attacker can initialise this very key first, at any price. Deployment must not depend on winning that race:
        try:
            self.uniswap.initialize(key, WAD)                                # price 1.000
            self.pool_preinitialised = False
        except Revert:
            # a failed initialise proves NOTHING by itself (wrong manager, invalid settings, anything): the pool must demonstrably exist
            require(key in self.uniswap.pools, "initialise failed and the pool does not exist: deployment must not report success")
            self.pool_preinitialised = True
        self.pool_price_observed = self.uniswap.pools[key]                   # what the pool REALLY holds; may differ from the target
        vault = LPFeeVault(self.clock)
        vault.uniswap = self.uniswap
        vault.pool_key, vault.range = key, (WAD - self.range_bp * WAD // 10_000, WAD + self.range_bp * WAD // 10_000)
        self.system, self.staking, self.vault, self.pool_key = s, staking, vault, key
        self.sealed = True
        return s


class Snapshot:
    def __init__(self, root):
        self.memo = {}
        copy.deepcopy(root, self.memo)
        originals = [o for o in self.memo[id(self.memo)] if isinstance(o, MODEL_CLASSES)]
        self.pairs = [(o, self.memo[id(o)]) for o in originals]
        self.inverse = {id(c): o for o, c in self.pairs}

    def _tr(self, v):
        if id(v) in self.inverse:
            return self.inverse[id(v)]
        if isinstance(v, defaultdict):
            d = defaultdict(v.default_factory)
            d.update({self._tr(k): self._tr(x) for k, x in v.items()})
            return d
        if isinstance(v, dict):
            return {self._tr(k): self._tr(x) for k, x in v.items()}
        if isinstance(v, list):
            return [self._tr(x) for x in v]
        if isinstance(v, tuple):
            return tuple(self._tr(x) for x in v)
        return v

    def restore(self):
        for o, c in self.pairs:
            names = c.__slots__ if hasattr(c, "__slots__") else list(vars(c))
            if not hasattr(c, "__slots__"):
                for extra in set(vars(o)) - set(names):
                    delattr(o, extra)
            for n in names:
                setattr(o, n, self._tr(getattr(c, n)))


def atomic(system, fn, *a, **kw):
    """Run fn as one transaction: on Revert every state change is rolled back."""
    snap = Snapshot(system)
    try:
        return fn(*a, **kw)
    except Revert:
        snap.restore()
        raise


# --------------------------------------------------------------------------- #
# Invariants (13)
# --------------------------------------------------------------------------- #
def check_invariants(system, tag=""):
    st = system.stable
    # INV-1
    assert st.supply == sum(b.agg_debt for b in system.branches.values()), f"INV-1 {tag}"
    report = {}
    for b in system.branches.values():
        open_t = b.open_troves()
        # INV-2 (holds at any instant, pending interest on both sides)
        lhs = b.agg_debt + b.pending_agg_interest()
        rhs = sum(b.debt_now(t) for t in open_t) + b.bad_debt
        eps = lhs - rhs
        assert eps >= 0, f"INV-2 eps<0 ({eps}) {tag}"
        # INV-3
        expect_w = 0 if b.shutdown_at else sum(t.debt * t.rate for t in open_t)
        assert b.agg_w == expect_w, f"INV-3 {tag}"
        # INV-4
        for name in ("bad_debt_coll", "settle_surplus_pool", "gas_pool", "late_pool", "default_coll", "active_coll"):
            assert getattr(b, name) >= 0, f"INV-20 named pool {name} negative {tag}"
        assert b.gas_pool == sum(b.gas_left.values()), f"INV-21 gas pool != sum of per-Trove deposits {tag}"
        assert all(v <= b.gas_deposit for v in b.gas_paid.values()), f"INV-22 a Trove paid more reward than its deposit {tag}"
        owed = sum(t.coll for t in open_t) + b.default_coll + sum(b.surplus.values()) + b.bad_debt_coll + b.settle_surplus_pool + b.gas_pool + b.late_pool
        assert b.vault_accounted == owed, f"INV-4 accounted {b.vault_accounted} != named accounts {owed} {tag}"
        assert b.coll.bal[b.vault] >= b.vault_accounted, f"INV-4 balance below accounted {tag}"
        assert b.bad_debt > 0 or b.bad_debt_coll == 0, f"INV-19 ownerless badDebtColl {tag}"
        assert b.active_coll == sum(t.coll for t in open_t), f"activeColl {tag}"
        assert b.default_coll >= sum(b.pend_coll(t) for t in open_t), f"defaultColl {tag}"
        # INV-5
        sp = b.sp
        assert sp.P > 0, f"INV-5 P {tag}"
        comp = sum(sp.compounded(w) for w in sp.deps)
        assert sp.total >= comp, f"INV-5 compounded {tag}"
        y = sum(sp.pending_yield(w) for w in sp.deps) + sum(sp.claim_yield.values())
        assert st.bal[sp.addr] >= sp.total + y, f"INV-5 stable balance {tag}"
        c = sum(sp.pending_coll(w) for w in sp.deps) + sum(sp.claim_coll.values())
        assert b.coll.bal[sp.addr] >= c, f"INV-5 coll balance {tag}"
        report[b.name] = dict(eps=eps, n_a=b.n_step_a, n_b=b.n_step_b, n_r=b.n_redist)
    # INV-17
    fe = system.frontends
    assert st.bal[fe.ADDR] >= sum(fe.claimable.values()), f"INV-17 {tag}"
    assert fe.total_deposited >= fe.total_credited, f"INV-17 totals {tag}"
    return report


MODEL_CLASSES = (EpochStream, UniswapStub, Deployment, LPFeeVault, Sequencer, Source, OracleFeed, Token, Feed, FrontendRegistry, StabilityPool, Trove, Branch, System, Clock,
                 StreamingStaking)
