#!/bin/bash
# =============================================================
# uninstall.sh
# Idempotent teardown for the old multi-service LLM stack.
#
# Removes everything the PREVIOUS architecture installed:
#   - The 4 custom LaunchAgents (com.mlx.fast, com.mlx.indepth,
#     com.colima.server, com.localllm.compose)
#   - Colima VM and its disk image
#   - Docker Compose stack (Open WebUI, ChromaDB, SearXNG) + volumes
#   - Old log directory /var/log/mlx/
#   - Old plist files from ~/Library/LaunchAgents/
#
# By default this PRESERVES /opt/models (downloaded weights are
# expensive to re-fetch). Use --purge-models to delete them too.
# By default this does NOT uninstall oMLX. Use --uninstall-omlx for that.
#
# Usage:
#   ./scripts/uninstall.sh                  # tear down old stack, keep models
#   ./scripts/uninstall.sh --purge-models   # also delete /opt/models/*
#   ./scripts/uninstall.sh --uninstall-omlx # also brew uninstall omlx
#   ./scripts/uninstall.sh --all           # purge models + uninstall omlx
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

# Parse args
PURGE_MODELS=false
UNINSTALL_OMLX=false
for arg in "$@"; do
  case "$arg" in
    --purge-models)    PURGE_MODELS=true ;;
    --uninstall-omlx) UNINSTALL_OMLX=true ;;
    --all)            PURGE_MODELS=true; UNINSTALL_OMLX=true ;;
    --help|-h)
      echo "Usage: $0 [--purge-models] [--uninstall-omlx] [--all]"
      echo ""
      echo "  --purge-models     Delete /opt/models/* (downloaded weights)"
      echo "  --uninstall-omlx   Also 'brew uninstall omlx' and stop the service"
      echo "  --all              Both of the above"
      exit 0
      ;;
    *) log_error "Unknown argument: $arg (use --help)" ;;
  esac
done

echo ""
echo "=============================================="
echo "  Headless oMLX LLM Server — Uninstall"
echo "=============================================="
echo ""

if [ "$PURGE_MODELS" = true ] || [ "$UNINSTALL_OMLX" = true ]; then
  log_warn "Destructive flags active:"
  [ "$PURGE_MODELS" = true ]    && log_warn "  --purge-models: /opt/models/* will be DELETED"
  [ "$UNINSTALL_OMLX" = true ]  && log_warn "  --uninstall-omlx: oMLX will be removed via brew"
  echo ""
  read -r -p "Proceed? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --------------------------------------------------------------
# 1. Stop and remove oMLX service (if --uninstall-omlx)
# --------------------------------------------------------------
if [ "$UNINSTALL_OMLX" = true ]; then
  echo "--- oMLX ---"
  if command -v brew >/dev/null 2>&1 && brew list omlx &>/dev/null; then
    log_info "Stopping oMLX brew service..."
    brew services stop omlx 2>/dev/null || true
    log_info "Uninstalling omlx via Homebrew..."
    brew uninstall omlx 2>/dev/null || log_warn "oMLX uninstall failed (may already be removed)"
    log_success "oMLX removed"
  else
    log_info "oMLX not installed via brew — skipping"
  fi
  echo ""
fi

# --------------------------------------------------------------
# 2. Bootout old custom LaunchAgents (best-effort, ignore errors)
#    Handle ALL com.mlx.* plists (fast, indepth, coding, reasoning, etc.)
#    plus the old compose plist.
# --------------------------------------------------------------
echo "--- Old LaunchAgents ---"

# Kill any running mlx_lm.server processes first (gracefully)
if pgrep -f "mlx_lm.server" >/dev/null 2>&1; then
  log_info "Stopping running mlx_lm.server processes..."
  pkill -f "mlx_lm.server" 2>/dev/null || true
  sleep 2
  log_success "mlx_lm.server processes stopped"
fi

