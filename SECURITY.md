# Security policy

## Scope
This repository contains a design, a reference model and a Solidity skeleton. **Nothing is deployed.** Findings are welcome against:
- the rules in `docs/SPEC.md` (a way to take, lock or mis-allocate user collateral or claims under the stated rules),
- the reference model in `model/` (a rule the model violates, an invariant that can be broken, a test that is blind),
- the contracts in `contracts/`.

## How to report
Use **GitHub Private Vulnerability Reporting** on this repository ("Security" tab → "Report a vulnerability"). Enabling it in the repository settings is a required step of the release checklist (`RELEASING.md`), and the repository owner verifies it from an account without administrative access before publishing. If the button is not there, the repository is not yet released; do not report through a public issue. Do not open a public issue and do not commit a reproducing test to a public branch before the finding is fixed.

## What to expect
- Acknowledgement within 7 days; an assessment within 30 days.
- Findings against the model or the specification are fixed in public, with credit, once agreed.
- There is no bug bounty at this stage.

## Once something is deployed
This policy will be replaced by one that names the deployed addresses, the versions in scope, a dedicated contact and the disclosure timeline. Because the protocol is immutable, a finding against a deployed contract cannot be patched; the response will be public notice and migration guidance.
