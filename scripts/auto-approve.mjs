#!/usr/bin/env node
/**
 * auto-approve.mjs — Automatically approve submitted work
 * 
 * Usage: node scripts/auto-approve.mjs --job-id 0 --rating 90
 * 
 * Or watch all jobs: node scripts/auto-approve.mjs --watch
 */

import { createWalletClient, createPublicClient, http, formatEther, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry, base } from "viem/chains";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const BOARD_ADDRESS = process.env.BOARD_ADDRESS || "0x25d23b63f166ec74b87b40cbcc5548d29576c56c";

const BOARD_ABI = parseAbi([
  "function approveWork(uint256 jobId, uint8 rating)",
  "function getJobCount() view returns (uint256)",
  "function getJobCore(uint256 jobId) view returns (address poster, string description, uint256 minPrice, uint256 maxPrice, uint256 auctionStart, uint256 auctionDuration, uint256 workDeadline, uint8 status)",
  "function getJobAgent(uint256 jobId) view returns (address agent, uint256 agentId, uint256 claimedAt, string submissionURI, uint256 paidAmount, uint8 rating)",
]);

const args = process.argv.slice(2);
const watchMode = args.includes("--watch");
const jobIdArg = args.includes("--job-id") ? BigInt(args[args.indexOf("--job-id") + 1]) : null;
const ratingArg = args.includes("--rating") ? Number(args[args.indexOf("--rating") + 1]) : 90;

async function main() {
  const chain = RPC_URL.includes("127.0.0.1") ? foundry : base;
  const account = privateKeyToAccount(PRIVATE_KEY);
  const publicClient = createPublicClient({ chain, transport: http(RPC_URL) });
  const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) });

  console.log(`\n✅ Agent Bounty Board — Auto Approver`);
  console.log(`═══════════════════════════════════════`);
  console.log(`Poster: ${account.address}`);
  console.log(`Rating: ${ratingArg}/100`);

  if (jobIdArg !== null) {
    // Approve specific job
    await approveJob(publicClient, walletClient, account.address, jobIdArg, ratingArg);
  } else if (watchMode) {
    // Watch mode: approve any submitted job from our address
    console.log(`\n👀 Watching for submitted work...\n`);
    const approved = new Set();
    
    while (true) {
      const count = await publicClient.readContract({
        address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCount"
      });

      for (let i = 0n; i < count; i++) {
        if (approved.has(Number(i))) continue;
        const [poster, , , , , , , status] = await publicClient.readContract({
          address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCore", args: [i]
        });
        
        if (poster.toLowerCase() === account.address.toLowerCase() && status === 2) {
          await approveJob(publicClient, walletClient, account.address, i, ratingArg);
          approved.add(Number(i));
        } else if (status > 2) {
          approved.add(Number(i));
        }
      }
      await new Promise(r => setTimeout(r, 3000));
    }
  }
}

async function approveJob(publicClient, walletClient, poster, jobId, rating) {
  const [, desc, , , , , , status] = await publicClient.readContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobCore", args: [jobId]
  });
  const [agent, agentId, , submissionURI, paidAmount] = await publicClient.readContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "getJobAgent", args: [jobId]
  });

  if (status !== 2) {
    console.log(`   ⏭️  Job #${jobId} not in Submitted state (status: ${status})`);
    return;
  }

  console.log(`\n   📋 Job #${jobId}: "${desc.slice(0, 50)}..."`);
  console.log(`   🤖 Agent: ${agent.slice(0, 10)}... (8004 #${agentId})`);
  console.log(`   📦 Submission: ${submissionURI.slice(0, 80)}...`);
  console.log(`   💰 Payment: ${formatEther(paidAmount)} CLAWD`);

  const tx = await walletClient.writeContract({
    address: BOARD_ADDRESS, abi: BOARD_ABI, functionName: "approveWork", args: [jobId, rating]
  });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  console.log(`   ✅ Approved with rating ${rating}/100! TX: ${tx}`);
}

main().catch(e => { console.error(e); process.exit(1); });
