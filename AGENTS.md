# AGENTS.md — SSH-ops playbook for the headless Mac Studio LLM server

This document codifies the operating contract for the Mac Studio: **it is headless, managed only over SSH, and runs exactly one service (oMLX).** AI agents and humans managing this machine must follow these rules.

---

## Operating assumptions

- **Headless.** No display, no monitor, no GUI session in normal operation.
- **SSH-only management.** All operations happen over `ssh <user>@<MAC_STUDIO_IP>`.
- **One service: oMLX.** No Docker, no Colima, no Open WebUI, no SearXNG on this box. Those run on unRAID / other hosts.
- **macOS 15+ (Sequoia).** Required by oMLX.
- **32GB unified memory.** Budget tightly: one 27B model + KV cache + macOS overhead.

---

## Forbidden operations

Never do any of the following on the Mac Studio:

- ❌ Install GUI applications or assume a browser exists
- ❌ Enable GUI auto-login dialogs that require a display to confirm
- ❌ Assume `open <file>` works (no GUI session)
- ❌ Start Colima, Docker, or any container runtime
- ❌ Install Open WebUI, SearXNG, ChromaDB, or any other LLM-adjacent service
- ❌ Delete `/opt/models/qwen3.6-27b-optiq` (it is the fallback safety net)
- ❌ Run `brew upgrade omlx` without then re-allowlisting the new interpreter in the firewall
- ❌ Assume the admin UI is reachable at `<MAC_STUDIO_IP>:8000/admin` from the Mac Studio itself without a tunnel — use `localhost:8000/admin` over an SSH tunnel

---

## Service lifecycle

oMLX runs as a Homebrew-managed background service. `brew services` generates and manages the launchd plist — **do not create custom LaunchAgent plists**.

```bash
brew services start omlx      # Start (auto-restart on crash, starts at boot)
brew services stop omlx       # Stop
brew services restart omlx    # Restart
brew services info omlx       # Check status
```

---

## Admin UI over SSH tunnel

The oMLX admin dashboard is at `:8000/admin` on the Mac Studio. Since the Mac is headless, you tunnel to it from another machine and open it in your local browser:

```bash
# On your laptop / another LAN machine:
ssh -L 8000:localhost:8000 <user>@<MAC_STUDIO_IP>

# Then, in your LOCAL browser (not on the Mac Studio):
#   http://localhost:8000/admin
```

The tunnel forwards your local port 8000 to the Mac Studio's port 8000. The admin UI is used for:
- Pinning the primary model
- Configuring profiles (thinking on/off)
- Viewing per-model settings, memory usage, and benchmarking
- One-click Hermes / OpenCode / Codex integration setup

**Never** assume `open http://localhost:8000/admin` works on the Mac Studio — there is no GUI.

---

## Logs

| Source | Location |
|---|---|
| oMLX application log | `~/.omlx/logs/server.log` |
| oMLX brew service log | `$(brew --prefix)/var/log/omlx.log` |

Tail over SSH:

```bash
ssh <user>@<MAC_STUDIO_IP> 'tail -f ~/.omlx/logs/server.log'
# Or:
ssh <user>@<MAC_STUDIO_IP> 'tail -f "$(brew --prefix)/var/log/omlx.log"'
```

---

## Model management

Models live in `/opt/models/<name>`. oMLX auto-discovers MLX-format model subdirectories.

### Current models on disk

| Directory | Model | Role |
|---|---|---|
| `/opt/models/qwen3.6-27b-heretic2-uncensored` | `mlx-community/Qwen3.6-27B-Heretic2-Uncensored-Finetune-Thinking-OptiQ-4bit` | Primary (uncensored, OptiQ 4-bit) |
| `/opt/models/qwen3.6-27b-optiq` | `mlx-community/Qwen3.6-27B-OptiQ-4bit` | Fallback (censored, OptiQ 4-bit, proven tool-call) |

### Downloading a new model

```bash
hf download <huggingface-repo-id> --local-dir /opt/models/<name>
```

It will appear in the admin panel's model list after a service restart (or immediately if oMLX watches the directory).

### Swapping the primary model

1. SSH-tunnel to the admin UI (see above).
2. Unpin the current model, pin the desired one from `/opt/models/`.
3. oMLX's LRU eviction handles the swap — only one 27B model is loaded at a time on 32GB.
4. Update any client configs (Hermes, Open WebUI, Home Assistant) to use the new model ID.

### Do NOT delete the fallback

The OptiQ fallback at `/opt/models/qwen3.6-27b-optiq` is the safety net in case the Heretic2 uncensored variant underperforms on Hermes tool-call loops. Keep it on disk even if it is not pinned.

---

## Profile management

Profiles are configured via the admin UI (SSH-tunneled). They expose one loaded model as multiple model IDs on `/v1/models` at zero extra RAM cost.

### Current profiles

| Profile name | Thinking | Use case |
|---|---|---|
| `qwen3.6-27b-heretic2` | OFF | Hermes Agent tool-call (clean JSON, no thinking block) |
| `qwen3.6-27b-heretic2:thinking` | ON | Home Assistant / Open WebUI general chat |

### Why

Hermes tool-call needs thinking OFF — a `<think>` block can consume the token budget before a tool call is emitted. General chat benefits from thinking ON. Profiles let one loaded model serve both use cases.

---

## Firewall

The macOS Application Firewall blocks incoming connections by default. `install.sh` and `update.sh --omlx` automatically add the oMLX listener binary to the allowlist.

**After every `brew upgrade omlx`:** the Python interpreter path changes, so the old firewall rule no longer applies. Re-allowlist:

```bash
OMLX_PID=$(pgrep -f "omlx serve" | head -1)
OMLX_BIN=$(ps -p "$OMLX_PID" -o comm=)
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN"
```

`update.sh --omlx` does this automatically. If you upgrade omlx manually, run the above or `./scripts/update.sh --omlx`.

---

## Verification commands

Quick health check from the Mac Studio over SSH:

```bash
# Service status:
brew services info omlx

# Process:
pgrep -fa "omlx serve"

# API:
curl -s http://localhost:8000/v1/models | python3 -m json.tool

# Admin UI reachable:
curl -sf http://localhost:8000/admin >/dev/null && echo "admin OK"

# RAM pressure:
vm_stat | head -5
sysctl vm.swapusage
```

From another LAN host (verifies firewall + binding):

```bash
curl -s http://<MAC_STUDIO_IP>:8000/v1/models | python3 -m json.tool
```

---

## Endpoint contract for clients

| Property | Value |
|---|---|
| Base URL | `http://<MAC_STUDIO_IP>:8000/v1` |
| API key | (none — unauthenticated, trusted home LAN) |
| Endpoints | `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`, `/v1/rerank` |
| Model field | Use the model ID or profile name from `/v1/models` (not the on-disk path) |

---

## What lives where (quick reference)

| Concern | Where |
|---|---|
| oMLX binary | `$(brew --prefix)/bin/omlx` |
| oMLX venv Python | `$(brew --prefix)/opt/omlx/libexec/bin/python` (the actual listener) |
| Model dir | `/opt/models/` |
| oMLX settings | `~/.omlx/settings.json` |
| oMLX logs | `~/.omlx/logs/server.log`, `$(brew --prefix)/var/log/omlx.log` |
| oMLX cache (optional SSD) | `~/.omlx/cache/` (if `--paged-ssd-cache-dir` enabled) |
| Repo | `~/Developer/headless-mac-llm/` (or wherever cloned) |
| Scripts | `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/status.sh`, `scripts/update.sh` |