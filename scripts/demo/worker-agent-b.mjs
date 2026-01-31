#!/usr/bin/env node
/**
 * worker-agent-b.mjs — Demo Worker B: Conservative bidder (threshold 100 CLAWD)
 *
 * This agent waits until the Dutch auction price reaches 100 CLAWD.
 * In the demo, it should LOSE the race to Agent A (threshold 50 CLAWD).
 *
 * Usage:
 *   node scripts/demo/worker-agent-b.mjs
 *
 * Environment (via scripts/demo/.env):
 *   WORKER_B_PRIVATE_KEY — agent's wallet private key (required)
 *   RPC_URL              — Base RPC (default: Base mainnet via Alchemy)
 *   BOARD_ADDRESS        — AgentBountyBoard contract address
 */

import { createWalletClient, createPublicClient, http, parseEther, formatEther, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, base } from "viem/chains";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, resolve } from "path";

// Load .env from scripts/demo/ directory (no dotenv dependency needed)
const __dirname = dirname(fileURLToPath(import.meta.url));
try {
  const envFile = readFileSync(resolve(__dirname, ".env"), "utf8");
  for (const line of envFile.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIdx = trimmed.indexOf("=");
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    const val = trimmed.slice(eqIdx + 1).trim();
    if (!process.env[key]) process.env[key] = val;
  }
} catch { /* .env optional if vars already exported */ }

// ═══════════════════════════════════════════
//           CONFIGURATION
// ═══════════════════════════════════════════

const PRIVATE_KEY = process.env.WORKER_B_PRIVATE_KEY || process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
  console.error("❌ WORKER_B_PRIVATE_KEY not set. Copy scripts/demo/.env.example to .env and fill in your keys.");
  process.exit(1);
}
const RPC_URL = process.env.RPC_URL || "https://base-mainnet.g.alchemy.com/v2/8GVG8WjDs-sGFRr6Rm839";
const BOARD_ADDRESS = process.env.BOARD_ADDRESS || "0x1aEf2515D21fA590a525ED891cCF1aD0f499c4C9";
const CLAWD_ADDRESS = "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07";
const AGENT_ID = 99999n; // Different agent ID from Agent A

// Agent B waits for price >= 100 CLAWD (more conservative, loses the race)
const PRICE_THRESHOLD = parseEther("100");
const POLL_INTERVAL_MS = 2000; // 2 seconds

// ═══════════════════════════════════════════
//              CONTRACT ABIs
// ═══════════════════════════════════════════

const BOARD_ABI = parseAbi([
  "function claimJob(uint256 jobId, uint256 agentId)",
  "function submitWork(uint256 jobId, string submissionURI)",
  "function getJobCount() view returns (uint256)",
  "function getCurrentPrice(uint256 jobId) view returns (uint256)",
  "function getJobCore(uint256 jobId) view returns (address poster, string description, uint256 minPrice, uint256 maxPrice, uint256 auctionStart, uint256 auctionDuration, uint256 workDeadline, uint8 status)",
  "function getJobAgent(uint256 jobId) view returns (address agent, uint256 agentId, uint256 claimedAt, string submissionURI, uint256 paidAmount, uint8 rating)",
]);

// ═══════════════════════════════════════════
//              MAIN LOOP
// ═══════════════════════════════════════════

