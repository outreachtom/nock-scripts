#!/bin/bash

SCRIPT_NAME="update_nockchain.sh"
SERVERS_FILE="servers.txt"
PASSWORDS_FILE="passwords.txt"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
LOG_DIR="logs/update_$DATE"
SUMMARY_FILE="$LOG_DIR/summary.log"
PARALLELISM=10
RETRIES=1
DEBUG_MODE=false

source .env

mkdir -p "$LOG_DIR"
> "$SUMMARY_FILE"

for arg in "$@"; do
  if [[ "$arg" == "--debug" ]]; then
    DEBUG_MODE=true
  fi
  if [[ "$arg" =~ ^--parallel=([0-9]+)$ ]]; then
    PARALLELISM="${BASH_REMATCH[1]}"
  fi
done

run_update() {
  local server_line="$1"
  local user_host=$(echo "$server_line" | cut -d'@' -f2)
  local password=$(grep "$user_host" "$PASSWORDS_FILE" | cut -d':' -f2)
  local log_file="$LOG_DIR/${user_host}.log"

  echo "[INFO] Updating $server_line" | tee -a "$SUMMARY_FILE"

  for ((i=1; i<=$RETRIES; i++)); do
    echo "[INFO] Attempt $i for $server_line" >> "$log_file"

    if sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$server_line" "MINING_PUBKEY=$MINING_PUBKEY bash -s $([ "$DEBUG_MODE" = true ] && echo '--debug')" < "$SCRIPT_NAME" >> "$log_file" 2>&1; then
      echo "$user_host: ✅ SUCCESS (Attempt $i)" | tee -a "$SUMMARY_FILE"
      return
    else
      echo "[WARN] Attempt $i FAILED for $server_line" >> "$log_file"
      sleep 5
    fi
  done

  echo "$user_host: ❌ FAILED after $RETRIES attempts" | tee -a "$SUMMARY_FILE"
}

export -f run_update
export SCRIPT_NAME PASSWORDS_FILE LOG_DIR SUMMARY_FILE RETRIES MINING_PUBKEY DEBUG_MODE

parallel -j "$PARALLELISM" run_update :::: "$SERVERS_FILE"

printf "\n✅ Update complete. Summary:\n"
cat "$SUMMARY_FILE"
