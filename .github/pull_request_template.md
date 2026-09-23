## What changed, and why

<!-- One or two sentences. If this changes a rule, name its identifier in docs/SPEC.md (B9, SP2, L6, X7, ...). -->

## Which of the three does this touch?

A rule lives in three places and they must agree (AGENTS.md 1). Tick what you changed, and say below why the untouched
ones did not need changing.

- [ ] `docs/SPEC.md` — the normative rule
- [ ] `model/` — the reference implementation and its tests
- [ ] `contracts/` — the Solidity
- [ ] none of the three (tooling, CI, prose)

## Evidence

- [ ] `make check` is green on this branch
- [ ] a scenario fails without this change and passes with it — name it: ...
- [ ] a mutant restores the old behaviour and is killed — name it: ...
- [ ] the record was **regenerated**, not edited (`make record`), and I read the diff
- [ ] no tolerance was widened, and any new one has its bound argued at the assertion
- [ ] no coverage floor in `MIN_COVERAGE` was lowered

## Open items

- [ ] this change decides nothing listed in `docs/SPEC.md` 13
- [ ] it adds no owner, pause, proxy, setter or vote, and no scan over all Troves after a shutdown

<!-- If a box above is unticked, say why here. An unticked box with a reason is fine; an unticked box with silence is not. -->
