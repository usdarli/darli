"""Verifies the manifest of docs/RESULTS.md.

Every listed file must exist with the recorded hash, every file the recorded results depend on must be listed, no row may
appear twice, and an empty manifest is a failure.

The manifest covers `model/` and `docs/SPEC.md`, and also `contracts/` and the two pinned submodules, because the run
record makes claims about them too: the vector count and the forge test result mean nothing without knowing which
Solidity sources, which `foundry.toml` and which version of OpenZeppelin produced them.

    python3 check_manifest.py            verify
    python3 check_manifest.py --write    regenerate both tables in docs/RESULTS.md, then read the diff
"""
import hashlib
import os
import re
import subprocess
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
RESULTS = "../docs/RESULTS.md"

# Files the recorded results are produced by. A results file that stops being required is a decision, not an accident.
REQUIRED = [
    "model/model.py", "model/econ_sim.py", "model/test_scenarios.py", "model/test_econ_sim.py", "model/fuzz.py",
    "model/fuzz_oracle.py", "model/mutants.py", "model/pilot_sweep.py", "model/beta_pilot_compare.py",
    "model/figures.py", "model/check_figures.py", "model/spec_check.py", "model/check_manifest.py", "model/study_figures.py",
    "model/results/pilot_seeds.jsonl", "model/results/pilot_summary.jsonl", "model/results/beta_pilot_compare.jsonl",
    "model/results/figures.json", "model/oracle_history.py", "model/base_gas_history.py",
    "model/results/oracle_history.jsonl", "model/results/base_gas_history.jsonl",
    "docs/SPEC.md",
    "contracts/foundry.toml", "contracts/remappings.txt", "contracts/script/export_vectors.py",
    "contracts/script/check_test_count.py",
    "contracts/test/vectors/math.json", "contracts/test/vectors/sorted_list.json", "contracts/test/vectors/branch_trace.json",
    "contracts/test/vectors/stability_pool.json", "contracts/script/branch_trace.py", "contracts/script/sp_trace.py",
]
SUBMODULES = ["contracts/lib/forge-std", "contracts/lib/openzeppelin-contracts", "contracts/lib/v4-core"]

FILE_ROW = re.compile(r"\| ((?:model|docs|contracts)/[\w./-]+) \| `([0-9a-f]{16})` \|")
SUB_ROW = re.compile(r"\| (contracts/lib/[\w.-]+) \| `([0-9a-f]{40})` \| ([^|]*?) \|")


def digest(path):
    return hashlib.sha256(open(os.path.join("..", path), "rb").read()).hexdigest()[:16]


def required_files():
    """REQUIRED plus every Solidity source and test (the whole input of `forge test`), every vector file and every script
    that writes one: a new trace generator is covered the day it is added, not the day someone remembers to list it."""
    extra = []
    for root, suffix in (("contracts/src", ".sol"), ("contracts/test", ".sol"), ("contracts/test/vectors", ".json"),
                         ("contracts/script", ".py"), ("contracts/script", ".sol"), ("contracts/fork", ".sol")):
        for dirpath, _, names in os.walk(os.path.join("..", root)):
            for n in sorted(names):
                if n.endswith(suffix):
                    extra.append(os.path.relpath(os.path.join(dirpath, n), "..").replace(os.sep, "/"))
    return sorted(set(REQUIRED) | set(extra))


def pinned_submodules():
    """The gitlink each submodule is pinned at, from the index: that is what `--recurse-submodules` will check out."""
    out = {}
    for path in SUBMODULES:
        try:
            line = subprocess.run(["git", "ls-tree", "HEAD", path], cwd="..", capture_output=True, text=True,
                                  check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None                                   # no git, or not a checkout: reported, never passed silently
        m = re.match(r"\S+ commit ([0-9a-f]{40})\t", line)
        if not m:
            return None
        tag = ""
        try:
            tag = subprocess.run(["git", "describe", "--tags", "--exact-match", m.group(1)],
                                 cwd=os.path.join("..", path), capture_output=True, text=True).stdout.strip()
        except OSError:
            pass
        out[path] = (m.group(1), tag)
    return out


def render(rows, sub):
    files = "\n".join(f"| {p} | `{h}` |" for p, h in rows)
    subs = "\n".join(f"| {p} | `{c}` | {t} |" for p, (c, t) in sorted(sub.items())) if sub else ""
    return files, subs


def main(write=False):
    text = open(RESULTS, encoding="utf-8").read()
    bad = []

    want = required_files()
    sub = pinned_submodules()
    if sub is None:
        bad.append("submodule pins could not be read (is this a git checkout with the submodules initialised?)")

    if write:
        rows = [(p, digest(p)) for p in want if os.path.exists(os.path.join("..", p))]
        files_tbl, subs_tbl = render(rows, sub or {})
        text = re.sub(r"(?m)^\| file \| hash \|\n\|[ -|]+\|\n(?:\|[^\n]*\n)+",
                      f"| file | hash |\n| --- | --- |\n{files_tbl}\n", text, count=1)
        if subs_tbl:
            text = re.sub(r"(?m)^\| submodule \| commit \| tag \|\n\|[ -|]+\|\n(?:\|[^\n]*\n)+",
                          f"| submodule | commit | tag |\n| --- | --- | --- |\n{subs_tbl}\n", text, count=1)
        open(RESULTS, "w", encoding="utf-8").write(text)
        print(f"rewrote the manifest of {RESULTS}: {len(rows)} files, {len(sub or {})} submodules")

    rows = FILE_ROW.findall(text)
    if not rows:
        bad.append("manifest is empty or unparseable")
    seen = set()
    for path, h in rows:
        if path in seen:
            bad.append(f"{path}: listed twice")
        seen.add(path)
        if not os.path.exists(os.path.join("..", path)):
            bad.append(f"{path}: missing")
            continue
        got = digest(path)
        if got != h:
            bad.append(f"{path}: manifest {h}, file {got}")
    for req in want:
        if req not in seen:
            bad.append(f"{req}: required but not in the manifest")

    if sub is not None:
        listed = dict((p, c) for p, c, _ in SUB_ROW.findall(text))
        for path, (commit, _) in sub.items():
            if path not in listed:
                bad.append(f"{path}: pinned submodule not in the manifest")
            elif listed[path] != commit:
                bad.append(f"{path}: manifest {listed[path]}, index {commit}")

    if bad:
        print("\n".join(bad))
        print("\nRegenerate with `python3 check_manifest.py --write`, then read the diff.")
        return 1
    print(f"manifest: {len(rows)} files and {len(sub)} submodules, all hashes match, all required files listed")
    return 0


if __name__ == "__main__":
    sys.exit(main(write="--write" in sys.argv[1:]))
