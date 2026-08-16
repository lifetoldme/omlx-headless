#!/bin/bash
# =============================================================
# update.sh
# Update the headless oMLX LLM server.
#
# Usage:
#   ./scripts/update.sh              # update everything (default)
#   ./scripts/update.sh --omlx       # update oMLX via Homebrew only
#   ./scripts/update.sh --models     # re-download primary model only
#
# After oMLX updates, the brew service is restarted automatically.
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Config
MODEL_DIR="/opt/models"
PRIMARY_MODEL_REPO="mlx-community/Qwen3.8-27B-4bit"
PRIMARY_MODEL_DIR="${MODEL_DIR}/qwen3.8-27b-4bit"
OMLX_PORT="8000"

# Parse args — default to all if none provided
UPDATE_OMLX=false
UPDATE_MODELS=false
if [ $# -eq 0 ]; then
  UPDATE_OMLX=true
  UPDATE_MODELS=true
else
  for arg in "$@"; do
    case "$arg" in
      --all)    UPDATE_OMLX=true; UPDATE_MODELS=true ;;
      --omlx)   UPDATE_OMLX=true ;;
      --models) UPDATE_MODELS=true ;;
      --help|-h)
        echo "Usage: $0 [--all | --omlx | --models]"
        exit 0
        ;;
      *) log_error "Unknown argument: $arg (use --all, --omlx, or --models)" ;;
    esac
  done
fi

echo ""
echo "=============================================="
echo "  Headless oMLX LLM Server — Update"
echo "=============================================="
echo ""

# --------------------------------------------------------------
# Update oMLX via Homebrew
# --------------------------------------------------------------
if [ "$UPDATE_OMLX" = true ]; then
  echo "--- oMLX ---"
  log_info "Updating Homebrew formulae..."
  brew update

  log_info "Upgrading oMLX..."
  if brew upgrade omlx; then
    log_success "oMLX upgraded"
    log_info "Installed version: $(brew info omlx | head -1)"
  else
    log_error "brew upgrade omlx failed — check \$(brew --prefix)/var/log/omlx.log"
  fi

  log_info "Restarting oMLX brew service..."
  brew services restart omlx
  log_success "oMLX service restarted"

  # Re-allowlist the interpreter after upgrade — the Python binary path
  # changes on each omlx upgrade, so the old firewall rule no longer applies.
  # Only relevant when the macOS Application Firewall is enabled.
  sleep 5  # let the service come up and bind the port
  FW_STATE=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "unknown")
  if echo "$FW_STATE" | grep -qi "disabled"; then
    log_success "Application Firewall is disabled — no rule refresh needed"
  elif pgrep -f "omlx serve" >/dev/null 2>&1; then
    OMLX_PID=$(pgrep -f "omlx serve" | head -1)
    OMLX_BIN=$(ps -p "$OMLX_PID" -o comm= 2>/dev/null || echo "")
    if [ -n "$OMLX_BIN" ] && [ -x "$OMLX_BIN" ]; then
      log_info "Re-allowlisting oMLX listener in macOS firewall..."
      if sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN" 2>/dev/null \
        && sudo -n /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN" 2>/dev/null; then
        log_success "Firewall rule refreshed for: ${OMLX_BIN}"
      else
        log_warn "Firewall refresh needs sudo — run manually:"
        log_warn "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \"$OMLX_BIN\""
        log_warn "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock \"$OMLX_BIN\""
      fi
    else
      log_warn "Could not find oMLX listener binary to re-allowlist"
      log_warn "Run manually: sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \$(ps -p \$(pgrep -f 'omlx serve' | head -1) -o comm=)"
    fi
  else
    log_warn "oMLX process not found after restart — firewall rule not refreshed"
  fi
  echo ""
fi

# --------------------------------------------------------------
# Re-download primary model (catches upstream revisions)
# --------------------------------------------------------------
if [ "$UPDATE_MODELS" = true ]; then
  echo "--- Models ---"
  if ! command -v hf >/dev/null 2>&1; then
    log_warn "huggingface-cli not found — skipping model update"
  else
    log_info "Re-downloading primary model (idempotent — only fetches changes)..."
    log_info "  ${PRIMARY_MODEL_REPO} → ${PRIMARY_MODEL_DIR}"
    hf download "$PRIMARY_MODEL_REPO" --local-dir "$PRIMARY_MODEL_DIR"
    log_success "Primary model is up to date"
  fi
  echo ""
fi

# --------------------------------------------------------------
# Post-update health check
# --------------------------------------------------------------
echo "=============================================="
echo "  Post-update Health Check"
echo "=============================================="

log_info "Waiting 10 seconds for oMLX to settle..."
sleep 10

if brew services info omlx 2>/dev/null | grep -qi "running"; then
  log_success "oMLX brew service is running"
else
  log_warn "oMLX brew service not reporting as running"
fi

if curl -sf --max-time 10 "http://localhost:${OMLX_PORT}/v1/models" >/dev/null 2>&1; then
  log_success "oMLX API responding on :${OMLX_PORT}"
else
  log_warn "oMLX API not responding — model may still be loading"
fi

echo ""
echo "=============================================="
echo "  Update complete!"
echo "=============================================="
echo ""