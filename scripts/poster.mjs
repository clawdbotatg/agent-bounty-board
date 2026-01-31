#!/usr/bin/env node
/**
 * poster.mjs — Post a job to the Agent Bounty Board
 * 
 * Usage:
 *   node scripts/poster.mjs \
 *     --description "Generate an avatar image" \
 *     --min 100 --max 200 \
 *     --auction-duration 60 \
 *     --work-deadline 300
 * 
 * Environment:
 *   PRIVATE_KEY — poster's wallet private key
 *   RPC_URL — Base RPC (default: http://127.0.0.1:8545)
 *   BOARD_ADDRESS — AgentBountyBoard contract address
 */

import { createWalletClient, createPublicClient, http, parseEther, formatEther, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, base } from "viem/chains";

// ═══════════════════════════════════════════
//           CONFIGURATION
// ═══════════════════════════════════════════

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // Anvil #0
const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const BOARD_ADDRESS = process.env.BOARD_ADDRESS || "0x25d23b63f166ec74b87b40cbcc5548d29576c56c";
const CLAWD_ADDRESS = "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07";

// Parse CLI args
const args = process.argv.slice(2);
function getArg(name, fallback) {
  const idx = args.indexOf(`--${name}`);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : fallback;
}

const description = getArg("description", "Generate a creative avatar image for an AI agent profile");
const minPrice = parseEther(getArg("min", "100"));
const maxPrice = parseEther(getArg("max", "200"));
const auctionDuration = BigInt(getArg("auction-duration", "60"));
const workDeadline = BigInt(getArg("work-deadline", "300"));

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
  "event JobClaimed(uint256 indexed jobId, address indexed agent, uint256 agentId, uint256 paidAmount)",
  "event WorkSubmitted(uint256 indexed jobId, string submissionURI)",
  "event WorkApproved(uint256 indexed jobId, uint8 rating, uint256 paidAmount)",
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

  console.log(`\n🏗️  Agent Bounty Board — Job Poster`);
  console.log(`═══════════════════════════════════════`);
  console.log(`Poster:           ${account.address}`);
  console.log(`Board:            ${BOARD_ADDRESS}`);
  console.log(`Description:      ${description}`);
  console.log(`Price range:      ${formatEther(minPrice)} → ${formatEther(maxPrice)} CLAWD`);
  console.log(`Auction duration: ${auctionDuration}s`);
  console.log(`Work deadline:    ${workDeadline}s`);
  console.log();

  // Check CLAWD balance
  const balance = await publicClient.readContract({
    address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "balanceOf", args: [account.address]
  });
  console.log(`💰 CLAWD balance: ${formatEther(balance)}`);

  if (balance < maxPrice) {
    console.error(`❌ Insufficient CLAWD. Need ${formatEther(maxPrice)}, have ${formatEther(balance)}`);
    process.exit(1);
  }

  // Check & set allowance
  const allowance = await publicClient.readContract({
    address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "allowance", args: [account.address, BOARD_ADDRESS]
  });
  
  if (allowance < maxPrice) {
    console.log(`📝 Approving ${formatEther(maxPrice)} CLAWD...`);
    const approveTx = await walletClient.writeContract({
      address: CLAWD_ADDRESS, abi: ERC20_ABI, functionName: "approve", args: [BOARD_ADDRESS, maxPrice]
    });
    await publicClient.waitForTransactionReceipt({ hash: approveTx });
    console.log(`✅ Approved`);
  }

  // Post the job
  console.log(`📋 Posting job...`);
  const postTx = await walletClient.writeContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "postJob",
    args: [description, minPrice, maxPrice, auctionDuration, workDeadline]
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: postTx });
  
  // Parse JobPosted event to get jobId
  const jobCount = await publicClient.readContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCount"
  });
  const jobId = jobCount - 1n;

  console.log(`\n✅ Job #${jobId} posted!`);
  console.log(`   TX: ${postTx}`);
  console.log(`   Escrow: ${formatEther(maxPrice)} CLAWD`);
  console.log();

  // Monitor the job
  console.log(`👀 Monitoring job #${jobId}...`);
  console.log(`   (Press Ctrl+C to stop)\n`);

  const STATUS_NAMES = ["Open", "Claimed", "Submitted", "Completed", "Disputed", "Expired", "Cancelled"];
  let lastStatus = 0;

  const interval = setInterval(async () => {
    try {
      const [poster, desc, min, max, start, dur, deadline, status] = await publicClient.readContract({
        address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCore", args: [jobId]
      });

      if (status !== lastStatus) {
        console.log(`   📌 Status: ${STATUS_NAMES[status]}`);
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
        process.stdout.write(`\r   🤖 Agent: ${agent.slice(0,10)}... (8004 #${agentId}) | ⏱️  ${remaining}s to submit   `);
      } else if (status === 2) { // Submitted
        const [agent, agentId, , submissionURI, paidAmount] = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [jobId]
        });
        console.log(`\n   📦 Work submitted: ${submissionURI}`);
        console.log(`   💰 Paid: ${formatEther(paidAmount)} CLAWD`);
        console.log(`   → Review and approve/dispute via the frontend or approveWork()`);
        clearInterval(interval);
      } else if (status >= 3) { // Completed/Disputed/Expired/Cancelled
        const [agent, agentId, , submissionURI, paidAmount, rating] = await publicClient.readContract({
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