# Bootout and remove every com.mlx.* plist (glob — catches fast, indepth, coding, reasoning, etc.)
for dest in "$HOME"/Library/LaunchAgents/com.mlx.*.plist; do
  [ -f "$dest" ] || continue
  plist=$(basename "$dest")
  log_info "Unloading $plist..."
  launchctl bootout "gui/$(id -u)" "$dest" 2>/dev/null || true
  rm -f "$dest"
  log_success "Removed $plist"
done

# Also remove the old compose plist if it exists
COMPOSE_PLIST="$HOME/Library/LaunchAgents/com.localllm.compose.plist"
if [ -f "$COMPOSE_PLIST" ]; then
  log_info "Unloading com.localllm.compose.plist..."
  launchctl bootout "gui/$(id -u)" "$COMPOSE_PLIST" 2>/dev/null || true
  rm -f "$COMPOSE_PLIST"
  log_success "Removed com.localllm.compose.plist"
fi

# Also the old custom colima plist (if the brew-managed one isn't handling it)
OLD_COLIMA_PLIST="$HOME/Library/LaunchAgents/com.colima.server.plist"
if [ -f "$OLD_COLIMA_PLIST" ]; then
  log_info "Unloading com.colima.server.plist..."
  launchctl bootout "gui/$(id -u)" "$OLD_COLIMA_PLIST" 2>/dev/null || true
  rm -f "$OLD_COLIMA_PLIST"
  log_success "Removed com.colima.server.plist"
fi

echo ""

# --------------------------------------------------------------
# 2b. Uninstall pipx mlx-lm (replaced by oMLX)
# --------------------------------------------------------------
echo "--- pipx mlx-lm ---"
if command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q "mlx-lm"; then
  log_info "Uninstalling mlx-lm via pipx..."
  pipx uninstall mlx-lm 2>/dev/null && log_success "mlx-lm removed from pipx" || log_warn "pipx uninstall failed (may need manual cleanup)"
else
  log_info "mlx-lm not installed via pipx — skipping"
fi
echo ""

# --------------------------------------------------------------
# 3. Stop Docker Compose stack and remove it (if present)
# --------------------------------------------------------------
echo "--- Docker Compose stack ---"
COMPOSE_DIR="$HOME/docker/local-llm"
if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  log_info "Stopping Docker Compose stack at $COMPOSE_DIR..."
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" down -v 2>/dev/null \
      && log_success "Compose stack stopped and volumes removed" \
      || log_warn "Compose down failed (Colima may not be running — that's OK)"
  else
    log_warn "docker CLI not found — cannot run compose down"
  fi
  rm -rf "$COMPOSE_DIR"
  log_success "Removed $COMPOSE_DIR"
else
  log_info "No compose stack at $COMPOSE_DIR — skipping"
fi
echo ""

# --------------------------------------------------------------
# 4. Stop and delete Colima VM (if present)
# --------------------------------------------------------------
echo "--- Colima ---"
if command -v colima >/dev/null 2>&1; then
  # Stop the brew-managed colima service if it's registered
  if launchctl list 2>/dev/null | grep -q "homebrew.mxcl.colima"; then
    log_info "Stopping brew-managed Colima service..."
    brew services stop colima 2>/dev/null || true
  fi
  if colima status 2>&1 | grep -q "colima is running"; then
    log_info "Stopping Colima..."
    colima stop 2>/dev/null || true
    log_success "Colima stopped"
  else
    log_info "Colima is not running"
  fi
  log_info "Deleting Colima VM and disk image..."
  read -r -p "Delete the Colima VM and its disk? [y/N] " colima_response
  case "$colima_response" in
    [yY][eE][sS]|[yY])
      colima delete --force 2>/dev/null || true
      log_success "Colima VM deleted"
      ;;
    *)
      log_info "Keeping Colima VM (you can delete it later with: colima delete --force)"
      ;;
  esac
else
  log_info "Colima not installed — skipping"
fi
echo ""

