"""
Mutation check: re-introduce known spec bugs one at a time and report who catches them.
    python3 mutants.py [prefix]   (takes several minutes; restores model.py afterwards; e.g. `mutants.py M1`)
"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import os
import shutil
import subprocess
import sys

# A mutant of the SAME SIZE written within the same second as the original leaves a byte-code cache that Python accepts as
# valid for the restored file (the cache is keyed on mtime in seconds + size). Never write or reuse byte code here.
ENV = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")


def _no_cache():
    shutil.rmtree("__pycache__", ignore_errors=True)

MUTANTS = {
    "M1 step A rounds down": (
        "        p = ceil_div(self.agg_w * (t - self.last_agg_update), YEAR * WAD)\n        self.agg_debt += p",
        "        p = self.agg_w * (t - self.last_agg_update) // (YEAR * WAD)\n        self.agg_debt += p"),
    "M2 step B re-activates aggW after shutdown": (
        "        if self.shutdown_at == 0:\n            self.agg_w += new_debt * new_rate - old_w",
        "        self.agg_w += new_debt * new_rate - old_w"),
    "M3 frontend deposit rounds down": (
        "        part = ceil_div(x * self.share, WAD)", "        part = x * self.share // WAD"),
    "M4 bad-debt payout capped at face value + bonus ": (
        "        out = self.bad_debt_coll if R == self.bad_debt else self.bad_debt_coll * R // self.bad_debt",
        "        out = min(self.bad_debt_coll * R // self.bad_debt, R * (WAD + self.urgent_bonus) // self.feed.price)"),
    "M5 scale bump with `if` instead of a loop": (
        "        while new_p < P_FLOOR:\n            numerator *= SCALE_FACTOR",
        "        if new_p < P_FLOOR:\n            numerator *= SCALE_FACTOR"),
    "M6 baseRate state from the requested amount": (
        "        self.base_rate = min(decayed + redeemed_total * WAD * WAD // (supply_before * beta_w), WAD)",
        "        self.base_rate = min(decayed + amount * WAD * WAD // (supply_before * beta_w), WAD)"),
    "M8 SP gains read over two scales only ": (
        "SCALE_SPAN = MAX_SCALE_DIFF ", "SCALE_SPAN = 2 "),
    "M9 SP deposits stay open after a shutdown (the pool would absorb nothing, and depositors would rank ahead of settlement)": (
        "        require(br.shutdown_at == 0, \"after a shutdown the pool absorbs nothing any more: deposits are closed, withdrawals stay open\")\n", ""),
    "M11 oracle: Failed allowed without the sequencer having been up for TIMEOUT": (
        "        can_fail = self._sequencer_ok_for(self.timeout)", "        can_fail = True"),
    "M12 oracle: a healthy observation does not clear the malformed marker": (
        "        self.last_good, self.last_valid_at, self.invalid_since = price, now, 0",
        "        self.last_good, self.last_valid_at = price, now"),
    "M13 oracle: no gas guard on the source call": (
        "combine=\"single\", max_skew=None, gas_mode=\"stipend\", feed_gas_limit=200_000):",
        "combine=\"single\", max_skew=None, gas_mode=\"none\", feed_gas_limit=200_000):"),
    "M14 oracle: timestamp in the future accepted as fresh": (
        "        if value <= 0 or updated_at > self.clock.now:        # non-positive value or timestamp in the future",
        "        if value <= 0:"),
    "M15 oracle: sequencer check skipped (sources read first)": (
        "        if self.seq is not None and not self._sequencer_ok_for(self.grace):\n            return getattr(self, \"last_good\", 0), NETWORK_UNSTABLE",
        "        if False:\n            return getattr(self, \"last_good\", 0), NETWORK_UNSTABLE"),
    "M23 LP vault: reward tokens credited instantly instead of queued for the next epoch": (
        "    def notify_incentive(self, amount):\n        self._stream()\n        self.stream.add(amount * self.PREC)",
        "    def notify_incentive(self, amount):\n        self._stream()\n        self.acc[2] += amount * self.PREC // self.total if self.total else 0"),
    "M28 staking hand-over is paid out instantly instead of being queued for the next epoch": (
        "        self.stream.add(amount * self.PREC)          # queued for the NEXT epoch; no earlier schedule is touched",
        "        self.rpt += amount * self.PREC // self.total if self.total else 0"),
    "M29 a hand-over restarts the running epoch (the old re-spreading stream: payouts can be postponed for ever)": (
        "    def add(self, amount_scaled):\n        self.queued += amount_scaled",
        "    def add(self, amount_scaled):\n        left = self.rate * max(self._epoch_end(self.last) - self.last, 0)\n        self.rate = (left + amount_scaled + self.queued) // self.period\n        self.queued = 0\n        self.t0 = self.last = self.clock.now"),
    "M30 holders can claim from the pot while Troves are still unsettled (the first-come race comes back)": (
        "        require(self.unsettled == 0, \"settlement phase 1 is not complete: some Troves are still unsettled\")\n        require(0 < R <= self.bad_debt, \"R out of range\")\n        # the pot MAY be empty",
        "        require(0 < R <= self.bad_debt, \"R out of range\")\n        # the pot MAY be empty"),
    "M31 settlement uses the live price instead of the reference price fixed at shutdown": (
        "        if self.settle_price is None:\n            self.settle_price = self._shutdown_price()\n        return self.settle_price",
        "        return self._shutdown_price()"),
    "M32 a borrower's surplus is released before phase 1 ends although it may still have to absorb a shortfall": (
        "            require(self.unsettled == 0 and self.surplus_keep is not None, \"surplus is released when settlement phase 1 is complete\")\n",
        "            if self.surplus_keep is None:\n                self.surplus_keep = L_PRECISION\n"),
    "M33 repaying and closing stay open after a shutdown (healthy borrowers can leave with tokens bought below par)": (
        "        require(self.shutdown_at == 0, \"after a shutdown a Trove is settled, not closed (settle_trove)\")\n", ""),
    "M34 a Trove can be written off before the deadline (phase 1 can be cut short at everybody's expense)": (
        "        require(self.shutdown_at != 0 and self.clock.now >= self.shutdown_at + self.WRITE_OFF_DELAY, \"write-off only after the deadline\")",
        "        require(self.shutdown_at != 0, \"write-off only after the deadline\")"),
    "M35 a late recovery goes into the base pot, so only those who have NOT claimed yet share it (inequality returns)": (
        "            self.late_per_unit += to_holders * L_PRECISION // self.claim_units\n            self.late_pool += to_holders",
        "            self.bad_debt_coll += to_holders"),
    "M36 the settler is not paid the gas deposit": (
        "        self._pay_gas_deposit(tid, caller if caller is not None else owner)      # whatever this Trove still holds, on every path\n", ""),
    "M37 settlement scans the Troves again (cost per Trove grows with the number of Troves)": (
        "        if self.n_open:                              # a COUNTER: nothing in the settlement path scans the Troves",
        "        if self.open_troves():"),
    "M38 settlement protects borrowers' surplus (vault parity) instead of the decided rule": (
        "    SETTLEMENT_SURPLUS_ABSORBS = True     # the specified constant",
        "    SETTLEMENT_SURPLUS_ABSORBS = False    # the specified constant"),
    "M39 late recovery keeps the OLD surplus fraction": (
        "            self.take = min(self.settle_short_total, self.settle_surplus_gross)\n            g = self.settle_surplus_gross\n            self.surplus_keep = (g - self.take) * L_PRECISION // g if g else L_PRECISION",
        "            self.take = min(self.settle_short_total, self.settle_surplus_gross)"),
    "M40 claim units are registered only when the first payment is positive": (
        "        require(out >= min_coll_out, \"minCollOut\")", "        require(out >= min_coll_out and out > 0, \"minCollOut / zero output\")"),
    "M41 surplus entitlement tracked as a FRACTION paid": (
        "            part = self.gross_of[who] * self.surplus_keep // L_PRECISION - self.surplus_paid_amt[who]\n            if part > 0:\n                self.surplus_paid_amt[who] += part",
        "            part = self.gross_of[who] * (self.surplus_keep - self.surplus_paid_amt[who]) // L_PRECISION\n            if part > 0:\n                self.surplus_paid_amt[who] = self.surplus_keep"),
    "M42 gas reward paid by path name instead of the Trove's remaining deposit": (
        "        left = self.gas_left.get(tid, 0)\n        amt = left if part is None else min(part, left)",
        "        left = self.gas_left.get(tid, 0)\n        amt = self.gas_deposit if part is None else min(part, left)"),
    "M25 built-in debt cap ignores its ceiling": (
        "        return min(self.cap_ceiling, self.cap0 << min(steps, 64))", "        return self.cap0 << min(steps, 64)"),
    "M26 built-in debt cap doubles every day instead of every 30 days": (
        "        steps = (self.clock.now - self.created_at) // CAP_PERIOD", "        steps = (self.clock.now - self.created_at) // (24 * 3600)"),
    "M27 the debt cap also blocks interest (step A refuses to mint above the cap)": (
        "        self.agg_debt += p\n        self.last_agg_update = t", "        require(self.agg_debt + p <= self.debt_cap, \"debt cap\")\n        self.agg_debt += p\n        self.last_agg_update = t"),
    "M43 equal rates redeemed highest Trove id first (the sorted list's order would depend on hints)": (
        "key=lambda t: (t.rate, t.id))", "key=lambda t: (t.rate, -t.id))"),
    "M44 the share of an untagged Trove goes to an ownerless account instead of its owner": (
        "            self.claimable[owner] += reward\n            return", "            self.claimable[\"IncentiveController\"] += reward\n            return"),
    "M45 adjust_trove leaves a Zombie that borrowed back above the minimum out of the redemption queue": (
        "            if t.status == ZOMBIE:\n                # SPEC B4: back at the minimum", "            if False:\n                # SPEC B4: back at the minimum"),
    "M46 a redemption request above the redeemer's balance is accepted and truncated instead of refused": (
        "        require(self.stable.bal[redeemer] >= amount, \"redemption", "        require(True or self.stable.bal[redeemer] >= amount, \"redemption"),
}


def main():
    rows = []
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    if only and only not in {n.split()[0] for n in MUTANTS}:
        print(f"unknown mutant {only}"); sys.exit(2)
    for name, spec in MUTANTS.items():
        if only and name.split()[0] != only:
            continue
        a, b = spec[0], spec[1]
        target = spec[2] if len(spec) > 2 else "model.py"
        src = open(target, encoding="utf-8").read()
        shutil.copy(target, target + ".orig")
        try:
            if src.count(a) != 1:
                rows.append((name, "INVALID", "-", "-"))
                print(f"{name}: INVALID (mutation point found {src.count(a)} times)", flush=True)
                continue
            open(target, "w", encoding="utf-8").write(src.replace(a, b))
            _no_cache()
            r1 = subprocess.run([sys.executable, "test_scenarios.py"], capture_output=True, text=True, env=ENV)
            r2 = subprocess.run([sys.executable, "fuzz.py", "12", "250"], capture_output=True, text=True, env=ENV)
            r3 = subprocess.run([sys.executable, "fuzz_oracle.py", "80", "120"], capture_output=True, text=True, env=ENV)
            failed = [l.split()[1].replace("scenario_", "")[:2] for l in r1.stdout.splitlines() if l.startswith("FAIL")]
            def verdict(r):                  # exit 1 = a property failed (kill); exit 2 = infrastructure error (invalid); 0 = survived
                return {0: "missed", 1: "caught"}.get(r.returncode, "INVALID")
            if r1.returncode not in (0, 1) or "Traceback" in r1.stderr and not failed:
                failed = ["INVALID"]
            rows.append((name, ",".join(failed) or "-", verdict(r2), verdict(r3)))
            print(f"{name}: scenarios={rows[-1][1]} fuzz={rows[-1][2]} fuzz_oracle={rows[-1][3]}", flush=True)
        finally:
            shutil.move(target + ".orig", target)
            _no_cache()
    return rows


def summary(rows):
    killed = [r for r in rows if r[1] not in ("-", "INVALID") or r[2] == "caught" or r[3] == "caught"]
    survived = [r for r in rows if r[1] == "-" and r[2] == "missed" and r[3] == "missed"]
    invalid = [r for r in rows if "INVALID" in r]
    print(f"\nmutants: {len(rows)} run, {len(killed)} killed, {len(survived)} survived, {len(invalid)} invalid")
    if not rows:
        print("  ERROR: no mutant was run"); return 1
    for r in survived:
        print("  SURVIVED:", r[0])
    for r in invalid:
        print("  INVALID:", r[0])
    if not survived and not invalid and len(rows) > 1:        # a full run, not `mutants.py M39`
        from figures import fig, dump
        fig("mutants_total", len(rows))
        fig("mutants_killed", len(killed))
        fig("mutants_survived", len(survived))
        fig("mutants_invalid", len(invalid))
        # The split matters: docs/SPEC.md 12 claims fuzzer coverage per area, and the honest figure is how many mutants
        # the random testers kill WITHOUT a scenario. It is recorded rather than described.
        fig("mutants_killed_by_fuzz", sum(1 for r in rows if r[2] == "caught"))
        fig("mutants_killed_by_fuzz_oracle", sum(1 for r in rows if r[3] == "caught"))
        fig("mutants_killed_by_a_fuzzer", sum(1 for r in rows if r[2] == "caught" or r[3] == "caught"))
        print(f"figures: {dump('mutants')} recorded")
    return 0 if not survived and not invalid else 1


if __name__ == "__main__":
    sys.exit(summary(main()))
