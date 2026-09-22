"""Verifies the manifest of docs/RESULTS.md: every listed file exists with the recorded hash; the files the results depend on are
all listed; no duplicate rows; an empty manifest is a failure.    python3 check_manifest.py"""
import hashlib, os, re, sys
os.chdir(os.path.dirname(os.path.abspath(__file__)))
REQUIRED = ["model/model.py", "model/econ_sim.py", "model/test_scenarios.py", "model/test_econ_sim.py", "model/fuzz.py", "model/fuzz_oracle.py",
            "model/mutants.py", "model/pilot_sweep.py", "model/beta_pilot_compare.py", "model/results/pilot_seeds.jsonl",
            "model/results/pilot_summary.jsonl", "model/results/beta_pilot_compare.jsonl", "docs/SPEC.md"]
R = open("../docs/RESULTS.md", encoding="utf-8").read()
rows = re.findall(r"\| ((?:model|docs)/[\w./-]+) \| `([0-9a-f]{16})` \|", R)
bad = []
if not rows:
    bad.append("manifest is empty or unparseable")
seen = set()
for path, h in rows:
    if path in seen:
        bad.append(f"{path}: listed twice")
    seen.add(path)
    p = os.path.join("..", path)
    if not os.path.exists(p):
        bad.append(f"{path}: missing"); continue
    got = hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]
    if got != h:
        bad.append(f"{path}: manifest {h}, file {got}")
for req in REQUIRED:
    if req not in seen:
        bad.append(f"{req}: required but not in the manifest")
print("\n".join(bad) if bad else f"manifest: {len(rows)} files, all hashes match, all required files listed")
sys.exit(1 if bad else 0)
