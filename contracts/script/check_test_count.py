"""`forge test` must have run exactly the tests docs/RESULTS.md says exist.

export_vectors.py records `declared_tests`, a static count of `function test...` in contracts/test. That count is what the
document quotes, and a static count can be wrong in two quiet ways: a test forge does not pick up (wrong contract, wrong
visibility), or a count left stale. This reads forge's own summary from stdin and fails on any difference.

    forge test | python3 script/check_test_count.py
"""
import json
import re
import sys
from pathlib import Path

out = sys.stdin.read()
sys.stdout.write(out)
m = re.search(r"(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)", out)
if not m:
    sys.exit("check_test_count: forge's summary line was not found; did `forge test` run?")
passed, failed, skipped, total = map(int, m.groups())
figs = json.loads((Path(__file__).resolve().parents[2] / "model" / "results" / "figures.json").read_text())
declared = int(figs["contracts"]["declared_tests"])
if failed or skipped:
    sys.exit(f"check_test_count: {failed} failed, {skipped} skipped")
if total != declared:
    sys.exit(f"check_test_count: forge ran {total} tests, the record declares {declared}: re-run export_vectors.py "
             f"(and make record), or find the test forge did not pick up")
print(f"check_test_count: forge ran {total} tests, exactly the {declared} the record declares")
