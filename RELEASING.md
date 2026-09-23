# Release checklist

Done by the repository owner, in order, before a version is announced.

1. `make check` green on the release commit. It is the whole gate: the scenarios, the simulator, both fuzzers at the recorded budget with their coverage floors, every mutant, `spec_check`, `check_manifest`, `check_figures`, `forge fmt --check`, the differential vectors and `forge test`; it ends by requiring `git diff --exit-code` on `model/results/figures.json` and `docs/RESULTS.md`, so the record was regenerated rather than edited.
2. `git submodule update --init --recursive` first, or `make check` cannot compile the contracts.
3. `docs/RESULTS.md`: the run record names the release commit, the date and the tool versions; the manifest and the figures were **regenerated** after the last edit (`check_manifest.py --write`, `check_figures.py --write`), never typed.
4. CI green on the release commit on GitHub (`.github/workflows/ci.yml`; actions pinned to full SHAs, Foundry pinned to a release).
5. **GitHub Private Vulnerability Reporting enabled** (Settings → Code security → Private vulnerability reporting), verified from a non-admin account by opening the "Security" tab and seeing "Report a vulnerability".
6. `LICENSE` present (MIT, Copyright (c) 2026 USDarli) and every `SPDX-License-Identifier` in `contracts/` reading `MIT`:
   `grep -rL 'SPDX-License-Identifier: MIT' contracts/src contracts/test --include='*.sol'` prints nothing.
7. `CHANGELOG.md` entry for the version; tag `vX.Y.Z` annotated **and signed** (`git tag -s`) on the release commit, and pushed.
8. Repository settings, checked by opening them, not assumed:
   - `main` protected: no force-push, no deletion, a pull request with at least one approval, and `smoke`, `evidence`
     and `contracts` required to pass. `analysis` is advisory and must NOT be required.
   - The nightly `stress` run of the last seven days reviewed: it fuzzes seeds the release configuration never reaches,
     so a failure there is a real finding, not noise.
9. The announcement says: research pre-release; nothing deployed or audited; core contracts not written; no token.