# --------------------------------------------------------------
# 5. Remove old log directory
# --------------------------------------------------------------
echo "--- Old logs ---"
if [ -d /var/log/mlx ]; then
  if [ -w /var/log/mlx ] && [ "$(ls -A /var/log/mlx 2>/dev/null | wc -l)" -eq 0 ]; then
    rmdir /var/log/mlx 2>/dev/null && log_success "Removed empty /var/log/mlx" || true
  else
    log_info "/var/log/mlx is not empty or not writable by you — leaving it"
    log_info "To force-remove: sudo rm -rf /var/log/mlx"
  fi
else
  log_info "/var/log/mlx not present — skipping"
fi
echo ""

# --------------------------------------------------------------
# 6. Remove old DOCKER_HOST and cliPluginsExtraDirs config (optional)
# --------------------------------------------------------------
echo "--- Shell/Docker config cleanup ---"
DOCKER_HOST_LINE='export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"'
if grep -qF "$DOCKER_HOST_LINE" ~/.zshrc 2>/dev/null; then
  log_info "Removing DOCKER_HOST line from ~/.zshrc..."
  # Use a temp file to safely remove the line + the comment we added
  tmpfile=$(mktemp)
  grep -vF "$DOCKER_HOST_LINE" ~/.zshrc > "$tmpfile" 2>/dev/null || true
  # Also remove the "# Added by local-llm install.sh" comment if it's now orphaned
  mv "$tmpfile" ~/.zshrc
  log_success "DOCKER_HOST removed from ~/.zshrc"
  log_warn "Review ~/.zshrc for any leftover Colima-related lines"
else
  log_info "No DOCKER_HOST line in ~/.zshrc — skipping"
fi

# Remove ~/.docker/config.json cliPluginsExtraDirs entry if it only pointed at Colima's plugin dir
if [ -f ~/.docker/config.json ]; then
  if python3 -c "import json,sys; d=json.load(open('$HOME/.docker/config.json')); sys.exit(0 if d.get('cliPluginsExtraDirs')==['/opt/homebrew/lib/docker/cli-plugins'] else 1)" 2>/dev/null; then
    log_info "Removing ~/.docker/config.json (only contained Colima plugin path)..."
    rm -f ~/.docker/config.json
    log_success "Removed ~/.docker/config.json"
  else
    log_info "~/.docker/config.json has other entries — leaving it"
  fi
fi
echo ""

# --------------------------------------------------------------
# 7. Optionally purge models
# --------------------------------------------------------------
if [ "$PURGE_MODELS" = true ]; then
  echo "--- Model purge ---"
  if [ -d /opt/models ]; then
    log_warn "Deleting /opt/models/* ..."
    sudo rm -rf /opt/models
    log_success "/opt/models purged"
  else
    log_info "/opt/models not present — skipping"
  fi
  echo ""
fi

# --------------------------------------------------------------
# 8. Summary
# --------------------------------------------------------------
echo "=============================================="
echo "  Uninstall complete"
echo ""
echo "  What was removed:"
echo "    - Old custom LaunchAgents (all com.mlx.*, com.colima.*, com.localllm.*)"
echo "    - Docker Compose stack + volumes (Open WebUI, ChromaDB, SearXNG)"
echo "    - pipx mlx-lm (replaced by oMLX)"
[ "$UNINSTALL_OMLX" = true ] && echo "    - oMLX brew package and service"
[ "$PURGE_MODELS" = true ] && echo "    - /opt/models/* (all downloaded weights)"
echo ""
echo "  What was preserved (by default):"
echo "    - /opt/models/* (downloaded weights — re-usable by oMLX)"
[ "$UNINSTALL_OMLX" = false ] && echo "    - oMLX brew package and service (use --uninstall-omlx to remove)"
echo "    - Homebrew, huggingface-cli, your shell profile"
echo ""
echo "  Ports now free: 8000 (oMLX if uninstalled), 3000, 8080, 8081 (old stack)"
echo "=============================================="
echo ""