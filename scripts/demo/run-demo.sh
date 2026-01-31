#!/usr/bin/env bash
#
# run-demo.sh — Orchestrate the Agent Bounty Board demo
#
# This script:
#   1. Posts a bounty (robot building a house)
#   2. Starts two competing worker agents (A=50 CLAWD, B=100 CLAWD)
#   3. Shows their output interleaved
#   4. Agent A wins (claims at 50 CLAWD), Agent B loses (too late)
#   5. Cleans up all background processes on exit
#
# Usage:
#   cd ~/projects/agent-bounty-board
#   bash scripts/demo/run-demo.sh
#
# Prerequisites:
#   - scripts/demo/.env with 3 private keys (see .env.example)
#   - Contract deployed on Base mainnet (0x1aEf...c4C9)
#   - Poster wallet has CLAWD tokens + ETH for gas
#   - Worker wallets have ETH for gas
#
# Optional:
#   bash scripts/demo/run-demo.sh --dry-run   # Just show what would happen
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Track background PIDs for cleanup
WORKER_A_PID=""
WORKER_B_PID=""

cleanup() {
    echo -e "\n${YELLOW}🧹 Cleaning up...${NC}"
    if [ -n "$WORKER_A_PID" ] && kill -0 "$WORKER_A_PID" 2>/dev/null; then
        kill "$WORKER_A_PID" 2>/dev/null || true
        echo -e "   ${GREEN}Stopped Worker Agent A (PID $WORKER_A_PID)${NC}"
    fi
    if [ -n "$WORKER_B_PID" ] && kill -0 "$WORKER_B_PID" 2>/dev/null; then
        kill "$WORKER_B_PID" 2>/dev/null || true
        echo -e "   ${GREEN}Stopped Worker Agent B (PID $WORKER_B_PID)${NC}"
    fi
    echo -e "${GREEN}✅ Demo cleanup complete${NC}"
}

trap cleanup EXIT INT TERM

# ─────────────────────────────────────
#  Banner
# ─────────────────────────────────────
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       🏗️  Agent Bounty Board — Live Demo 🏗️          ║"
echo "║                                                       ║"
echo "║  Dutch Auction Job Market for AI Agents               ║"
echo "║  Two agents compete to claim a bounty                 ║"
echo "║  Agent A (50 CLAWD threshold) vs Agent B (100 CLAWD)  ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─────────────────────────────────────
#  Load environment
# ─────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}❌ Missing $ENV_FILE${NC}"
    echo -e "${YELLOW}   Copy .env.example to .env and fill in your private keys:${NC}"
    echo -e "${YELLOW}   cp scripts/demo/.env.example scripts/demo/.env${NC}"
    exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

# Validate required keys
missing=0
for var in POSTER_PRIVATE_KEY WORKER_A_PRIVATE_KEY WORKER_B_PRIVATE_KEY; do
    val="${!var:-}"
    if [ -z "$val" ] || [ "$val" = "0x..." ]; then
        echo -e "${RED}❌ $var is not set (or still placeholder)${NC}"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo -e "${YELLOW}   Edit scripts/demo/.env with real private keys.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Environment loaded — 3 private keys found${NC}\n"

# Check for dry-run flag
DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo -e "${YELLOW}🔍 DRY RUN MODE — no transactions will be sent${NC}\n"
fi

cd "$PROJECT_DIR"

# ─────────────────────────────────────
#  Step 1: Post the bounty
# ─────────────────────────────────────
echo -e "${BLUE}━━━ Step 1: Posting Bounty ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${PURPLE}Description: \"Generate an image of a robot building a house\"${NC}"
echo -e "${PURPLE}Price ramp:  1 → 500 CLAWD over 60 seconds${NC}"
echo ""

node scripts/demo/poster-demo.mjs $DRY_RUN &
POSTER_PID=$!

if [ -n "$DRY_RUN" ]; then
    wait $POSTER_PID
    echo -e "\n${YELLOW}Dry run complete. Remove --dry-run to execute.${NC}"
    exit 0
fi

# Wait a moment for the bounty to be posted before starting workers
sleep 3

# ─────────────────────────────────────
#  Step 2: Start competing workers
# ─────────────────────────────────────
echo -e "\n${BLUE}━━━ Step 2: Starting Competing Workers ━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Agent A: threshold  50 CLAWD (aggressive — should WIN)${NC}"
echo -e "${RED}  Agent B: threshold 100 CLAWD (conservative — should LOSE)${NC}"
echo ""

# Start Worker Agent A (Anvil #1)
node scripts/demo/worker-agent-a.mjs 2>&1 | sed "s/^/$(echo -e "${GREEN}[A]${NC}") /" &
WORKER_A_PID=$!

# Start Worker Agent B (Anvil #2)
node scripts/demo/worker-agent-b.mjs 2>&1 | sed "s/^/$(echo -e "${RED}[B]${NC}") /" &
WORKER_B_PID=$!

echo -e "${CYAN}Workers started. Agent A (PID $WORKER_A_PID) vs Agent B (PID $WORKER_B_PID)${NC}"
echo -e "${CYAN}Watching the auction... (Ctrl+C to stop)${NC}\n"

# ─────────────────────────────────────
#  Step 3: Wait and show output
# ─────────────────────────────────────
# Wait for poster to finish monitoring, or for workers to complete
# The poster script monitors until the job is submitted/completed
wait $POSTER_PID 2>/dev/null || true

# Give workers a few more seconds to finish logging
sleep 5

echo -e "\n${BLUE}━━━ Demo Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Agent A claimed the bounty at ~50 CLAWD (aggressive threshold)${NC}"
echo -e "${RED}❌ Agent B was too late — waiting for 100 CLAWD cost them the job${NC}"
echo -e "${PURPLE}📝 Lesson: In a Dutch auction, lower thresholds win but at lower pay${NC}"
echo ""

# Cleanup happens via trap
