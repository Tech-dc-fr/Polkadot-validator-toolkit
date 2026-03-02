#!/usr/bin/env node
/**
 * Polkadot Validator — Auto Payout Staking Rewards
 *
 * Automatically claims unclaimed staking rewards for a validator.
 *
 * SECURITY:
 * - Uses a dedicated PAYOUT account (NOT your stash!)
 *   → A separate account with ~2-5 DOT to cover transaction fees
 *   → Anyone can trigger payout for any validator, no special permissions needed
 * - The seed phrase for the PAYOUT account lives in a separate .env file
 * - NEVER put your stash seed phrase here
 *
 * INSTALL:
 *   mkdir ~/payout && cd ~/payout
 *   npm init -y
 *   npm install @polkadot/api @polkadot/keyring dotenv
 *   cp payout.mjs ~/payout/
 *   cp .env.payout ~/payout/.env
 *
 * USAGE:
 *   node payout.mjs              # dry-run (prints without sending)
 *   node payout.mjs --send       # sends transactions
 *
 * CRON (once a day at 6 AM):
 *   0 6 * * * cd /home/ubuntu/payout && /usr/bin/node payout.mjs --send >> /var/log/polkadot-payout.log 2>&1
 */

import { ApiPromise, WsProvider } from '@polkadot/api';
import { Keyring } from '@polkadot/keyring';
import { config } from 'dotenv';

config(); // load .env

// ── CONFIG ──
const VALIDATOR_STASH = process.env.VALIDATOR_STASH || '16Pb7ykJ1X1gB8HtsH7JqX5E6brjMqAqxhWEHRByGwhuv9nu';
const RPC_ENDPOINT    = process.env.RPC_ENDPOINT || 'wss://polkadot-asset-hub-rpc.polkadot.io';
const PAYOUT_SEED     = process.env.PAYOUT_SEED;
const DRY_RUN         = !process.argv.includes('--send');
const MAX_ERAS        = 84; // Polkadot keeps 84 eras of unclaimed rewards

// ── MAIN ──
async function main() {
  if (!PAYOUT_SEED) {
    console.error('❌ PAYOUT_SEED missing from .env');
    console.error('   Create a .env file with: PAYOUT_SEED="word1 word2 ... word12"');
    process.exit(1);
  }

  const ts = new Date().toISOString();
  console.log(`\n[${ts}] Polkadot Payout ${DRY_RUN ? '(DRY RUN)' : '(LIVE)'}`);
  console.log(`Validator: ${VALIDATOR_STASH}`);
  console.log(`RPC: ${RPC_ENDPOINT}\n`);

  // Connect
  const provider = new WsProvider(RPC_ENDPOINT);
  const api = await ApiPromise.create({ provider });
  console.log(`✓ Connected to ${(await api.rpc.system.chain()).toString()}`);

  // Current era
  const activeEra = (await api.query.staking.activeEra()).unwrap().index.toNumber();
  console.log(`✓ Active era: ${activeEra}`);

  // Find unclaimed eras
  const unclaimedEras = [];

  for (let era = activeEra - 1; era >= Math.max(activeEra - MAX_ERAS, 0); era--) {
    try {
      // Check if validator was active in this era
      const exposure = await api.query.staking.erasStakersOverview(era, VALIDATOR_STASH);

      if (exposure.isNone || exposure.isEmpty) continue;

      // Check if already claimed
      const claimed = await api.query.staking.claimedRewards(era, VALIDATOR_STASH);

      if (claimed.length === 0 || claimed.isEmpty) {
        unclaimedEras.push(era);
        console.log(`  Era ${era} → unclaimed reward ✓`);
      }
    } catch (_) {
      // Era not available or error, skip
    }
  }

  if (unclaimedEras.length === 0) {
    console.log('\n✓ No rewards to claim. Everything is up to date.');
    await api.disconnect();
    return;
  }

  console.log(`\n${unclaimedEras.length} era(s) to payout: [${unclaimedEras.join(', ')}]`);

  if (DRY_RUN) {
    console.log('\n⚠ DRY RUN — no transactions sent.');
    console.log('  Run again with --send to submit transactions.');
    await api.disconnect();
    return;
  }

  // Prepare payout account
  const keyring = new Keyring({ type: 'sr25519', ss58Format: 0 });
  const payoutAccount = keyring.addFromUri(PAYOUT_SEED);
  console.log(`\nPayout account: ${payoutAccount.address}`);

  // Check payout account balance
  const { data: balance } = await api.query.system.account(payoutAccount.address);
  const freeDot = balance.free.toBigInt() / 10000000000n;
  console.log(`Balance: ${freeDot} DOT`);

  if (freeDot < 1n) {
    console.error('❌ Insufficient balance for tx fees. Send at least 2 DOT to this account.');
    await api.disconnect();
    process.exit(1);
  }

  // Send payouts
  let success = 0;
  let failed = 0;

  for (const era of unclaimedEras) {
    try {
      console.log(`\n→ Payout era ${era}...`);

      // payoutStakersByPage for newer runtimes, payoutStakers as fallback
      const tx = api.tx.staking.payoutStakersByPage
        ? api.tx.staking.payoutStakersByPage(VALIDATOR_STASH, era, 0)
        : api.tx.staking.payoutStakers(VALIDATOR_STASH, era);

      const hash = await tx.signAndSend(payoutAccount);
      console.log(`  ✓ Era ${era} payout sent — tx: ${hash.toHex()}`);
      success++;

      // Delay between txs to avoid nonce conflicts
      await new Promise(r => setTimeout(r, 6000));
    } catch (err) {
      console.error(`  ✗ Era ${era} failed: ${err.message}`);
      failed++;
    }
  }

  console.log(`\n── Result ──`);
  console.log(`✓ ${success} payout(s) sent`);
  if (failed > 0) console.log(`✗ ${failed} failure(s)`);

  await api.disconnect();
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
