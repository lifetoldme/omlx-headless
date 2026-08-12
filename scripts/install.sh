#!/bin/bash
# =============================================================
# install.sh
# One-shot setup for the headless oMLX LLM server on Apple Silicon.
#
# This Mac Studio is HEADLESS and managed only over SSH. No GUI apps,
# no Docker, no Colima, no Open WebUI, no SearXNG. Just oMLX serving
# one model on :8000 to Home Assistant, Open WebUI (on unRAID), and
# Hermes Agent — all on other LAN hosts.
#
# Usage: ./scripts/install.sh
# =============================================================

set -e  # Exit immediately on any error

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Config
MODEL_DIR="/opt/models"
PRIMARY_MODEL_REPO="mlx-community/Qwen3.6-27B-Heretic2-Uncensored-Finetune-Thinking-OptiQ-4bit"
PRIMARY_MODEL_DIR="${MODEL_DIR}/qwen3.6-27b-heretic2-uncensored"
FALLBACK_MODEL_REPO="mlx-community/Qwen3.6-27B-OptiQ-4bit"
FALLBACK_MODEL_DIR="${MODEL_DIR}/qwen3.6-27b-optiq"
OMLX_PORT="8000"

echo ""
echo "=============================================="
echo "  Headless oMLX LLM Server — Install"
echo "=============================================="
echo ""

# --------------------------------------------------------------
# 1. Check prerequisites
# --------------------------------------------------------------
log_info "Checking prerequisites..."

command -v brew >/dev/null 2>&1 || log_error "Homebrew is not installed. Install it first: https://brew.sh"

if ! command -v hf >/dev/null 2>&1; then
  log_info "Installing huggingface-cli via Homebrew..."
  brew install hf
else
  log_success "huggingface-cli already installed"
fi

# --------------------------------------------------------------
# 2. Install oMLX via Homebrew
# --------------------------------------------------------------
log_info "Installing oMLX via Homebrew..."

if ! brew tap | grep -q "jundot/omlx"; then
  brew tap jundot/omlx https://github.com/jundot/omlx
fi

if brew list omlx &>/dev/null; then
  log_info "oMLX already installed, upgrading..."
  brew upgrade omlx 2>/dev/null || log_success "oMLX already at latest version"
else
  brew install omlx
  log_success "oMLX installed"
fi

# Verify the omlx CLI is on PATH
if ! command -v omlx >/dev/null 2>&1; then
  log_error "omlx CLI not found on PATH after install. Try: brew link omlx"
fi
log_success "omlx CLI found at: $(command -v omlx)"

# --------------------------------------------------------------
# 3. Prepare model directory
# --------------------------------------------------------------
log_info "Preparing model directory at ${MODEL_DIR}..."

if [ ! -d "$MODEL_DIR" ]; then
  sudo mkdir -p "$MODEL_DIR"
  sudo chown "$(whoami)" "$MODEL_DIR"
  log_success "Created ${MODEL_DIR}"
else
  log_success "${MODEL_DIR} already exists"
fi

# --------------------------------------------------------------
# 4. Download primary model (Heretic2 uncensored + OptiQ 4-bit)
# --------------------------------------------------------------
log_info "Checking primary model: ${PRIMARY_MODEL_REPO}"

if [ -d "$PRIMARY_MODEL_DIR" ] && [ "$(ls -A "$PRIMARY_MODEL_DIR" 2>/dev/null | head -1)" ]; then
  log_success "Primary model already present at ${PRIMARY_MODEL_DIR}"
else
  log_info "Downloading primary model (~17.5GB)..."
  log_info "  ${PRIMARY_MODEL_REPO} → ${PRIMARY_MODEL_DIR}"
  hf download "$PRIMARY_MODEL_REPO" --local-dir "$PRIMARY_MODEL_DIR"
  log_success "Primary model downloaded"
fi

# --------------------------------------------------------------
# 5. Ensure fallback model (OptiQ 4-bit) is preserved
# --------------------------------------------------------------
log_info "Checking fallback model: ${FALLBACK_MODEL_REPO}"

if [ -d "$FALLBACK_MODEL_DIR" ] && [ "$(ls -A "$FALLBACK_MODEL_DIR" 2>/dev/null | head -1)" ]; then
  log_success "Fallback model preserved at ${FALLBACK_MODEL_DIR}"
else
  log_warn "Fallback model not found at ${FALLBACK_MODEL_DIR}"
  log_info "  The fallback (censored OptiQ) is a safety net in case the"
  log_info "  Heretic2 uncensored variant underperforms on Hermes tool-call."
  log_info "  To download it later:"
  log_info "    hf download ${FALLBACK_MODEL_REPO} --local-dir ${FALLBACK_MODEL_DIR}"
fi

# --------------------------------------------------------------
# 6. Persist oMLX settings (model-dir, host, port)
# --------------------------------------------------------------
log_info "Persisting oMLX settings to ~/.omlx/settings.json..."

mkdir -p ~/.omlx

