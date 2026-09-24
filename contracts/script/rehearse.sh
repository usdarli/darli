#!/usr/bin/env bash
# The deployment rehearsal: the real deployment scripts, in real transactions, on a local fork of Base at the fork tests'
# pinned block -- the feed (DeployFeed), then the whole system (DeployDarli), then an ordinary user on it (RehearseUse).
# The scripts carry every SPEC 2 constant; only what SPEC 13 leaves open (DARLI supply and recipient) is set here.
# The keys are anvil's public test keys: they exist only on the local fork. Every transaction that reads the price carries
# a gas limit well above what it uses: the feed's stipend guard (SPEC O5) must see the stipend available before the read,
# and forge's default limit (what the simulation used, plus 30 %) falls short of it.   make rehearse   (BASE_RPC_URL overrides
# the endpoint)
set -euo pipefail
cd "$(dirname "$0")/.."
RPC_UPSTREAM="${BASE_RPC_URL:-https://base-mainnet.public.blastapi.io}"
BLOCK=51380224
PORT=8547
RPC="http://127.0.0.1:$PORT"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
USER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

anvil --fork-url "$RPC_UPSTREAM" --fork-block-number "$BLOCK" --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 60); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done

# 1. the feed
forge script script/DeployFeed.s.sol:DeployFeed --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow -q --gas-estimate-multiplier 300
WETH_FEED=$(python3 -c "import json; t=json.load(open('broadcast/DeployFeed.s.sol/8453/run-latest.json'))['transactions']; print([x['contractAddress'] for x in t if x['contractName']=='DualSourcePriceFeed'][0])")
export WETH_FEED
echo "rehearse: feed $WETH_FEED"

# 2. the system: DARLI supply and recipient are placeholders (SPEC 13); the pilot's debt limits as in SPEC 2
export DARLI_INITIAL_BASE_RATE=100000000000000000 DARLI_RECIPIENT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export DARLI_SUPPLY=1000000000000000000000000 MIN_DEBT=500000000000000000000 DEBT_CAP0=125000000000000000000000
export DEBT_CAP_CEILING=250000000000000000000000
forge script script/DarliSystem.s.sol:DeployDarli --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow -q --gas-estimate-multiplier 300
eval "$(python3 - <<'PY'
import json
t = json.load(open("broadcast/DarliSystem.s.sol/8453/run-latest.json"))["transactions"]
made = {}
for x in t:
    if x.get("transactionType") == "CREATE":
        made.setdefault(x["contractName"], x["contractAddress"])
print(f"export MANAGER={made['BranchManager']} SP={made['StabilityPool']} REGISTRY={made['CollateralRegistry']}")
print(f"echo 'rehearse: {len(made)} contract kinds created, {len(t)} transactions'")
PY
)"
echo "rehearse: manager $MANAGER"

# 3. an ordinary user
out=$(forge script script/RehearseUse.s.sol:RehearseUse --rpc-url "$RPC" --private-key "$USER_KEY" --broadcast --slow \
  --gas-estimate-multiplier 1000 -vv 2>&1) || { echo "$out"; exit 1; }
if grep -q "Transaction Failure" <<<"$out"; then echo "$out"; exit 1; fi
grep -E "trove|stability|ETH received|supply" <<<"$out"
echo "rehearse: done, every transaction succeeded"
