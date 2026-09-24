#!/usr/bin/env bash
# The deployment rehearsal: the real deployment scripts, in real transactions, on a local fork of Base at the fork tests'
# pinned block -- the feed (DeployFeed), then the whole system (DeployDarli), then an ordinary user on it (RehearseUse).
# The keys are anvil's public test keys: they exist only on the local fork. Every transaction that reads the price carries
# a gas limit well above what it uses: the feed's stipend guard (SPEC O5) must see the stipend available before the read,
# and forge's default limit (what the simulation used, plus 30 %) falls short of it. The values SPEC 13 leaves open are the fork
# tests' placeholders, set here and nowhere else.   make rehearse   (BASE_RPC_URL overrides the endpoint)
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

# 1. the feed: placeholders for the open oracle values (SPEC 13 item 2), as in contracts/fork
export POOLS=0xd0b53D9277642d899DF5C87A3966A349A798F224,0x6c561B446416E1A00E8E93E221854d6eA4171372,0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59,0x9785eF59E2b499fB741674ecf6fAF912Df7b3C1b
export POOL_WINDOW=600 POOL_STALENESS=3600 MIN_DEPTH=5000000000000000000000000 POOL_CALL_GAS=80000
export POOL_SOURCE_GAS=600000 MAX_DEVIATION=50000000000000000 FEED_GAS=100000 SEQUENCER_GAS=100000
export STALENESS=3600 TIMEOUT=86400 GRACE=3600
forge script script/DeployFeed.s.sol:DeployFeed --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --slow -q --gas-estimate-multiplier 300
WETH_FEED=$(python3 -c "import json; t=json.load(open('broadcast/DeployFeed.s.sol/8453/run-latest.json'))['transactions']; print([x['contractAddress'] for x in t if x['contractName']=='DualSourcePriceFeed'][0])")
export WETH_FEED
echo "rehearse: feed $WETH_FEED"

# 2. the system: the other open values (gas deposit, DARLI supply and recipient) are placeholders too
export DARLI_INITIAL_BASE_RATE=100000000000000000 DARLI_RECIPIENT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
export DARLI_SUPPLY=1000000000000000000000000 MIN_DEBT=500000000000000000000 DEBT_CAP0=125000000000000000000000
export DEBT_CAP_CEILING=250000000000000000000000 GAS_DEPOSIT=1000000000000000
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
