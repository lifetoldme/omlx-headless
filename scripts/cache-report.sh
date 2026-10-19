#!/usr/bin/env bash
# =============================================================
# cache-report.sh
# Show oMLX KV/prefix-cache effectiveness from the usage database.
#
# Runs from any host that can SSH to the Mac Studio. The report uses
# the prefill/cached counters oMLX records in ~/.omlx/usage.sqlite3,
# so it reflects server-side cache reuse rather than client-reported
# token counts.
#
# Usage:
#   ./scripts/cache-report.sh [host] [days]
#
# Defaults: host=local-llm, days=30. The database starts at the
# oMLX 0.7.0 upgrade (2026-10-09); earlier rows do not exist.
# =============================================================

set -euo pipefail

HOST="${1:-${CACHE_REPORT_HOST:-local-llm}}"
DAYS="${2:-30}"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
    echo "days must be a positive integer" >&2
    exit 1
fi

read -r -d '' SQL <<'SQL' || true
.mode column
.headers on
SELECT
    date(timestamp_hour, 'unixepoch', 'localtime') AS day,
    SUM(requests) AS reqs,
    SUM(prompt_tokens) AS prompt,
    SUM(cached_tokens) AS cached,
    ROUND(100.0 * SUM(cached_tokens) / NULLIF(SUM(prompt_tokens), 0), 1) AS cache_pct,
    ROUND(SUM(prefill_seconds), 1) AS prefill_s,
    ROUND(SUM(generation_seconds), 1) AS gen_s,
    ROUND(SUM(request_seconds), 1) AS wall_s,
    ROUND(
        (SUM(prompt_tokens) + SUM(completion_tokens)) / NULLIF(SUM(request_seconds), 0),
        1
    ) AS eff_tps
FROM model_usage_hourly
WHERE model_id NOT IN ('bge-m3', 'qwen3-reranker')
  AND timestamp_hour >= strftime('%s', 'now', '-__DAYS__ days')
GROUP BY day
ORDER BY day DESC;

SELECT
    datetime(timestamp_hour, 'unixepoch', 'localtime') AS hour,
    substr(model_id, 1, 34) AS model,
    requests AS req,
    prompt_tokens AS prompt,
    cached_tokens AS cached,
    ROUND(100.0 * cached_tokens / NULLIF(prompt_tokens, 0), 1) AS cache_pct,
    ROUND(prefill_seconds, 1) AS prefill_s,
    ROUND(request_seconds, 1) AS wall_s,
    ROUND(
        (prompt_tokens + completion_tokens) / NULLIF(request_seconds, 0),
        1
    ) AS eff_tps
FROM model_usage_hourly
WHERE model_id NOT IN ('bge-m3', 'qwen3-reranker')
  AND timestamp_hour >= strftime('%s', 'now', '-__DAYS__ days')
  AND prompt_tokens >= 5000
  AND cached_tokens * 10 < prompt_tokens
ORDER BY prompt_tokens DESC
LIMIT 10;

SELECT
    substr(model_id, 1, 34) AS model,
    SUM(requests) AS reqs,
    SUM(prompt_tokens) AS prompt,
    SUM(cached_tokens) AS cached,
    ROUND(100.0 * SUM(cached_tokens) / NULLIF(SUM(prompt_tokens), 0), 1) AS cache_pct,
    ROUND(SUM(prefill_seconds), 1) AS prefill_s,
    ROUND(SUM(generation_seconds), 1) AS gen_s,
    ROUND(SUM(request_seconds), 1) AS wall_s
FROM model_usage_hourly
WHERE model_id NOT IN ('bge-m3', 'qwen3-reranker')
  AND timestamp_hour >= strftime('%s', 'now', '-__DAYS__ days')
GROUP BY model_id
ORDER BY prompt DESC;
SQL

printf '%s\n' "${SQL//__DAYS__/$DAYS}" |
    ssh "$HOST" 'sqlite3 -header -column ~/.omlx/usage.sqlite3'
