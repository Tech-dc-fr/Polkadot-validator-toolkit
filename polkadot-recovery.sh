#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Polkadot Validator — Disaster Recovery (Auto-Healing)
# ══════════════════════════════════════════════════════════════
# Triggered by systemd OnFailure after 3 crashes within 60s.
#
# Sequence:
#   1. Lock file (prevent concurrent execution)
#   2. Full stop + zombie kill (anti-equivocation)
#   3. Verify NO polkadot process is running
#   4. Auto-detect database directory
#   5. Purge DB only (keystore + network identity preserved)
#   6. Restart service → warp sync takes over
#   7. Post-restart health check (peers + sync status)
#   8. Notification (optional Discord/Telegram webhook)
# ══════════════════════════════════════════════════════════════

set -euo pipefail

LOG="/var/log/polkadot-recovery.log"
LOCK="/tmp/polkadot-recovery.lock"
BASE_PATH="/var/lib/polkadot"
CHAIN="polkadot"
CHAIN_DIR="$BASE_PATH/chains/$CHAIN"
SERVICE="polkadot"

# Optional notification webhooks (leave empty to disable)
DISCORD_WEBHOOK=""
# TELEGRAM_BOT_TOKEN=""
# TELEGRAM_CHAT_ID=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG"; }

notify() {
  local msg="$1"
  # Discord
  if [ -n "$DISCORD_WEBHOOK" ]; then
    curl -s --max-time 10 -H "Content-Type: application/json" \
      -d "{\"content\":\"🚨 **Polkadot Validator** — $msg\"}" \
      "$DISCORD_WEBHOOK" > /dev/null 2>&1 || true
  fi
  # Telegram (uncomment if needed)
  # if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
  #   curl -s --max-time 10 \
  #     "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  #     -d "chat_id=${TELEGRAM_CHAT_ID}&text=🚨 Polkadot Validator — $msg" > /dev/null 2>&1 || true
  # fi
}

# ── STEP 0: Lock file to prevent concurrent execution ──
if [ -f "$LOCK" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK") ))
  if [ "$LOCK_AGE" -lt 600 ]; then
    log "[SKIP] Recovery already in progress (lock age: ${LOCK_AGE}s). Aborting."
    exit 0
  fi
  log "[WARNING] Stale lock found (${LOCK_AGE}s). Removing and proceeding."
  rm -f "$LOCK"
fi
trap 'rm -f "$LOCK"' EXIT
touch "$LOCK"

log "════════════════════════════════════════"
log "[ALERT] Crash detected. Starting Disaster Recovery."
notify "Crash detected — Recovery in progress..."

# ── STEP 1: Full stop (anti-equivocation) ──
log "Stopping $SERVICE service..."
systemctl stop "$SERVICE" 2>/dev/null || true
sleep 5

# Aggressive kill if zombie process remains
if pgrep -x "polkadot" > /dev/null; then
  log "[WARNING] Rogue process detected → sending SIGKILL"
  pkill -9 -x polkadot || true
  sleep 3
fi

# ── CRITICAL CHECK: no polkadot process must be running ──
if pgrep -x "polkadot" > /dev/null; then
  log "[CRITICAL] Unable to kill polkadot process!"
  log "[CRITICAL] ABORTING recovery to prevent equivocation."
  notify "⛔ CRITICAL — Cannot stop polkadot. Recovery aborted. MANUAL INTERVENTION REQUIRED."
  exit 1
fi
log "✓ No polkadot process running. Safe to proceed."

# ── STEP 2: Auto-detect database directory ──
DB_DIR=""
for candidate in \
  "$CHAIN_DIR/paritydb" \
  "$CHAIN_DIR/db/full" \
  "$CHAIN_DIR/db" \
  "$CHAIN_DIR/rocksdb"; do
  if [ -d "$candidate" ]; then
    DB_DIR="$candidate"
    break
  fi
done

if [ -z "$DB_DIR" ]; then
  log "[WARNING] No DB directory found. Node will resync from scratch."
else
  DB_SIZE=$(du -sh "$DB_DIR" 2>/dev/null | cut -f1)
  log "Removing corrupted DB: $DB_DIR ($DB_SIZE)"
  rm -rf "$DB_DIR"
  log "✓ Database removed."
fi

# ── Verify: keystore and network identity still intact ──
if [ -d "$CHAIN_DIR/keystore" ]; then
  KEY_COUNT=$(ls "$CHAIN_DIR/keystore" 2>/dev/null | wc -l)
  log "✓ Keystore intact ($KEY_COUNT keys)"
else
  log "[WARNING] Keystore missing! Session keys will need to be regenerated."
  notify "⚠️ Keystore missing after DB purge. Session keys must be regenerated!"
fi

if [ -d "$CHAIN_DIR/network" ]; then
  log "✓ Network identity intact"
else
  log "[INFO] Network identity missing (will be regenerated automatically)"
fi

# ── STEP 3: Restart ──
log "Restarting $SERVICE service (warp sync)..."
# Reset systemd failure counter to prevent restart refusal
systemctl reset-failed "$SERVICE" 2>/dev/null || true
systemctl start "$SERVICE"

# ── STEP 4: Post-restart health check ──
sleep 15
if systemctl is-active --quiet "$SERVICE"; then
  log "✓ Service $SERVICE is active."

  # Check peers after 30s
  sleep 30
  PEERS=$(curl -s --max-time 5 -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"system_health"}' \
    http://127.0.0.1:9944 2>/dev/null | jq -r '.result.peers // 0' 2>/dev/null || echo "0")

  SYNC=$(curl -s --max-time 5 -H 'Content-Type: application/json' \
    -d '{"id":1,"jsonrpc":"2.0","method":"system_health"}' \
    http://127.0.0.1:9944 2>/dev/null | jq -r '.result.isSyncing // "unknown"' 2>/dev/null || echo "unknown")

  log "  Peers: $PEERS | Syncing: $SYNC"

  if [ "$PEERS" -gt 0 ] 2>/dev/null; then
    log "[SUCCESS] Recovery complete. Node connected with $PEERS peers."
    notify "✅ Recovery successful — $PEERS peers, syncing: $SYNC"
  else
    log "[WARNING] Service active but 0 peers. Warp sync may take a few minutes."
    notify "⚠️ Recovery complete but 0 peers yet. Monitor closely."
  fi
else
  log "[FAILURE] Service did not restart!"
  notify "❌ FAILURE — Service did not restart after recovery. MANUAL INTERVENTION REQUIRED."
  exit 1
fi

log "════════════════════════════════════════"
