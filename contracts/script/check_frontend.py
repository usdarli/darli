"""
frontend/index.html against the contracts: every function selector the page embeds must be what the compiler gives for
its signature, and every action must call a function that exists on the contract it names.   python3 script/check_frontend.py

The page cannot compute selectors itself without a hashing library, and it loads nothing; so it carries them, and this
check keeps them true. A renamed or re-typed function fails here instead of sending the wrong calldata.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = (ROOT.parent / "frontend" / "index.html").read_text(encoding="utf-8")
SOURCES = {
    "BranchManager": "src/core/BranchManager.sol:BranchManager",
    "StabilityPool": "src/core/StabilityPool.sol:StabilityPool",
    "BranchSettlement": "src/core/BranchSettlement.sol:BranchSettlement",
    "CollateralRegistry": "src/core/CollateralRegistry.sol:CollateralRegistry",
    "DarliStaking": "src/revenue/DarliStaking.sol:DarliStaking",
    "RevenueRouter": "src/revenue/RevenueRouter.sol:RevenueRouter",
    "DarliLiquidityVault": "src/liquidity/DarliLiquidityVault.sol:DarliLiquidityVault",
    "FrontendRegistry": "src/core/FrontendRegistry.sol:FrontendRegistry",
    "ERC20": "IERC20",
    "StableToken": "src/core/StableToken.sol:StableToken",
    "DarliToken": "src/revenue/DarliToken.sol:DarliToken",
    "OptimismPortal": "IOptimismPortal",
}


def methods(name):
    out = subprocess.run(["forge", "inspect", SOURCES[name], "methodIdentifiers", "--json"], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    return {sig: "0x" + sel for sig, sel in json.loads(out).items()}


selectors = json.loads(re.search(r'<script type="application/json" id="selectors">(.*?)</script>', PAGE, re.S).group(1))
contracts = dict(re.findall(r'(\w+): "(\w+)"', re.search(r"const CONTRACTS = \{(.*?)\};", PAGE, re.S).group(1)))
actions = re.findall(r'c: "(\w+)", s: "([^"]+)"', PAGE)
known = {name: methods(name) for name in set(contracts.values()) | {"OptimismPortal"}}
errors = []
every = {sig: sel for m in known.values() for sig, sel in m.items()}
for sig, sel in selectors.items():
    if every.get(sig) != sel:
        errors.append(f"selector of {sig}: the page has {sel}, the compiler {every.get(sig)}")
for key, sig in actions:
    if key not in contracts:
        errors.append(f"action on an unknown contract {key}")
    elif sig not in known[contracts[key]]:
        errors.append(f"{contracts[key]} has no {sig}")
    if sig not in selectors:
        errors.append(f"no selector for {sig}")
if "depositTransaction(address,uint256,uint64,bool,bytes)" not in known["OptimismPortal"]:
    errors.append("the Ethereum path's function is not the portal's")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"frontend: {len(selectors)} selectors and {len(actions)} actions match the contracts")
