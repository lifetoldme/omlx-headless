#!/bin/bash
# =============================================================
# status.sh
# Health check for the headless oMLX LLM server.
#
# This Mac Studio is headless (SSH-only). This script verifies:
#   - oMLX brew service is running
#   - oMLX process is alive
#   - /v1/models endpoint responds and lists expected models
#   - /admin dashboard is reachable
#   - No recent errors in the oMLX server log
#   - System RAM pressure (swap usage) — critical for 32GB boxes
#
# Usage: ./scripts/status.sh
# =============================================================

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; }
warn() { echo -e "  ${YELLOW}!${NC}  $1"; }
info() { echo -e "  ${BLUE}→${NC}  $1"; }

OMLX_PORT="8000"
MODEL_DIR="/opt/models"

echo ""
echo -e "${BOLD}=============================================="
echo "  Headless oMLX LLM Server — Status"
echo "==============================================${NC}"
echo ""

# --------------------------------------------------------------
# brew service
# --------------------------------------------------------------
echo -e "${BOLD}oMLX Service${NC}"

if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew not found on PATH"
else
  SERVICE_INFO=$(brew services info omlx 2>/dev/null)
  if echo "$SERVICE_INFO" | grep -qi "running"; then
    pass "oMLX brew service is running"
  elif echo "$SERVICE_INFO" | grep -qi "error"; then
    fail "oMLX brew service is in error state"
    info "Inspect: brew services info omlx"
  elif echo "$SERVICE_INFO" | grep -qi "not running\|stopped"; then
    fail "oMLX brew service is NOT running"
    info "Start it: brew services start omlx"
  else
    warn "oMLX brew service status unknown"
    info "$SERVICE_INFO"
  fi
fi
echo ""

# --------------------------------------------------------------
# Process
# --------------------------------------------------------------
echo -e "${BOLD}Processes${NC}"

if pgrep -f "omlx" >/dev/null 2>&1; then
  PID=$(pgrep -f "omlx" | tr '\n' ' ')
  pass "omlx process running (PID $PID)"
else
  fail "omlx process not found"
  info "If the brew service shows running but no process, check the log:"
  info "  tail -50 ~/.omlx/logs/server.log"
fi
echo ""

# --------------------------------------------------------------
# API endpoint
# --------------------------------------------------------------
echo -e "${BOLD}API Endpoints${NC}"

check_endpoint() {
  local name="$1"
  local url="$2"
  local expected="$3"

  response=$(curl -sf --max-time 5 "$url" 2>/dev/null)
  if [ $? -ne 0 ]; then
    fail "$name — not responding ($url)"
    return
  fi
  if [ -n "$expected" ] && ! echo "$response" | grep -q "$expected"; then
    warn "$name — responding but unexpected output ($url)"
    return
  fi
  pass "$name — responding ($url)"
}

check_endpoint "oMLX /v1/models"  "http://localhost:${OMLX_PORT}/v1/models"  "model"
check_endpoint "oMLX /admin"      "http://localhost:${OMLX_PORT}/admin"     ""
echo ""

# --------------------------------------------------------------
# Discovered models
# --------------------------------------------------------------
echo -e "${BOLD}Discovered Models${NC}"

MODELS_RESPONSE=$(curl -s --max-time 5 "http://localhost:${OMLX_PORT}/v1/models" 2>/dev/null)
if [ -n "$MODELS_RESPONSE" ]; then
  echo "$MODELS_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    models = data.get('data', [])
    if not models:
        print('  !  No models discovered — check --model-dir path')
    for m in models:
        print(f'  →  {m[\"id\"]}')
except Exception:
    print('  ✘  Could not parse /v1/models response')
" 2>/dev/null || warn "Could not list models"
else
  fail "oMLX API not responding — cannot list models"
fi
echo ""

# --------------------------------------------------------------
# Model directory on disk
# --------------------------------------------------------------
echo -e "${BOLD}Model Directory${NC}"

if [ -d "$MODEL_DIR" ]; then
  pass "$MODEL_DIR exists"
  info "On-disk models:"
  for d in "$MODEL_DIR"/*/; do
    [ -d "$d" ] && info "  $(basename "$d")"
  done
  [ -z "$(ls -d "$MODEL_DIR"/*/ 2>/dev/null)" ] && warn "No model subdirectories found in $MODEL_DIR"
else
  fail "$MODEL_DIR not found — models must be downloaded first"
fi
echo ""

# --------------------------------------------------------------
# Recent errors
# --------------------------------------------------------------
echo -e "${BOLD}Recent Errors (oMLX server log)${NC}"

SERVER_LOG="$HOME/.omlx/logs/server.log"
if [ -f "$SERVER_LOG" ]; then
  errors=$(tail -n 50 "$SERVER_LOG" | grep -i "error\|failed\|fatal\|exception" | tail -n 5)
  if [ -n "$errors" ]; then
    warn "Recent errors in $(basename "$SERVER_LOG"):"
    echo "$errors" | while IFS= read -r line; do
      warn "  $line"
    done
  else
    pass "No recent errors in server.log"
  fi
else
  warn "Server log not found: $SERVER_LOG"
  info "Logs appear after the first start. Check: brew services info omlx"
fi

# Also check the brew service log if it exists
BREW_LOG="$(brew --prefix 2>/dev/null)/var/log/omlx.log"
if [ -f "$BREW_LOG" ]; then
  brew_errors=$(tail -n 20 "$BREW_LOG" | grep -i "error\|failed\|fatal" | tail -n 3)
  if [ -n "$brew_errors" ]; then
    warn "Recent errors in omlx.log (brew service):"
    echo "$brew_errors" | while IFS= read -r line; do
      warn "  $line"
    done
  fi
fi
echo ""

# --------------------------------------------------------------
# RAM pressure
# --------------------------------------------------------------
echo -e "${BOLD}RAM Pressure${NC}"

# vm_stat gives us free/active/inactive/wired/speculative counts
PAGE_SIZE=$(vm_stat 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo "4096")
FREE_PAGES=$(vm_stat 2>/dev/null | grep "free" | awk '{print $3}' | tr -d '.' || echo "0")
SWAP_INS=$(sysctl vm.swapusage 2>/dev/null | grep -oE 'used = [0-9.]+[KMG]' | head -1 || echo "")

if [ -n "$SWAP_INS" ] && ! echo "$SWAP_INS" | grep -q "0G"; then
  warn "Swap in use: $SWAP_INS — 32GB box may be under memory pressure"
  warn "during concurrent Home Assistant + Hermes load"
else
  pass "No significant swap usage"
fi

# Total system RAM
TOTAL_MEM=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
if [ "$TOTAL_MEM" -gt 0 ] 2>/dev/null; then
  TOTAL_GB=$(( TOTAL_MEM / 1024 / 1024 / 1024 ))
  info "Total system RAM: ${TOTAL_GB} GB"
fi
echo ""

# --------------------------------------------------------------
# Network summary
# --------------------------------------------------------------
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")
echo -e "${BOLD}Network${NC}"
info "Host IP:        $HOST_IP"
info "oMLX API:        http://${HOST_IP}:${OMLX_PORT}/v1"
info "oMLX Admin:      http://${HOST_IP}:${OMLX_PORT}/admin"
echo ""
echo -e "${BOLD}Headless access to Admin UI (from another machine):${NC}"
info "  ssh -L ${OMLX_PORT}:localhost:${OMLX_PORT} ${USER}@${HOST_IP}"
info "  Then open http://localhost:${OMLX_PORT}/admin in your browser"

echo ""
echo -e "${BOLD}==============================================${NC}"
echo ""