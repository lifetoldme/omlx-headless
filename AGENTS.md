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
- ❌ Delete `/opt/models/qwen3.6-27b-heretic2-uncensored` (uncensored rollback option)
- ❌ Run `brew upgrade omlx` without then re-allowlisting the new interpreter in the firewall (unless the Application Firewall is disabled — check `socketfilterfw --getglobalstate`)
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
| `/opt/models/qwen3.8-27b-uncensored-oq4e-fp16-mtp` | `pyros-vault/Qwen3.8-27B-Uncensored-oQ4e-fp16-mtp` | **Primary** (VLM, oQ4e 4-bit + FP16 MTP head, ~17GB, uncensored, Lightning VLM-MTP enabled) |
| `/opt/models/qwen3.8-27b-4bit` | `mlx-community/Qwen3.8-27B-4bit` | Rollback (VLM, 4-bit, ~16.9GB, censored base) |
| `/opt/models/bge-m3` | `BAAI/bge-m3` | Embeddings (HA / RAG) |
| `/opt/models/qwen3-reranker` | `Qwen/Qwen3-Reranker` | Reranking |

The Qwen3.6 fallbacks (`qwen3.6-27b-optiq`, `qwen3.6-27b-heretic2-uncensored`) are no longer on disk as of 2026-08-22. If a Hermes tool-call regression appears on the uncensored primary, either download `mlx-community/Qwen3.6-27B-OptiQ-4bit` fresh or unpin back to `qwen3.8-27b-4bit`.

Qwen3.8 requires oMLX >= 0.6.0rc1 (Qwen3.5-family compatibility path); the box runs **0.6.4** since 2026-09-11. Keep oMLX current via `scripts/update.sh --omlx`.

Note: `mtp_enabled` and `vlm_mtp_enabled` are mutually exclusive in `model_settings.json` — oMLX rejects the settings entry if both are true. For the VLM primary, only `vlm_mtp_enabled: true` is set.

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

Headless alternative: stop the service, flip `is_pinned` in `~/.omlx/model_settings.json`, start.

### Do NOT delete the rollback

The censored rollback at `/opt/models/qwen3.8-27b-4bit` is the safety net in case the uncensored primary underperforms on Hermes tool-call loops. Keep it on disk even when not pinned.

---

## Profile management

Profiles are configured via the admin UI (SSH-tunneled). They expose one loaded model as multiple model IDs on `/v1/models` at zero extra RAM cost.

For headless management (no tunnel), the same state lives in JSON:

| File | Contents |
|---|---|
| `~/.omlx/model_settings.json` | Per-model settings incl. `is_pinned`, `is_default` |
| `~/.omlx/model_profiles.json` | Profiles incl. `display_name`, `api_name`, `expose_as_model` |

Edit while the service is stopped (`brew services stop omlx`), then start. Profile `api_name` is what appears after `:` in the exposed model ID (`<model-id>:<api_name>`).

### Current profiles

| Profile name | Thinking | Use case |
|---|---|---|
| `qwen3.8-27b-uncensored-oq4e-fp16-mtp:qwen3-8-27b-tool` | OFF | Hermes Agent tool-call (clean XML, no thinking block) |
| `qwen3.8-27b-uncensored-oq4e-fp16-mtp:qwen3-8-27b-thinking` | ON | Home Assistant / Open WebUI general chat |

### Why

Hermes tool-call needs thinking OFF — a `<think>` block can consume the token budget before a tool call is emitted. General chat benefits from thinking ON. Profiles let one loaded model serve both use cases.

---

## Firewall

The macOS Application Firewall blocks incoming connections by default. `install.sh` and `update.sh --omlx` automatically add the oMLX listener binary to the allowlist when the firewall is enabled.

**Current state on this box: Application Firewall is DISABLED** (`socketfilterfw --getglobalstate` → "Firewall is disabled"). No rule refresh is needed after upgrades while it stays disabled; `update.sh` checks this automatically.

If it is ever re-enabled, after every `brew upgrade omlx` the Python interpreter path changes, so the old firewall rule no longer applies. Re-allowlist:

```bash
OMLX_PID=$(pgrep -f "omlx serve" | head -1)
OMLX_BIN=$(ps -p "$OMLX_PID" -o comm=)
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$OMLX_BIN"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$OMLX_BIN"
```

`update.sh --omlx` does this automatically. If you upgrade omlx manually, run the above or `./scripts/update.sh --omlx`.

---

## Wired memory limit (iogpu.wired_limit_mb)