# oMLX persists settings to ~/.omlx/settings.json when `omlx serve` runs
# with CLI flags. We start it briefly in the background to write the
# settings, then stop it and let `brew services` manage the lifecycle.
#
# The flags below set:
#   --model-dir  : where oMLX discovers models (subdirectories of MLX models)
#   --host       : bind to all interfaces so LAN clients can reach :8000
#   --port       : the OpenAI-compatible API port (default 8000)
#
# NOTE: If `--host` is not a valid flag in your oMLX version, check
#   `omlx serve --help` for the equivalent (may be an env var OMLX_HOST).
#   The settings.json file is read by `brew services` on start.
# Start oMLX briefly in the background so it writes ~/.omlx/settings.json,
# then stop it. `brew services` will later pick up the persisted settings.
SETTINGS_PERSISTED=false
omlx serve --model-dir "$MODEL_DIR" --host 0.0.0.0 --port "$OMLX_PORT" >/dev/null 2>&1 &
OMLX_PID=$!
sleep 3  # let it write settings.json and begin listening
if kill -0 "$OMLX_PID" 2>/dev/null; then
  kill "$OMLX_PID" 2>/dev/null
  wait "$OMLX_PID" 2>/dev/null || true
  SETTINGS_PERSISTED=true
  log_success "oMLX settings persisted (model-dir=${MODEL_DIR}, host=0.0.0.0, port=${OMLX_PORT})"
else
  log_warn "oMLX foreground start failed — check 'omlx serve --help' for flag compatibility"
  log_warn "Will fall back to brew services with env vars"
fi

# --------------------------------------------------------------
# 7. Start oMLX as a managed background service
# --------------------------------------------------------------
log_info "Starting oMLX as a brew service (auto-restart on crash, starts at boot)..."

# Stop any existing instance first (idempotent)
brew services stop omlx 2>/dev/null || true

# If settings persisted above, brew services picks up ~/.omlx/settings.json.
# If not, pass env vars inline via the brew services run.
if [ "$SETTINGS_PERSISTED" = true ]; then
  brew services start omlx
else
  # Fallback: set env vars in the brew service context
  OMLX_MODEL_DIR="$MODEL_DIR" OMLX_HOST=0.0.0.0 OMLX_PORT="$OMLX_PORT" brew services start omlx
fi

sleep 5  # let the service come up

if brew services info omlx 2>/dev/null | grep -qi "running"; then
  log_success "oMLX service is running"
else
  log_warn "oMLX service may still be starting — check: brew services info omlx"
fi

# --------------------------------------------------------------
# 8. Firewall — allow incoming LAN connections to oMLX
# --------------------------------------------------------------
log_info "Configuring macOS firewall to allow LAN access to oMLX..."

# oMLX runs under a brew-venv Python interpreter. Find the actual binary
# that listens on :8000 and allowlist it.
OMLX_BIN=""
if pgrep -f "omlx" >/dev/null 2>&1; then
  # Discover the actual listening binary via lsof
  OMLX_BIN=$(lsof -nP -iTCP:"$OMLX_PORT" -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $1}')
  if [ -n "$OMLX_BIN" ]; then
    # Resolve the full path of the process binary
    OMLX_PID=$(pgrep -f "omlx" | head -1)
    OMLX_BIN=$(ps -p "$OMLX_PID" -o comm= 2>/dev/null || echo "")
  fi
fi

if [ -n "$OMLX_BIN" ] && [ -x "$OMLX_BIN" ]; then
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN" 2>/dev/null || true
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN" 2>/dev/null || true
  log_success "Firewall rule added for: ${OMLX_BIN}"
  log_warn "NOTE: re-run this after 'brew upgrade omlx' (the interpreter path changes)"
else
  log_warn "Could not auto-discover the oMLX listener binary for the firewall."
  log_warn "After verifying the server is up, run manually:"
  log_warn "  LISTENER=\$(lsof -nP -iTCP:${OMLX_PORT} -sTCP:LISTEN | tail -1 | awk '{print \$1}')"
  log_warn "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add \"\$LISTENER\""
  log_warn "  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock \"\$LISTENER\""
fi

# --------------------------------------------------------------
# 9. Final health check
# --------------------------------------------------------------
echo ""
log_info "Waiting 15 seconds for oMLX to load models..."
sleep 15

echo ""
echo "=============================================="
echo "  Health Check"
echo "=============================================="

# oMLX service
if brew services info omlx 2>/dev/null | grep -qi "running"; then
  log_success "oMLX brew service is running"
else
  log_warn "oMLX service not reporting as running"
  log_warn "Check: brew services info omlx"
fi

# oMLX API
if curl -sf --max-time 10 "http://localhost:${OMLX_PORT}/v1/models" >/dev/null 2>&1; then
  log_success "oMLX API responding on :${OMLX_PORT}"
else
  log_warn "oMLX API not responding — model may still be loading"
fi

# List discovered models
echo ""
log_info "Discovered models at http://localhost:${OMLX_PORT}/v1/models:"
curl -s --max-time 10 "http://localhost:${OMLX_PORT}/v1/models" 2>/dev/null \
  | python3 -c "import sys,json; [print(f'  - {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null \
  || log_warn "Could not list models (API may still be starting)"

echo ""
echo "=============================================="
echo "  Install complete!"
echo ""
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "<MAC_STUDIO_IP>")
echo "  oMLX API:           http://${HOST_IP}:${OMLX_PORT}/v1"
echo "  oMLX Admin UI:      http://${HOST_IP}:${OMLX_PORT}/admin"
echo ""
echo "  Headless access to Admin UI (from another machine):"
echo "    ssh -L ${OMLX_PORT}:localhost:${OMLX_PORT} ${USER}@${HOST_IP}"
echo "  Then open http://localhost:${OMLX_PORT}/admin in your browser"
echo ""
echo "  Next steps:"
echo "    1. Use the Admin UI to pin the primary model and configure"
echo "       profiles (thinking on/off) — see README.md"
echo "    2. Point Hermes / Open WebUI / Home Assistant at the endpoint"
echo "       above (see README.md per-app routing guide)"
echo "    3. Verify with: ./scripts/status.sh"
echo "=============================================="
echo ""