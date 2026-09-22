# Release checklist

Done by the repository owner, in order, before a version is announced.

1. `python3 model/test_scenarios.py`, `test_econ_sim.py`, `fuzz.py 30 300`, `fuzz_oracle.py 200 150`, `mutants.py`, `spec_check.py`, `check_manifest.py`: all green on the release commit.
2. `cd contracts && git submodule update --init --recursive && python3 script/export_vectors.py ../model && git diff --exit-code -- test/vectors && forge test`.
3. `docs/RESULTS.md`: the run record names the release commit, the date and the tool versions; the manifest was regenerated after the last edit.
4. CI green on the release commit on GitHub (`.github/workflows/ci.yml`; actions pinned to full SHAs, Foundry pinned to a release).
5. **GitHub Private Vulnerability Reporting enabled** (Settings → Code security → Private vulnerability reporting), verified from a non-admin account by opening the "Security" tab and seeing "Report a vulnerability".
6. `LICENSE` present (MIT, Copyright (c) 2026 USDarli) and every `SPDX-License-Identifier` in `contracts/` reading `MIT`:
   `grep -rL 'SPDX-License-Identifier: MIT' contracts/src contracts/test --include='*.sol'` prints nothing.
7. `CHANGELOG.md` entry for the version; tag `vX.Y.Z` annotated on the release commit.
8. The announcement says: research pre-release; nothing deployed or audited; core contracts not written; no token.