Apple Silicon caps how much unified memory Metal can wire. oMLX's process memory enforcer computes its ceiling as `min(static, dynamic, metal_cap)` where `metal_cap` comes from this sysctl. **Two knobs must both be raised** — the kernel sysctl alone does nothing because oMLX's static ceiling (tier-dependent) still caps at 28GB (aggressive tier = 87.5% of 32GB).

**Current state (raised to 30GB on 2026-08-22):**

- Kernel: `iogpu.wired_limit_mb = 30720` — set at runtime via `sudo sysctl -w iogpu.wired_limit_mb=30720`
- Persistence: root LaunchDaemon `/Library/LaunchDaemons/com.beaty.wired-limit.plist` runs that sysctl at boot (nvram boot-args route is SIP-blocked)
- oMLX: `~/.omlx/settings.json` → `memory_guard_tier: "custom"`, `memory_guard_custom_ceiling_gb: 30.0` (live-applied via `POST /admin/api/global-settings`, no restart needed)

**To change the limit:**

1. `sudo sysctl -w iogpu.wired_limit_mb=<MB>` (immediate)
2. Update the value in the LaunchDaemon plist, then `sudo launchctl unload /Library/LaunchDaemons/com.beaty.wired-limit.plist && sudo launchctl load -w /Library/LaunchDaemons/com.beaty.wired-limit.plist`
3. Match it in oMLX: set `memory_guard_tier: "custom"` + `memory_guard_custom_ceiling_gb` (or via admin UI Memory Guard settings)

**Rollback if the box destabilizes** (30GB = 93.75% of 32GB, ~2GB left for macOS):

```bash
sudo sysctl -w iogpu.wired_limit_mb=28672   # revert plist value too
# and in oMLX: memory_guard_tier: "aggressive" (ceiling drops back to 28GB)
```

Verify: `sysctl iogpu.wired_limit_mb` and the enforcer startup line in `~/.omlx/logs/server.log` (`ceiling=…`).

---

## Prefill memory guard: chunked prefill + context ceiling (2026-09-11)

`0.6.0rc1 → 0.6.4` upgrade plus `~/.omlx/settings.json` →
`scheduler.chunked_prefill: true` (service stopped for the edit, then started).

**Observed behavior (32GB, 27B primary):**

- Requests are admitted and the scheduler throttles the chunked prefill instead
  of rejecting at admission: log lines `adaptive_prefill_throttle` →
  `Reclaimed N GB of pooled Metal buffers` → optional `Evicting idle model
  'bge-m3'` → continue. Hard 400 (`prefill_memory_exceeded`) only when even a
  minimum chunk cannot fit.
- A 19.5K-token prompt (the size class that failed 2026-09-09) now completes.
- Measured single-prompt boundary: **49,152 tokens verified**; 65,536 failed
  mid-prefill at 56,288 tokens (26.88GB + 1.66GB transient vs the 28.5GB safety
  cap). Practical single-prompt ceiling ≈ **50K tokens**.
- No throughput regression vs 0.6.0rc1 (PP 114.9/111.6, TG 17.2/16.1 tok/s at
  8K/16K); peak system memory slightly lower.
- Guard failures can be state-dependent: a 32K bench test failed at 28,672
  tokens right after 8K+16K runs, while a fresh engine admitted ~56K.

**Admin context benchmark gotcha:** `POST /admin/api/bench/context/start` with
`target_tokens` *applies* the verified boundary to the model's
`max_context_window` when it completes. Revert (live, no restart):

```bash
curl -X PUT http://127.0.0.1:8000/admin/api/models/<model-id>/settings \
  -H 'Content-Type: application/json' -d '{"max_context_window": 65536}'
```

Hermes requires ≥64K advertised, so never leave it below 65536.

**Rollback assets (2026-09-11):**

- Configs: `~/.omlx/{model_settings,model_profiles,settings}.json.bak-upgrade-20260911-145625`
- oMLX 0.6.0rc1 wheel: `/tmp/omlx-0.6.0rc1-cp311.whl` (sha256 `632fe4df…`, matches the v0.6.0rc1 release asset)

**Next lever if ~50K is insufficient:** enable TurboQuant KV
(`turboquant_kv_enabled: true`, 4-bit, `skip_last: true`) — cuts KV ~75% —
or swap to the non-fp16 oQ4e variant (~0.9GB smaller).

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
| Repo | `~/Developer/omlx-headless/` (or wherever cloned) |
| Scripts | `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/status.sh`, `scripts/update.sh` |