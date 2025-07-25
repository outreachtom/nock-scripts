#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_nockchain.sh – idempotent installer/upgrader for a Nockchain miner
# ---------------------------------------------------------------------------

set -euo pipefail

REPO_URL="https://github.com/zorp-corp/nockchain.git"
TARGET_DIR="nockchain"
LOG_FILE="update.log"

# Defaults; can be overridden via env
P2P_PORT="${NOCK_P2P_PORT:-33000}"
API_PORT="${NOCK_API_PORT:-12000}"
DEBUG_MODE=false

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
usage(){ echo "Usage: MINING_PUBKEY=<pubkey> $0 [--debug]" >&2; exit 1; }

# ‑‑‑ parse args ‑‑‑
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG_MODE=true ;;
    *) usage ;;
  esac
done

# ‑‑‑ require pubkey ‑‑‑
: "${MINING_PUBKEY:?MINING_PUBKEY not set. Export it or pass via .env file}"

# ‑‑‑ 1) install apt deps (non‑interactive) ‑‑‑
export DEBIAN_FRONTEND=noninteractive
log "Installing system packages…"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  git curl build-essential clang llvm-dev libclang-dev \
  make pkg-config libssl-dev

# ‑‑‑ 2) clone or update repo ‑‑‑
if [[ ! -d "$TARGET_DIR/.git" ]]; then
  log "Cloning repository…"
  git clone --depth 1 "$REPO_URL" "$TARGET_DIR" \
    || { log "[ERROR] git clone failed"; exit 1; }
fi
cd "$TARGET_DIR"

log "Fetching latest code…"
git fetch --all --prune --tags

# determine branch
CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [[ -z "$CURRENT_BRANCH" ]]; then
  if git show-ref --verify --quiet refs/heads/main; then
    CURRENT_BRANCH=main
  elif git show-ref --verify --quiet refs/heads/master; then
    CURRENT_BRANCH=master
  else
    log "[ERROR] Cannot determine branch (no main/master)"
    exit 1
  fi
  git checkout "$CURRENT_BRANCH"
fi

git pull --ff-only origin "$CURRENT_BRANCH"

# ‑‑‑ 3) ensure Rust toolchain ‑‑‑
if ! command -v cargo >/dev/null 2>&1; then
  log "Installing Rust toolchain…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default
fi
# shellcheck source=/dev/null
source "$HOME/.cargo/env"

# ‑‑‑ 4) build the binaries ‑‑‑
log "Building hoonc…"
make install-hoonc > /dev/null

log "Building nockchain-wallet…"
make install-nockchain-wallet > /dev/null

log "Building nockchain node…"
make install-nockchain > /dev/null

NODE_BIN="$(cargo bin nockchain 2>/dev/null || true)"
[[ -x "$NODE_BIN" ]] || NODE_BIN="./target/release/nockchain"

# ‑‑‑ 5) stop old miner and free ports ‑‑‑
log "Stopping any running nockchain…"
pkill -9 -f 'nockchain --mine' 2>/dev/null || true
pkill -9 -f nockchain           2>/dev/null || true

# free both TCP+UDP on both v4/v6
for port in "$P2P_PORT" "$API_PORT"; do
  for proto in tcp udp; do
    ss -lnp --$proto "sport = :$port" 2>/dev/null \
      | awk 'NR>1 { sub(/.*pid=/,"",$NF); sub(/,.*/,"",$NF); print $NF }' \
      | sort -u \
      | xargs -r sudo kill -9 || true
  done
done

# ─── Clear out any stale IPC socket ─────────────────────────────────────────
if [[ -d ".socket" ]]; then
  log "Removing stale UNIX socket .socket/nockchain_npc.sock…"
  rm -f .socket/nockchain_npc.sock
fi

# ‑‑‑ 6) launch the miner directly ‑‑‑
log "Launching miner (via wrapper)…"
nohup bash ./scripts/run_nockchain_miner.sh \
      --mining-pubkey "$MINING_PUBKEY" \
      > miner.log 2>&1 &

sleep 3
if pgrep -f 'nockchain .*--mine' >/dev/null; then
  log "✅ Miner running (PID: $(pgrep -f 'nockchain .*--mine'))"
else
  log "❌ Miner failed to start – check miner.log"
  exit 1
fi

$DEBUG_MODE && {
  log "Debug mode – tailing miner.log"
  tail -f miner.log
}

log "=== Update complete ==="
