# Changelog

## 0.0.1 — 2026-09-22

First published version. There is no earlier release and no earlier public history; development starts from this commit.

Contents: design decisions, normative specification, whitepaper, reference model with its evidence, Solidity skeleton.

Research pre-release: nothing is deployed or audited and the core contracts are not written. Released under MIT (Copyright (c) 2026 USDarli); the legal review named in `docs/SPEC.md` §13 has not been done.

Decisions in force (see `docs/SPEC.md` §0): immutable system; DARLI as revenue-only token; interest split 72 / 25 / 3; built-in debt cap; staged settlement after shutdown with healthy borrowers' surplus absorbing shortfalls first; write-off after 30 days with exact late recovery; one-shot deployment creating the canonical pool at par; external oracle only.

Open: β; gas deposit amount; oracle stipend and thresholds; PoolManager storage layout; vault quote asset and position maths; DARLI distribution; liquidity-provider share of revenue (studied, not decided).
