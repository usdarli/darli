"""Checks SPEC.md against test_scenarios.py: every S-NN cited exists; every scenario is cited at least once; every M-n cited exists in mutants.py;
every Foundry test SPEC.md cites exists as a function in contracts/test (it cited `test_e` and `test_f` for years; neither existed).
    python3 spec_check.py"""
import os as _os
_os.chdir(_os.path.dirname(_os.path.abspath(__file__)))
import re, sys
spec = open("../docs/SPEC.md", encoding="utf-8").read()
scen = dict(re.findall(r"def scenario_(\d+)_(\w+)", open("test_scenarios.py").read()))
muts = set(re.findall(r'^    "M(\d+) ', open("mutants.py", encoding="utf-8").read(), flags=re.M))
cited_s = set(re.findall(r"S-(\d+)", spec)); cited_m = set()
for chunk in re.findall(r"M-?(\d+(?:[–-]\d+)?)", spec):
    if "–" in chunk or "-" in chunk:
        a, b = re.split("[–-]", chunk); cited_m |= {str(i) for i in range(int(a), int(b) + 1)}
    else:
        cited_m.add(chunk)
bad = [f"S-{n} cited but no such scenario" for n in sorted(cited_s) if n not in scen]
bad += [f"scenario_{n}_{name} never cited" for n, name in sorted(scen.items()) if n not in cited_s]
bad += [f"M-{n} cited but no such mutant" for n in sorted(cited_m, key=int) if n not in muts]
bad += [f"mutant M{n} never cited" for n in sorted(muts, key=int) if n not in cited_m]
import pathlib
foundry_src = "".join(f.read_text(encoding="utf-8") for f in sorted(pathlib.Path("../contracts/test").rglob("*.sol")))
foundry_fns = set(re.findall(r"function\s+(test\w*)\s*\(", foundry_src))
cited_f = set()
for chunk in re.findall(r"Foundry ([^)]*)", spec):
    cited_f |= set(re.findall(r"`(test\w*)`", chunk))
bad += [f"Foundry `{t}` cited but no such test in contracts/test" for t in sorted(cited_f) if t not in foundry_fns]
print("\n".join(bad) if bad else f"spec_check: all {len(scen)} scenarios and all {len(muts)} mutants are cited and exist; all {len(cited_f)} cited Foundry tests exist")
sys.exit(1 if bad else 0)
