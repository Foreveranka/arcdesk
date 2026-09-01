#!/usr/bin/env bash
# Mainnet deploy for Arcdesk. Run this yourself so your private key never leaves your machine:
#
#   ! ~/arcdesk/deploy-mainnet.sh
#
# It asks for the key interactively (never echoed, never written to disk or history) and
# deploys the same ArcdeskEscrow bytecode to both chains:
#   - Base mainnet  (8453)  -> payment leg
#   - Arc mainnet   (5042)  -> liquidity leg
#
# Roles on purpose: YOUR wallet becomes owner (and will be the maker), while the keeper key
# that already lives on the VPS becomes operator. That way your key is never copied to the
# server; a compromised server can stall trades but cannot move your funds or take ownership.
set -euo pipefail

OWNER_ADDR=0x463CC337CA454B321A0324198265E65FbBAE2Dd2   # your wallet: deployer + owner + maker
OPERATOR=0x7d2828dee9C6FE9253805314306Eda3fBded3465     # keeper on the VPS: may only reserve

BASE_RPC=https://mainnet.base.org
BASE_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
ARC_RPC=https://rpc.arc-scan.org
ARC_USDC=0x3600000000000000000000000000000000000000

cd "$(dirname "$0")/contracts"

echo "Arcdesk mainnet deploy"
echo "  deployer/owner : $OWNER_ADDR"
echo "  operator       : $OPERATOR"
echo

read -rsp "Private key for $OWNER_ADDR (input hidden): " PK
echo
[[ "$PK" == 0x* ]] || PK="0x$PK"

# macOS ships bash 3.2, which has no ${var,,}; use tr for the case-insensitive compare.
DERIVED=$(cast wallet address --private-key "$PK")
D_LC=$(printf '%s' "$DERIVED" | tr 'A-Z' 'a-z')
O_LC=$(printf '%s' "$OWNER_ADDR" | tr 'A-Z' 'a-z')
if [ "$D_LC" != "$O_LC" ]; then
  echo "ABORT: that key controls $DERIVED, not $OWNER_ADDR" >&2
  exit 1
fi
echo "key matches $DERIVED"

echo
echo "balances before:"
echo "  Base ETH : $(cast balance "$OWNER_ADDR" --rpc-url $BASE_RPC)"
echo "  Arc USDC : $(cast call $ARC_USDC 'balanceOf(address)(uint256)' "$OWNER_ADDR" --rpc-url $ARC_RPC)"
echo
read -rp "Deploy to MAINNET on both chains? type 'deploy' to continue: " CONFIRM
[[ "$CONFIRM" == "deploy" ]] || { echo "cancelled"; exit 1; }

echo
echo "==> Base mainnet (payment leg)"
BASE_OUT=$(USDC=$BASE_USDC OPERATOR=$OPERATOR \
  forge script script/Deploy.s.sol --rpc-url $BASE_RPC --broadcast --private-key "$PK" 2>&1)
BASE_ESC=$(grep -oE "ArcdeskEscrow: 0x[a-fA-F0-9]{40}" <<<"$BASE_OUT" | awk '{print $2}')
[[ -n "$BASE_ESC" ]] || { echo "$BASE_OUT" | tail -20; echo "ABORT: Base deploy failed"; exit 1; }
echo "    $BASE_ESC"

echo "==> Arc mainnet (liquidity leg)"
ARC_OUT=$(USDC=$ARC_USDC OPERATOR=$OPERATOR \
  forge script script/Deploy.s.sol --rpc-url $ARC_RPC --broadcast --private-key "$PK" --legacy 2>&1)
ARC_ESC=$(grep -oE "ArcdeskEscrow: 0x[a-fA-F0-9]{40}" <<<"$ARC_OUT" | awk '{print $2}')
[[ -n "$ARC_ESC" ]] || { echo "$ARC_OUT" | tail -20; echo "ABORT: Arc deploy failed"; exit 1; }
echo "    $ARC_ESC"

unset PK

echo
echo "verifying on-chain wiring:"
echo "  Base usdc()     : $(cast call "$BASE_ESC" 'usdc()(address)' --rpc-url $BASE_RPC)"
echo "  Base owner()    : $(cast call "$BASE_ESC" 'owner()(address)' --rpc-url $BASE_RPC)"
echo "  Base operator() : $(cast call "$BASE_ESC" 'operator()(address)' --rpc-url $BASE_RPC)"
echo "  Arc  usdc()     : $(cast call "$ARC_ESC" 'usdc()(address)' --rpc-url $ARC_RPC)"
echo "  Arc  owner()    : $(cast call "$ARC_ESC" 'owner()(address)' --rpc-url $ARC_RPC)"
echo "  Arc  operator() : $(cast call "$ARC_ESC" 'operator()(address)' --rpc-url $ARC_RPC)"

cat > ../.env.mainnet <<EOF
SOURCE_RPC=$BASE_RPC
SOURCE_USDC=$BASE_USDC
SOURCE_ESCROW=$BASE_ESC
ARC_RPC=$ARC_RPC
ARC_USDC=$ARC_USDC
ARC_ESCROW=$ARC_ESC
TREASURY=$OWNER_ADDR
FEE_BPS=200
EOF
chmod 600 ../.env.mainnet

echo
echo "DONE. Addresses written to ~/arcdesk/.env.mainnet"
echo "  Base (payment)   $BASE_ESC"
echo "  Arc  (liquidity) $ARC_ESC"
echo
echo "Next: tell Claude the addresses so the backend, keeper and site get pointed at mainnet."
