"""
Stability Pool vectors from the reference model, for StabilityPool.t.sol to replay (SPEC SP2, SP4).

The model's `StabilityPool` is driven directly, with a stand-in for its branch, through deposits, withdrawals, claims,
yield credits and offsets. Most offsets take the pool close to MIN_SP_RESIDUAL, so P falls below P_FLOOR again and again
and the pool rescales, several times per offset when the pool is drained hard; one depositor never touches its deposit,
so it is read across more rescalings than MAX_SCALE_DIFF allows and must compound to zero. After every operation the
whole pool is recorded: P, the scale, the carried remainders, the sums of the current scale, and for every depositor the
compounded deposit, the pending and the claimable gains, and both token balances.

Imported by export_vectors.py; `build(rng)` returns the JSON-ready trace and statistics.
"""
from model import (StabilityPool, Token, Revert, atomic, WAD, MIN_SP_RESIDUAL)
import model

E = WAD
N_USERS = 4
STEPS = 400
OPS = ["deposit", "withdraw", "claim", "offset", "credit"]


class StandInBranch:
    """What the pool reads from its branch: the two tokens, whether it is shut down, and step A (a no-op here: the
    yield the branch would mint is credited explicitly by the `credit` operation)."""

    def __init__(self):
        self.name = "X"
        self.stable = Token("USDarli")
        self.coll = Token("WETH")
        self.shutdown_at = 0

    def _step_a(self):
        return 0


class Root:
    """`atomic` snapshots whatever object it is given; the pool and its branch are the whole world here."""

    def __init__(self, sp, br):
        self.sp, self.branch = sp, br


def state(sp, br, users):
    v = [sp.P, sp.scale, sp.total, sp.err_coll, sp.err_yield, sp.S[sp.scale], sp.B[sp.scale],
         br.stable.bal[sp.addr], br.coll.bal[sp.addr]]
    for u in users:
        v += [sp.compounded(u), sp.pending_coll(u), sp.pending_yield(u), sp.claim_coll[u], sp.claim_yield[u],
              br.stable.bal[u], br.coll.bal[u]]
    return v


STATE_LEN = 9 + 7 * N_USERS


def build(rng):
    br = StandInBranch()
    sp = StabilityPool(br)
    root = Root(sp, br)
    users = [f"u{i}" for i in range(N_USERS)]
    ops = {k: [] for k in ("kind", "who", "a", "b", "ok")}
    states = []
    max_scale, rescaling_offsets, multi_rescales = 0, 0, 0

    for step in range(STEPS):
        k = rng.choice(["deposit"] * 5 + ["withdraw"] * 2 + ["claim"] * 2 + ["offset"] * 5 + ["credit"] * 3)
        who = rng.randrange(N_USERS)
        if step == 0:
            k, who = "deposit", 0
        if who == 0 and step > 0 and k in ("deposit", "withdraw", "claim"):
            who = 1 + rng.randrange(N_USERS - 1)          # u0 deposits once, at step 0, and never touches it again
        a = b = 0
        if k == "deposit":
            a = rng.choice([rng.randint(1, 10**6), rng.randint(E, 10**6 * E), rng.randint(10**3 * E, 10**9 * E),
                            rng.randint(10**9 * E, 10**11 * E)])
            if step == 0:
                a = 10**6 * E
            br.stable.mint(users[who], a)                   # the replay mints the same amount before depositing
            fn = lambda: sp.deposit(users[who], a)
        elif k == "withdraw":
            a = rng.choice([rng.randint(1, 10**20), rng.randint(1, 10**27), 2**255])
            fn = lambda: sp.withdraw(users[who], a)
        elif k == "claim":
            fn = lambda: sp.claim(users[who])
        elif k == "offset":
            room = sp.total - MIN_SP_RESIDUAL
            if room <= 0:
                k, a = "credit", 0                          # nothing to absorb: fall through to a (zero) credit
            else:
                # mostly drain close to the residual, so P falls below P_FLOOR and the pool rescales; a large pool drained
                # to exactly the residual while P is near its floor needs more than one rescale in ONE offset (M-5)
                r = rng.random()
                if r < 0.2 and sp.total >= 10**27:
                    a = room
                elif r < 0.75:
                    a = room - rng.randint(0, min(room - 1, 10**6))
                else:
                    a = rng.randint(1, room)
                b = rng.randint(0, 10**24)
                br.coll.mint(sp.addr, b)                    # the branch sends the collateral before the offset
                fn = lambda: sp.offset(a, b)
        if k == "credit":
            if sp.total >= MIN_SP_RESIDUAL:
                a = rng.randint(0, 10**24)
            else:
                a = 0
            br.stable.mint(sp.addr, a)
            fn = lambda: sp.credit_yield(a)
        scale_before = sp.scale
        try:
            atomic(root, fn)
            ok = 1
        except Revert:
            ok = 0
        rescaling_offsets += k == "offset" and sp.scale > scale_before
        multi_rescales += k == "offset" and sp.scale > scale_before + 1
        max_scale = max(max_scale, sp.scale)
        for key, v in zip(ops, (OPS.index(k), who, a, b, ok)):
            ops[key].append(str(v))
        states += [str(x) for x in state(sp, br, users)]
    zeroed = sp.compounded(users[0]) == 0 and sp.scale - sp.deps[users[0]]["scale"] > 8
    assert zeroed, "the untouched deposit must outlive MAX_SCALE_DIFF rescalings and compound to zero"
    assert rescaling_offsets >= 20 and multi_rescales >= 3, (rescaling_offsets, multi_rescales)
    trace = {"ops": ops, "state": states, "stateLen": str(STATE_LEN), "users": str(N_USERS)}
    return trace, dict(steps=STEPS, max_scale=max_scale, rescaling_offsets=rescaling_offsets, multi_rescales=multi_rescales)
