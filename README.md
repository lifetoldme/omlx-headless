# Headless Mac Studio LLM Server (oMLX)

A single-purpose, SSH-managed Apple Silicon Mac Studio running [oMLX](https://github.com/jundot/omlx) to serve one local LLM over the LAN to Home Assistant, Open WebUI (on unRAID), and Hermes Agent (on another host).

**This Mac is headless.** No display, no Docker, no Colima, no Open WebUI, no SearXNG, no GUI apps. It is managed exclusively over SSH. The only service it runs is oMLX.

---

## Architecture

```
macOS (headless, SSH-only — no Docker, no Colima)
└── oMLX (brew service, auto-restart on crash, starts at boot)
    ├── Port 8000, bound to 0.0.0.0
    ├── Model dir: /opt/models
    ├── Primary: qwen3.8-27b-4bit (VLM, 4-bit, ~16.9GB, censored base)
    ├── Rollbacks (on disk, swappable): qwen3.6-27b-heretic2-uncensored (uncensored)
    │                                  qwen3.6-27b-optiq (proven tool-call)
    ├── Profiles (zero extra RAM):
    │   ├── qwen3.8-27b-4bit:qwen3-8-27b-tool      (thinking OFF — Hermes tool-call)
    │   └── qwen3.8-27b-4bit:qwen3-8-27b-thinking  (thinking ON  — HA / Open WebUI chat)
    └── Admin UI: :8000/admin  (SSH-tunneled from another machine)

Clients (all on OTHER LAN hosts — nothing else runs on the Mac Studio):
├── Home Assistant          → http://<MAC_STUDIO_IP>:8000/v1
├── Open WebUI (on unRAID)  → http://<MAC_STUDIO_IP>:8000/v1
└── Hermes Agent            → http://<MAC_STUDIO_IP>:8000/v1
```

oMLX exposes an OpenAI-compatible endpoint (`/v1/chat/completions`, `/v1/models`) with continuous batching and tiered KV caching (RAM hot tier + SSD cold tier) — far better than `mlx_lm.server` for concurrent HA + Hermes load on a single endpoint.

---

## Hardware Requirements

- Apple Silicon Mac (M1 or later)
- 32GB unified memory recommended (the 27B model at 4-bit is ~16.9GB weights + KV cache)
- macOS 15.0+ (Sequoia) — required by oMLX

---

## Prerequisites

Install Homebrew and the HuggingFace CLI:

```bash
# Homebrew (if not already installed): https://brew.sh
brew install hf
```

oMLX is installed via Homebrew (see [Deployment](#deployment) below) — no `pipx`, no `mlx-lm` direct install. oMLX bundles its own MLX runtime.

---

## Deployment

### 1. Clone the repo

```bash
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/<you>/omlx-headless.git
cd omlx-headless
chmod +x scripts/*.sh
```

### 2. Run the install script

```bash
./scripts/install.sh
```

This single command:
1. Installs oMLX via Homebrew (`brew tap jundot/omlx && brew install omlx`)
2. Creates `/opt/models` if missing (preserves any existing models)
3. Downloads the primary model: `mlx-community/Qwen3.8-27B-4bit` (~16.9GB)
4. Preserves the fallback model at `/opt/models/qwen3.6-27b-optiq` if already present
5. Persists oMLX settings (`~/.omlx/settings.json`) with `--model-dir /opt/models --host 0.0.0.0 --port 8000`
6. Starts oMLX as a brew service (`brew services start omlx` — auto-restart on crash, starts at boot)
7. Adds the oMLX listener to the macOS Application Firewall allowlist
8. Runs a health check and prints the LAN endpoint URL

### 3. Configure model profiles (via Admin UI)

Profiles are configured via the oMLX admin panel — there is no GUI on the Mac Studio, so you tunnel in from another machine:

```bash
# On your laptop / another LAN machine:
ssh -L 8000:localhost:8000 <user>@<MAC_STUDIO_IP>
# Then open http://localhost:8000/admin in your local browser
```

In the admin panel:
1. **Pin** the primary model (`qwen3.8-27b-4bit`) so it stays loaded.
2. **Create two profiles** for the pinned model:
   - `qwen3.8-27b:tool` — chat template kwargs `{"enable_thinking": false}` (for Hermes tool-call)
   - `qwen3.8-27b:thinking` — default kwargs (thinking ON, for general chat)
3. **Expose both profiles as models** (toggle "Expose as model" on each) so they appear on `/v1/models`.
4. **Disable API key auth** if you want unauthenticated LAN access (see [API key warning](#api-key-warning-on-first-connect) below).

> **Why profiles?** Hermes tool-call needs thinking OFF (a thinking block can consume the token budget before a tool call is emitted). General chat benefits from thinking ON. Profiles let one loaded model serve both use cases without a second model in memory.

#### API key warning on first connect

The oMLX admin panel **generates and requires an API key on first connect** — clients calling `/v1/models` or `/v1/chat/completions` without it get `{"error":{"message":"API key required"}}`. If you want the unauthenticated trusted-home-LAN setup this repo documents, disable it after first connect:

- In the admin panel: **Settings → Auth → skip API key verification** (toggle on), then clear the `api_key` field.
- Or edit `~/.omlx/settings.json` directly: set `auth.skip_api_key_verification` to `true` and `auth.api_key` to `""`.
- Then: `brew services restart omlx`

If you prefer to keep the API key, point each client (HA, Open WebUI, Hermes) at the key instead. The endpoint contract in [AGENTS.md](AGENTS.md) assumes unauthenticated — update it if you keep the key.

### 4. Verify

```bash
./scripts/status.sh
```

---

## Auto-start (brew services)

oMLX runs as a Homebrew-managed background service. No custom LaunchAgent plists are needed — `brew services` generates and manages the launchd plist automatically.

| Command | Action |
|---|---|
| `brew services start omlx` | Start (auto-restart on crash, starts at boot) |
| `brew services stop omlx` | Stop |
| `brew services restart omlx` | Restart |
| `brew services info omlx` | Check status |

The service reads `~/.omlx/settings.json` (persisted by `install.sh` or `omlx serve --flags`) on start.

> **Auto-login:** The brew service runs as your user and starts at user login. Enable auto-login: System Settings → General → Login Items & Extensions. For a truly headless box, auto-login of a non-admin user is the standard pattern.

---

## Configuration

### oMLX server settings

Settings are persisted to `~/.omlx/settings.json` and can be edited via the admin UI (`:8000/admin`) or by running `omlx serve` with new flags (which overwrites the file).

| Setting | Value | Notes |
|---|---|---|
| Model dir | `/opt/models` | oMLX auto-discovers MLX model subdirectories |
| Host | `0.0.0.0` | Bind to all interfaces for LAN access |
| Port | `8000` | Default oMLX port |
| Memory guard | `balanced` (default) | Adjust via `--memory-guard safe` or `--memory-guard-gb <N>` |

### Primary model

| Property | Value |
|---|---|
| HuggingFace repo | `mlx-community/Qwen3.8-27B-4bit` |
| Local path | `/opt/models/qwen3.8-27b-4bit` |
| Quant | 4-bit (~16.9GB weights), full VLM (vision tower included) |
| Base | Qwen3.8-27B (Qwen3.5-architecture hybrid: Gated DeltaNet + attention) |
| Tool-call | Qwen3.5-series XML `<function=...>` format — verified working |
| Thinking | ON by default; `enable_thinking` + `reasoning_effort` (xhigh/medium/low) supported |
| oMLX requirement | >= 0.6.0rc1 |

### Fallback / rollback models

| Property | Value |
|---|---|
| Rollback repo | `mlx-community/Qwen3.6-27B-Heretic2-Uncensored-Finetune-Thinking-OptiQ-4bit` |
| Rollback path | `/opt/models/qwen3.6-27b-heretic2-uncensored` (uncensored) |
| Fallback repo | `mlx-community/Qwen3.6-27B-OptiQ-4bit` |
| Fallback path | `/opt/models/qwen3.6-27b-optiq` |
| Fallback tool-call | Proven (BFCL-V3 function-calling score: 92.5%) |

Both stay on disk as safety nets. If Qwen3.8 underperforms on Hermes tool-call loops, swap to the OptiQ fallback via the oMLX admin panel (or `is_pinned` in `~/.omlx/model_settings.json`); if censorship refusals bite, swap to the Heretic2 rollback. No re-download needed.

### Swapping models

1. Open the admin UI over SSH tunnel (see [Configure model profiles](#configure-model-profiles-via-admin-ui)).
2. In the admin panel, unpin the current model and pin the desired one from `/opt/models/`.
3. oMLX's LRU eviction handles the swap; only one 27B model is loaded at a time on 32GB.

To download a new model to disk:

```bash
hf download <repo-id> --local-dir /opt/models/<name>
```

It will then appear in the admin panel's model list automatically.

---

## Per-app routing guide

All clients point at the same endpoint. The `model` field in requests selects which model/profile to use.

| App | Endpoint | Model field | Profile |
|---|---|---|---|
| **Home Assistant** | `http://<MAC_STUDIO_IP>:8000/v1` | `qwen3.8-27b-4bit:qwen3-8-27b-thinking` | Thinking ON for richer HA responses |
| **Open WebUI (unRAID)** | `http://<MAC_STUDIO_IP>:8000/v1` | pick from model picker | Both profiles available |
| **Hermes Agent** | `http://<MAC_STUDIO_IP>:8000/v1` | `qwen3.8-27b-4bit:qwen3-8-27b-tool` | Thinking OFF for clean tool calls |

Find the Mac Studio's LAN IP:

```bash
# On the Mac Studio:
ipconfig getifaddr en0
# (status.sh also prints it in the Network section)
```

---

## Hermes Agent integration

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is a self-improving AI agent by Nous Research. It works with any OpenAI-compatible endpoint. oMLX has a one-click Hermes integration in the admin panel, but you can also configure it manually:

### Firewall — allow LAN access to :8000

`install.sh` adds the oMLX listener to the macOS Application Firewall allowlist automatically. If you reload the service after a `brew upgrade omlx`, re-run the firewall refresh (the interpreter path changes on upgrade):

```bash
# On the Mac Studio (after omlx upgrade):
OMLX_PID=$(pgrep -f "omlx serve" | head -1)
OMLX_BIN=$(ps -p "$OMLX_PID" -o comm=)
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN"
```

`update.sh --omlx` does this automatically.

Verify from the Hermes host (not the Mac Studio):

```bash
curl -s http://<MAC_STUDIO_IP>:8000/v1/models | python3 -m json.tool
```

### Install Hermes (on the Hermes host, not the Mac Studio)

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.zshrc
```

### Point Hermes at the oMLX endpoint

```bash
hermes model
# → Select "Custom endpoint (self-hosted / VLLM / etc.)"
# → API base URL:  http://<MAC_STUDIO_IP>:8000/v1
# → API key:       (leave blank — local server needs none)
# → Model name:    qwen3.8-27b-4bit:qwen3-8-27b-tool
```

Or set it directly:

```bash
hermes config set model.provider custom
hermes config set model.base_url http://<MAC_STUDIO_IP>:8000/v1
hermes config set model.default qwen3.8-27b-4bit:qwen3-8-27b-tool
```

> **Use the model alias/profile name, not the local path.** oMLX advertises model IDs (aliases or directory names) on `/v1/models`, not on-disk paths like the old `mlx_lm.server` did. Check `curl http://localhost:8000/v1/models` for the exact IDs to use.

### Context length requirement

Hermes **rejects** endpoints with under 64,000 tokens of context at startup. oMLX uses the model's native context window by default (Qwen3.6-27B supports 128k), so this is satisfied out of the box.

### Why thinking is disabled for Hermes

The `qwen3.8-27b-4bit:qwen3-8-27b-tool` profile passes `{"enable_thinking": false}`. Reasoning models emit a `<think>…</think>` block *before* the answer; in an agent loop that block can consume the entire token budget before a tool call is emitted, and the resulting tool-call JSON is often malformed. Disabling thinking keeps tool calls clean and reliable.

### Verify the integration

```bash
# 1. On the Mac Studio — endpoint up and serving the primary model:
curl -s http://localhost:8000/v1/models

# 2. On the Hermes host — reachable over the LAN:
curl -s http://<MAC_STUDIO_IP>:8000/v1/models

# 3. On the Hermes host — Hermes starts without rejecting the endpoint:
hermes

# 4. Run one simple tool-call turn in Hermes (e.g. ask it to list files
#    in the current directory) and confirm the tool call completes
#    end-to-end without a truncated/malformed response.
```

> **If Qwen3.8 tool-call is unreliable:** swap to the fallback via the admin panel (pin `/opt/models/qwen3.6-27b-optiq`, unpin Qwen3.8), then update Hermes: `hermes config set model.default qwen3.6-27b-optiq`. If censorship refusals bite, swap to the Heretic2 rollback at `/opt/models/qwen3.6-27b-heretic2-uncensored`. No re-architecting needed.

---

## Open WebUI on unRAID

Open WebUI runs on your unRAID server (not on the Mac Studio). Point it at the Mac Studio's oMLX endpoint:

1. In Open WebUI: **Admin → Connections**
2. Add a new OpenAI-compatible connection:
   - **Base URL:** `http://<MAC_STUDIO_IP>:8000/v1`
   - **API Key:** (leave blank — local server needs none)
3. Save. Open WebUI will discover all models/profiles from oMLX's `/v1/models`.
4. The model picker will show both `qwen3.8-27b-4bit:qwen3-8-27b-tool` and `qwen3.8-27b-4bit:qwen3-8-27b-thinking`.

> **SearXNG** also runs on unRAID. It is out of scope for this repo — configure it on the unRAID side.

---

## Headless SSH operations

See **[AGENTS.md](AGENTS.md)** for the complete SSH-ops playbook. Key points:

- **No GUI on the Mac Studio.** Admin UI is accessed via SSH tunnel: `ssh -L 8000:localhost:8000 <user>@<host>`, then open `http://localhost:8000/admin` on your local machine.
- **Service lifecycle:** `brew services {start,stop,restart,info} omlx`
- **Logs:** `~/.omlx/logs/server.log` + `$(brew --prefix)/var/log/omlx.log`
- **No Docker, no Colima, no LaunchAgent plists.** oMLX is the only service.

---

## Maintenance

```bash
./scripts/status.sh              # Health check
./scripts/update.sh              # Update everything (oMLX + re-download model)
./scripts/update.sh --omlx       # Update oMLX via Homebrew only
./scripts/update.sh --models     # Re-download primary model only
./scripts/uninstall.sh           # Tear down old stack (preserves models by default)
```

---

## Logs

| Source | Location |
|---|---|
| oMLX application log | `~/.omlx/logs/server.log` |
| oMLX brew service log (stdout/stderr) | `$(brew --prefix)/var/log/omlx.log` |

Tail over SSH:

```bash
ssh <user>@<MAC_STUDIO_IP> 'tail -f ~/.omlx/logs/server.log'
```

---

## Troubleshooting

### oMLX service won't start

```bash
brew services info omlx
tail -50 ~/.omlx/logs/server.log
tail -50 "$(brew --prefix)/var/log/omlx.log"
```

Common causes: model directory not found, port 8000 already in use, insufficient RAM.

### Port 8000 conflict

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
```

Stop the conflicting process, then `brew services restart omlx`.

### Hermes (remote host) cannot reach oMLX

```bash
# On the Hermes host:
curl -s http://<MAC_STUDIO_IP>:8000/v1/models
```

If this hangs or is refused but `curl http://localhost:8000/v1/models` works on the Mac Studio, the macOS Application Firewall is blocking inbound LAN traffic. Refresh the allowlist:

```bash
OMLX_PID=$(pgrep -f "omlx serve" | head -1)
OMLX_BIN=$(ps -p "$OMLX_PID" -o comm=)
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN"
```

The oMLX settings bind `--host 0.0.0.0`, so no change to the config is needed — only the OS firewall. Re-run this after every `brew upgrade omlx` (the interpreter path changes). `update.sh --omlx` does this automatically.

### Model not found in admin panel

oMLX auto-discovers models from subdirectories of `--model-dir`. Verify:

```bash
ls -la /opt/models/
# Each subdirectory should contain an MLX model (config.json, model.safetensors, etc.)
```

If a model is missing from the admin panel, it may not be in MLX format or the directory may be empty. Re-download:

```bash
hf download <repo-id> --local-dir /opt/models/<name>
```

Then restart: `brew services restart omlx`.

### RAM pressure / swap on 32GB

The 27B model at 4-bit (~16.9GB weights) plus KV cache plus macOS overhead sits near the 32GB ceiling under concurrent HA + Hermes load. Mitigations:

- In the oMLX admin panel, set a memory guard: `--memory-guard safe` or `--memory-guard-gb 24`
- Enable SSD KV cache: `--paged-ssd-cache-dir ~/.omlx/cache` (offloads cold KV blocks to disk)
- Reduce max concurrent requests: `--max-concurrent-requests 4` (default is 8)
- Drop to a smaller model if sustained swap is observed

### oMLX `--host` flag not recognized

If `omlx serve --host 0.0.0.0` errors with an unknown-flag message, check `omlx serve --help` for the current flag name. You can also set it via environment variable: `OMLX_HOST=0.0.0.0 brew services start omlx`, or edit `~/.omlx/settings.json` directly.

---

## Migrating from the old stack

If you're upgrading from the previous multi-service architecture (mlx_lm.server + Colima + Open WebUI + SearXNG on the Mac Studio):

```bash
# 1. Tear down the old stack (preserves /opt/models):
./scripts/uninstall.sh

# 2. Install the new headless oMLX stack:
./scripts/install.sh

# 3. Move Open WebUI and SearXNG to unRAID (out of scope for this repo).
#    Point unRAID's Open WebUI at http://<MAC_STUDIO_IP>:8000/v1
```

---

## Repository Structure

```
omlx-headless/
├── README.md
├── AGENTS.md           # SSH-ops playbook for AI agents and humans
└── scripts/
    ├── install.sh      # One-shot setup: oMLX + model download + firewall
    ├── uninstall.sh    # Idempotent teardown of old + new stack
    ├── status.sh       # Health check
    └── update.sh       # Update oMLX and/or re-download models
```