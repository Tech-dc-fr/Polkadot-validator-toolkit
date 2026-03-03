# Polkadot Validator Toolkit

A collection of scripts for operating a Polkadot validator node on bare metal infrastructure.

Built for production use. Opinionated about safety.

## What's Inside

### 🔧 Disaster Recovery (`polkadot-recovery.sh`)

Automatic self-healing when your validator crashes repeatedly. Triggered by systemd after 3 failures within 60 seconds.

**What it does:**
- Stops the node and kills any zombie processes
- Verifies no duplicate process is running (equivocation = slashing)
- Checks disk space before proceeding (a full disk would just crash loop again after resync)
- Purges the corrupted database while preserving session keys and network identity
- Restarts the node (warp sync rebuilds the DB in ~15-30 min)
- Runs a health check (service status, peer count, sync state)
- Sends a notification via Discord or Telegram webhook

**What it doesn't do:**
- It will **never** restart a second node if it can't kill the first one. Two validators with the same session keys = equivocation = you get slashed. The script aborts and screams for manual intervention instead.

**Safety features:**
- Lock file prevents concurrent execution
- Auto-detects DB directory (paritydb, rocksdb, db/full)
- Disk space check before purge (avoids resync crash loop on full disk)
- Confirms keystore is intact after DB purge
- Resets systemd failure counter before restart
- 10-minute stale lock expiry as failsafe

### 💰 Auto Payout (`payout.mjs`)

Automatically claims unclaimed staking rewards once a day.

**How it works:**
- Scans the last 84 eras for unclaimed rewards
- Submits `payoutStakers` (or `payoutStakersByPage`) transactions
- Uses a **dedicated payout account** — not your stash
- Supports dry-run mode for safe testing

> On Polkadot, anyone can trigger the payout for any validator. Your stash private key never needs to be on the server.

## Installation

### Disaster Recovery

```bash
# Copy the script
sudo cp polkadot-recovery.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/polkadot-recovery.sh

# Install the systemd service
sudo cp polkadot-recovery.service /etc/systemd/system/

# Add OnFailure trigger to your existing polkadot.service
sudo systemctl edit polkadot
```

Add these lines in the editor that opens:

```ini
[Unit]
OnFailure=polkadot-recovery.service

[Service]
StartLimitBurst=3
StartLimitIntervalSec=60
```

```bash
sudo systemctl daemon-reload
```

**Optional — Discord notifications:**

Edit `/usr/local/bin/polkadot-recovery.sh` and set:
```bash
DISCORD_WEBHOOK="https://discord.com/api/webhooks/your/webhook/url"
```

### Auto Payout

```bash
mkdir ~/payout && cd ~/payout
npm init -y
npm install @polkadot/api @polkadot/keyring dotenv

cp /path/to/payout.mjs .
cp /path/to/.env.payout .env
```

Edit `.env` with your dedicated payout account seed phrase.

**Test (dry run):**
```bash
node payout.mjs
```

**Run for real:**
```bash
node payout.mjs --send
```

**Set up daily cron:**
```bash
echo '0 6 * * * ubuntu cd /home/ubuntu/payout && /usr/bin/node payout.mjs --send >> /var/log/polkadot-payout.log 2>&1' | sudo tee /etc/cron.d/polkadot-payout
```

## How It All Fits Together

```
polkadot.service
    ├── Normal operation
    │     └── Restart=on-failure (handles occasional crashes)
    │
    ├── 3 crashes in 60s → OnFailure triggered
    │     └── polkadot-recovery.service
    │           └── polkadot-recovery.sh
    │                 ├── Kill all processes (anti-equivocation)
    │                 ├── Check disk space (abort if full)
    │                 ├── Purge DB (keep keystore + network)
    │                 ├── Restart → warp sync
    │                 ├── Health check
    │                 └── Notify (Discord/Telegram)
    │
    └── Daily cron
          └── payout.mjs --send
                ├── Scan unclaimed eras
                └── Submit payout txs
```

## Configuration

### Recovery Script

| Variable | Default | Description |
|---|---|---|
| `BASE_PATH` | `/var/lib/polkadot` | Polkadot data directory |
| `CHAIN` | `polkadot` | Chain name (polkadot, kusama, etc.) |
| `SERVICE` | `polkadot` | Systemd service name |
| `DISCORD_WEBHOOK` | *(empty)* | Discord webhook URL for notifications |
| `DISK_THRESHOLD` | `95` | Skip recovery if disk usage exceeds this % |

### Payout Script

| Variable | Source | Description |
|---|---|---|
| `PAYOUT_SEED` | `.env` | Seed phrase of the dedicated payout account |
| `VALIDATOR_STASH` | `.env` or code | Validator stash address |
| `RPC_ENDPOINT` | `.env` or code | WebSocket RPC endpoint |

## Testing

### Test the recovery (simulates 3 rapid crashes):

```bash
# Terminal 1: watch the recovery log
tail -f /var/log/polkadot-recovery.log

# Terminal 2: kill the process 3 times
sudo kill -9 $(pgrep -x polkadot)
sleep 12
sudo kill -9 $(pgrep -x polkadot)
sleep 12
sudo kill -9 $(pgrep -x polkadot)
# → systemd triggers polkadot-recovery.service
```

### Test the payout (dry run):

```bash
cd ~/payout
node payout.mjs
# Shows unclaimed eras without sending any transaction
```

## Requirements

- Ubuntu 22.04+ / Debian 12+
- Polkadot node running as a systemd service
- `jq` and `curl` installed (for recovery script)
- Node.js 18+ (for payout script)

## Security Notes

- The recovery script runs as root (required for `systemctl` and process management)
- The payout script uses a **dedicated account with minimal funds** — never your stash
- The `.env` file containing the payout seed must never be committed to Git
- Add `.env` to your `.gitignore`

## License

MIT — Use at your own risk. This is validator infrastructure; test thoroughly before deploying to production.