async function main() {
  const chain = RPC_URL.includes("127.0.0.1") ? foundry : base;
  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });

  console.log(`\n🤖 Agent Bounty Board — Worker Agent B`);
  console.log(`═══════════════════════════════════════`);
  console.log(`Agent Wallet:    ${account.address}`);
  console.log(`Agent ID:        ${AGENT_ID} (ERC-8004)`);
  console.log(`Board:           ${BOARD_ADDRESS}`);
  console.log(`Price Threshold: ${formatEther(PRICE_THRESHOLD)} CLAWD`);
  console.log(`Poll Interval:   ${POLL_INTERVAL_MS}ms`);
  console.log(`Strategy:        🔴 CONSERVATIVE — wait for higher price (will lose race)`);
  console.log();

  const processedJobs = new Set();

  console.log(`👀 Scanning for bounties...\n`);

  while (true) {
    try {
      const jobCount = await publicClient.readContract({
        address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCount"
      });

      for (let i = 0n; i < jobCount; i++) {
        if (processedJobs.has(Number(i))) continue;

        const [poster, description, minPrice, maxPrice, auctionStart, auctionDuration, workDeadline, status] =
          await publicClient.readContract({
            address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCore", args: [i]
          });

        // Skip non-open jobs
        if (status !== 0) {
          if (status === 1 || status === 2) {
            // Check if we claimed it (we shouldn't have in the demo)
            const [agent] = await publicClient.readContract({
              address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [i]
            });
            if (agent.toLowerCase() === account.address.toLowerCase()) {
              console.log(`   ✅ [Agent B] Job #${i} — we claimed this one!`);
            } else {
              console.log(`   😤 [Agent B] Job #${i} — LOST! Claimed by ${agent.slice(0, 10)}... before our threshold was met`);
            }
          }
          processedJobs.add(Number(i));
          continue;
        }

        // Check current price
        const currentPrice = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getCurrentPrice", args: [i]
        });

        const now = BigInt(Math.floor(Date.now() / 1000));
        const remaining = (auctionStart + auctionDuration) > now ? auctionStart + auctionDuration - now : 0n;

        if (currentPrice < PRICE_THRESHOLD) {
          console.log(`   ⏳ [Agent B] Job #${i}: price ${formatEther(currentPrice)} CLAWD < threshold ${formatEther(PRICE_THRESHOLD)} | ⏱️  ${remaining}s left`);
          continue; // Wait for price to rise
        }

        // Price is at or above our threshold — CLAIM IT!
        console.log(`\n   🎯 [Agent B] Job #${i}: "${description.slice(0, 60)}"`);
        console.log(`   💰 [Agent B] Price ${formatEther(currentPrice)} CLAWD >= threshold ${formatEther(PRICE_THRESHOLD)} — CLAIMING!`);

        try {
          const claimTx = await walletClient.writeContract({
            address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "claimJob", args: [i, AGENT_ID]
          });
          await publicClient.waitForTransactionReceipt({ hash: claimTx });
          console.log(`   ✅ [Agent B] Claimed job #${i}! TX: ${claimTx}`);

          // Simulate work (5 seconds)
          console.log(`   ⚙️  [Agent B] Working on job #${i}... (simulating 5s)`);
          await new Promise(r => setTimeout(r, 5000));

          // Submit a fake result hash
          const fakeResultHash = `ipfs://QmDemo_AgentB_Job${i}_${Date.now().toString(36)}`;
          console.log(`   📤 [Agent B] Submitting result: ${fakeResultHash}`);

          const submitTx = await walletClient.writeContract({
            address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "submitWork", args: [i, fakeResultHash]
          });
          await publicClient.waitForTransactionReceipt({ hash: submitTx });
          console.log(`   ✅ [Agent B] Work submitted! TX: ${submitTx}`);
          console.log(`   🏆 [Agent B] Job #${i} complete — awaiting poster approval\n`);

          processedJobs.add(Number(i));
        } catch (e) {
          const msg = e.message || String(e);
          if (msg.includes("Job not open")) {
            console.log(`   💀 [Agent B] Job #${i} — TOO LATE! Already claimed by another agent.`);
            console.log(`   📉 [Agent B] Lesson: waiting for ${formatEther(PRICE_THRESHOLD)} CLAWD was too greedy.\n`);
          } else {
            console.log(`   ❌ [Agent B] Failed on job #${i}: ${msg.slice(0, 120)}`);
          }
          processedJobs.add(Number(i));
        }
      }
    } catch (e) {
      // Silently retry on RPC errors
    }

    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch(e => { console.error(e); process.exit(1); });
