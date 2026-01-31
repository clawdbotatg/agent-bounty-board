#!/usr/bin/env node
/**
 * poster-demo.mjs — Demo: Post a bounty for image generation
 *
 * Usage:
 *   node scripts/demo/poster-demo.mjs
 *   node scripts/demo/poster-demo.mjs --dry-run
 *
 * Environment (via scripts/demo/.env):
 *   POSTER_PRIVATE_KEY — poster's wallet private key (required)
 *   RPC_URL            — Base RPC (default: Base mainnet via Alchemy)
 *   BOARD_ADDRESS      — AgentBountyBoard contract address
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

const PRIVATE_KEY = process.env.POSTER_PRIVATE_KEY || process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
  console.error("❌ POSTER_PRIVATE_KEY not set. Copy scripts/demo/.env.example to .env and fill in your keys.");
  process.exit(1);
}
const RPC_URL = process.env.RPC_URL || "https://base-mainnet.g.alchemy.com/v2/8GVG8WjDs-sGFRr6Rm839";
const BOARD_ADDRESS = process.env.BOARD_ADDRESS || "0x1aEf2515D21fA590a525ED891cCF1aD0f499c4C9";
const CLAWD_ADDRESS = "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07";

// Demo bounty parameters
const DESCRIPTION = "Generate an image of a robot building a house";
const MIN_PRICE = parseEther("1");       // 1 CLAWD
const MAX_PRICE = parseEther("500");     // 500 CLAWD
const AUCTION_DURATION = 60n;            // 60 seconds
const WORK_DEADLINE = 300n;              // 5 minutes
const AGENT_ID = 21548n;                 // ERC-8004 agent ID

// Parse CLI args
const DRY_RUN = process.argv.includes("--dry-run");

// ═══════════════════════════════════════════
//              CONTRACT ABIs
// ═══════════════════════════════════════════

const BOARD_ABI = parseAbi([
  "function postJob(string description, uint256 minPrice, uint256 maxPrice, uint256 auctionDuration, uint256 workDeadline) returns (uint256)",
  "function getJobCount() view returns (uint256)",
  "function getCurrentPrice(uint256 jobId) view returns (uint256)",
  "function getJobCore(uint256 jobId) view returns (address poster, string description, uint256 minPrice, uint256 maxPrice, uint256 auctionStart, uint256 auctionDuration, uint256 workDeadline, uint8 status)",
  "function getJobAgent(uint256 jobId) view returns (address agent, uint256 agentId, uint256 claimedAt, string submissionURI, uint256 paidAmount, uint8 rating)",
  "event JobPosted(uint256 indexed jobId, address indexed poster, string description, uint256 minPrice, uint256 maxPrice, uint256 auctionDuration, uint256 workDeadline)",
]);

const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
]);

// ═══════════════════════════════════════════
//              MAIN
// ═══════════════════════════════════════════

async function main() {
  const chain = RPC_URL.includes("127.0.0.1") ? foundry : base;
  const account = privateKeyToAccount(PRIVATE_KEY);

  const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });

  console.log(`\n🏗️  Agent Bounty Board — Demo Poster`);
  console.log(`═══════════════════════════════════════`);
  console.log(`Poster:           ${account.address}`);
  console.log(`Board:            ${BOARD_ADDRESS}`);
  console.log(`CLAWD Token:      ${CLAWD_ADDRESS}`);
  console.log(`Description:      ${DESCRIPTION}`);
  console.log(`Price range:      ${formatEther(MIN_PRICE)} → ${formatEther(MAX_PRICE)} CLAWD`);
  console.log(`Auction duration: ${AUCTION_DURATION}s`);
  console.log(`Work deadline:    ${WORK_DEADLINE}s`);
  console.log(`Agent ID:         ${AGENT_ID} (ERC-8004)`);
  if (DRY_RUN) console.log(`\n🔍 DRY RUN — no transactions will be sent`);
  console.log();

  // Check CLAWD balance
  const balance = await publicClient.readContract({
    address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "balanceOf", args: [account.address]
  });
  console.log(`💰 CLAWD balance: ${formatEther(balance)}`);

  if (balance < MAX_PRICE) {
    console.error(`❌ Insufficient CLAWD. Need ${formatEther(MAX_PRICE)}, have ${formatEther(balance)}`);
    process.exit(1);
  }

  // Check current allowance
  const allowance = await publicClient.readContract({
    address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "allowance", args: [account.address, BOARD_ADDRESS]
  });
  console.log(`📝 Current allowance: ${formatEther(allowance)} CLAWD`);

  if (DRY_RUN) {
    console.log(`\n── DRY RUN SUMMARY ──────────────────`);
    if (allowance < MAX_PRICE) {
      console.log(`  1. approve(${BOARD_ADDRESS}, ${formatEther(MAX_PRICE)} CLAWD)`);
    } else {
      console.log(`  1. Allowance sufficient — skip approve`);
    }
    console.log(`  2. postJob(`);
    console.log(`       description: "${DESCRIPTION}",`);
    console.log(`       minPrice:    ${formatEther(MIN_PRICE)} CLAWD,`);
    console.log(`       maxPrice:    ${formatEther(MAX_PRICE)} CLAWD,`);
    console.log(`       auctionDur:  ${AUCTION_DURATION}s,`);
    console.log(`       workDeadline:${WORK_DEADLINE}s`);
    console.log(`     )`);
    console.log(`  3. Escrow: ${formatEther(MAX_PRICE)} CLAWD locked in contract`);
    console.log(`  4. Price ramps 1 → 500 CLAWD over 60 seconds`);
    console.log(`──────────────────────────────────────\n`);
    process.exit(0);
  }

  // Approve CLAWD spending if needed
  if (allowance < MAX_PRICE) {
    console.log(`📝 Approving ${formatEther(MAX_PRICE)} CLAWD for Board...`);
    const approveTx = await walletClient.writeContract({
      address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "approve", args: [BOARD_ADDRESS, MAX_PRICE]
    });
    await publicClient.waitForTransactionReceipt({ hash: approveTx });
    console.log(`✅ Approved — TX: ${approveTx}`);
  } else {
    console.log(`✅ Allowance sufficient — skipping approve`);
  }

  // Post the job
  console.log(`\n📋 Posting bounty...`);
  const postTx = await walletClient.writeContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "postJob",
    args: [DESCRIPTION, MIN_PRICE, MAX_PRICE, AUCTION_DURATION, WORK_DEADLINE]
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: postTx });

  // Get the jobId
  const jobCount = await publicClient.readContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCount"
  });
  const jobId = jobCount - 1n;

  console.log(`\n✅ Bounty #${jobId} posted!`);
  console.log(`   TX:     ${postTx}`);
  console.log(`   Escrow: ${formatEther(MAX_PRICE)} CLAWD`);
  console.log(`   Price ramps: ${formatEther(MIN_PRICE)} → ${formatEther(MAX_PRICE)} CLAWD over ${AUCTION_DURATION}s`);
  console.log();

  // Monitor the bounty
  console.log(`👀 Monitoring bounty #${jobId}...`);
  console.log(`   (Press Ctrl+C to stop)\n`);

  const STATUS_NAMES = ["Open", "Claimed", "Submitted", "Completed", "Disputed", "Expired", "Cancelled"];
  let lastStatus = 0;

  const interval = setInterval(async () => {
    try {
      const [poster, desc, min, max, start, dur, deadline, status] = await publicClient.readContract({
        address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCore", args: [jobId]
      });

      if (status !== lastStatus) {
        console.log(`\n   📌 Status changed: ${STATUS_NAMES[status]}`);
        lastStatus = status;
      }

      if (status === 0) { // Open
        const price = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getCurrentPrice", args: [jobId]
        });
        const now = BigInt(Math.floor(Date.now() / 1000));
        const remaining = (start + dur) > now ? start + dur - now : 0n;
        process.stdout.write(`\r   💰 Current price: ${formatEther(price)} CLAWD | ⏱️  ${remaining}s remaining   `);
      } else if (status === 1) { // Claimed
        const [agent, agentId, claimedAt] = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [jobId]
        });
        const now = BigInt(Math.floor(Date.now() / 1000));
        const deadlineAt = claimedAt + deadline;
        const remaining = deadlineAt > now ? deadlineAt - now : 0n;
        process.stdout.write(`\r   🤖 Agent: ${agent.slice(0, 10)}... (8004 #${agentId}) | ⏱️  ${remaining}s to submit   `);
      } else if (status === 2) { // Submitted
        const [agent, agentId, , submissionURI, paidAmount] = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [jobId]
        });
        console.log(`\n   📦 Work submitted: ${submissionURI.slice(0, 80)}...`);
        console.log(`   💰 Paid: ${formatEther(paidAmount)} CLAWD`);
        console.log(`   → Review and approve via approveWork() or the frontend`);
        clearInterval(interval);
      } else if (status >= 3) {
        const [, , , , paidAmount, rating] = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [jobId]
        });
        if (status === 3) {
          console.log(`\n   ✅ Completed! Rating: ${rating}/100 | Paid: ${formatEther(paidAmount)} CLAWD`);
        } else {
          console.log(`\n   ❌ ${STATUS_NAMES[status]}`);
        }
        clearInterval(interval);
      }
    } catch (e) {
      // Silently retry
    }
  }, 2000);
}

main().catch(e => { console.error(e); process.exit(1); });
