# One place where the checks are written down. `RELEASING.md` step 1-2 and `.github/workflows/ci.yml` both run these
# targets rather than repeating the commands, so the release gate and CI cannot drift apart again: for a while CI ran the
# fuzzers at a tenth of the budget the release checklist required, and a green CI therefore meant less than it looked.
#
#   make smoke      what AGENTS.md 3 asks for before you change anything (a minute or two)
#   make evidence   every producer at the configuration docs/RESULTS.md records, then the document checks (slow)
#   make contracts  formatting, differential vectors and forge test
#   make check      smoke + evidence + contracts: the whole release gate
#   make record     regenerate figures and manifest after a change, then read the diff
#   make fmt        format the Solidity (read `forge fmt` in AGENTS.md 7 first)

MAKEFLAGS += --no-print-directory
PY ?= python3
.PHONY: help smoke evidence contracts check record fmt clean

help:
	@sed -n 's/^#   //p' $(MAKEFILE_LIST)

# --- fast ------------------------------------------------------------------------------------------------------------
smoke:
	cd model && $(PY) test_scenarios.py
	cd model && $(PY) test_econ_sim.py
	cd model && $(PY) fuzz.py 10 200
	cd model && $(PY) fuzz_oracle.py 50 100
	cd model && $(PY) spec_check.py
	cd model && $(PY) check_manifest.py
	cd model && $(PY) check_figures.py

# --- the record ---------------------------------------------------------------------------------------------------- #
# The producers must all run in one workspace: each rewrites only its own group of model/results/figures.json, and
# check_figures.py fails if any group is missing. The final `git diff` is what makes the document unable to drift.
evidence:
	cd model && $(PY) test_scenarios.py
	cd model && $(PY) test_econ_sim.py
	cd model && $(PY) fuzz.py 30 300
	cd model && $(PY) fuzz_oracle.py 200 150
	cd model && $(PY) mutants.py
	cd model && $(PY) spec_check.py
	cd model && $(PY) check_figures.py
	cd model && $(PY) check_manifest.py
	git diff --exit-code -- model/results/figures.json docs/RESULTS.md

record:
	cd model && $(PY) test_scenarios.py && $(PY) test_econ_sim.py && $(PY) fuzz.py 30 300 && $(PY) fuzz_oracle.py 200 150 && $(PY) mutants.py
	cd model && $(PY) check_figures.py --write
	cd model && $(PY) check_manifest.py --write
	@echo "regenerated: read the diff before committing it"

# --- contracts ---------------------------------------------------------------------------------------------------- #
contracts:
	cd contracts && forge fmt --check
	cd contracts && $(PY) script/export_vectors.py ../model
	git diff --exit-code -- contracts/test/vectors
	cd contracts && forge test

fmt:
	cd contracts && forge fmt

check: smoke evidence contracts
	@echo "all green: this is the release gate of RELEASING.md steps 1-2"

clean:
	rm -rf contracts/out contracts/cache
	find model -name __pycache__ -type d -exec rm -rf {} +
