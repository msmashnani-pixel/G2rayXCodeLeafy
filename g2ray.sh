#!/bin/bash

set -euo pipefail

readonly G2RAY_ID="G2ray Panel v1.4.3"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_project_repo_default() {
    local remote url slug upstream_ref upstream_remote
    upstream_ref=$(git -C "$BASE_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    upstream_remote="${upstream_ref%%/*}"
    for remote in "$upstream_remote" origin shaun upstream; do
        [[ -n "$remote" && "$remote" != "$upstream_ref" ]] || continue
        url=$(git -C "$BASE_DIR" remote get-url "$remote" 2>/dev/null || true)
        [[ -n "$url" ]] || continue
        slug=$(printf '%s' "$url" \
            | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')
        if [[ "$slug" =~ ^[^/]+/[^/]+$ ]]; then
            printf '%s\n' "$slug"
            return 0
        fi
    done
    printf 'shaunme32/G2rayXCodeLeafy\n'
}

PROJECT_REPO="${G2RAY_PROJECT_REPO:-$(detect_project_repo_default)}"
RAW_BASE_URL="${G2RAY_RAW_BASE_URL:-https://raw.githubusercontent.com/${PROJECT_REPO}/main}"

G2RAY_BENCH_PREINIT_TMP="${G2RAY_BENCH_PREINIT_TMP:-}"
case "${1:-}" in
    --bench|bench)
        if [[ "${2:-}" == "--mock" || "${3:-}" == "--mock" || "${G2RAY_BENCH_MOCK:-0}" == "1" ]]; then
            umask 077
            if ! G2RAY_BENCH_PREINIT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/g2ray-bench.XXXXXX"); then
                echo "Could not create temporary benchmark runtime directory." >&2
                exit 1
            fi
            G2RAY_DATA_DIR="$G2RAY_BENCH_PREINIT_TMP/data"
            G2RAY_LOG_DIR="$G2RAY_BENCH_PREINIT_TMP/logs"
        fi
        ;;
esac

GREEN='\033[1;32m'; WHITE='\033[1;37m'; RED='\033[1;31m'
YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'; B='\033[1m'

DATA_DIR="${G2RAY_DATA_DIR:-$BASE_DIR/data}"
CONFIG_FILE="$DATA_DIR/config.json"
UUID_FILE="$DATA_DIR/uuid.txt"
BG_TASKS_PID="$DATA_DIR/bg_tasks.pid"
BG_TASKS_VERSION_FILE="$DATA_DIR/bg_tasks.version"
BG_TASKS_LOCK_DIR="$DATA_DIR/bg_tasks.lock"
RUNTIME_LOCK_DIR="$DATA_DIR/runtime.lock"
BG_TASKS_TOKEN_FILE="$DATA_DIR/bg_tasks.token"
BG_TASKS_HEARTBEAT_FILE="$DATA_DIR/bg_tasks.heartbeat"
RESUME_GAP_FILE="$DATA_DIR/resume_gap.txt"
WAKER_METADATA_FILE="$DATA_DIR/waker_metadata.txt"
WAKER_PROMPT_FILE="$DATA_DIR/.waker_setup_prompted"
REMOTE_MESSAGE_FILE="$DATA_DIR/message.txt"
ROUTE_BAD_COUNT_FILE="$DATA_DIR/xhttp_route_bad_count"
EDGE_BAD_COUNT_FILE="$DATA_DIR/edge_bad_count"
EDGE_RECONNECT_STAMP_FILE="$DATA_DIR/edge_reconnect_last"
ROUTE_HEALTH_FILE="$DATA_DIR/route_candidate_health.tsv"
ROUTE_STATS_FILE="$DATA_DIR/route_candidate_stats.tsv"
ROUTE_COOLDOWN_FILE="$DATA_DIR/route_candidate_cooldowns.tsv"
DNS_CANDIDATE_CACHE_FILE="$DATA_DIR/dns_candidate_cache.tsv"
BOOT_STATUS_FILE="$DATA_DIR/boot_status.json"
XHTTP_PATH_CACHE_FILE="$DATA_DIR/xhttp_path_cache"
LOW_OVERHEAD_FILE="$DATA_DIR/low_overhead_mode"
LOW_OVERHEAD_DISABLED_FILE="$DATA_DIR/low_overhead_mode_disabled"
LATENCY_FOCUS_FILE="$DATA_DIR/latency_focus_mode"
LATENCY_FOCUS_DISABLED_FILE="$DATA_DIR/latency_focus_mode_disabled"
LAST_GOOD_ROUTE_FILE="$DATA_DIR/last_good_route.txt"
PINNED_ROUTE_FILE="$DATA_DIR/pinned_route.txt"
MANUAL_ROUTE_CANDIDATES_FILE="$DATA_DIR/manual_route_candidates.txt"
BLACKLISTED_ROUTE_CANDIDATES_FILE="$DATA_DIR/blacklisted_route_candidates.txt"
ROUTE_SETTLING_HISTORY_FILE="$DATA_DIR/route_settling_history.tsv"
PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
QUOTA_CYCLE_FILE="$DATA_DIR/quota_cycle.txt"
XRAY_PID_FILE="$DATA_DIR/xray.pid"
SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
SESSION_START_FILE="$DATA_DIR/session_start.txt"
LOG_DIR="${G2RAY_LOG_DIR:-$BASE_DIR/logs}"
LOG_FILE="$LOG_DIR/g2ray.log"
STRUCTURED_LOG_FILE="$LOG_DIR/g2ray-events.jsonl"
DIAGNOSTIC_LOG_FILE="$LOG_DIR/g2ray-diagnostics.log"
QR_DIR="$DATA_DIR/qr"
MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
CODESPACE_ENV_JSON_FILE="${G2RAY_CODESPACE_ENV_JSON_FILE:-/workspaces/.codespaces/shared/environment-variables.json}"
CODESPACE_SHARED_ENV_FILE="${G2RAY_CODESPACE_SHARED_ENV_FILE:-/workspaces/.codespaces/shared/.env}"
XRAY_BIN="/usr/local/bin/xray"
XRAY_PORT="${XRAY_PORT:-443}"
[[ "$XRAY_PORT" =~ ^[0-9]+$ && "$XRAY_PORT" -gt 0 && "$XRAY_PORT" -le 65535 ]] || XRAY_PORT=443
CODESPACES_EDGE_PORT="${G2RAY_CODESPACES_EDGE_PORT:-443}"
DEFAULT_FALLBACK_IPS="${G2RAY_DEFAULT_FALLBACK_IPS:-20.69.79.91 20.85.77.48 20.120.56.11 20.125.70.28 20.90.66.7 20.103.221.187 20.207.70.99}"
MAX_FALLBACK_LINKS="${G2RAY_MAX_FALLBACK_LINKS:-20}"
ROUTE_MONITOR_MAX_CANDIDATES="${G2RAY_ROUTE_MONITOR_MAX_CANDIDATES:-24}"
DIAGNOSTIC_MAX_FALLBACK_PROBES="${G2RAY_DIAGNOSTIC_MAX_FALLBACK_PROBES:-12}"
SELF_HEAL_EDGE_RECONNECT_THRESHOLD="${G2RAY_EDGE_RECONNECT_THRESHOLD:-3}"
SELF_HEAL_RECONNECT_COOLDOWN_SEC="${G2RAY_RECONNECT_COOLDOWN_SEC:-300}"
ROUTE_WAIT_SEC="${G2RAY_ROUTE_WAIT_SEC:-120}"
FORCE_RECONNECT_ROUTE_WAIT_SEC="${G2RAY_FORCE_RECONNECT_ROUTE_WAIT_SEC:-60}"
ROUTE_READY_STABLE_PROBES="${G2RAY_ROUTE_READY_STABLE_PROBES:-2}"
ROUTE_READY_STABLE_SLEEP_SEC="${G2RAY_ROUTE_READY_STABLE_SLEEP_SEC:-1}"
ROUTE_HEALTH_TTL_SEC="${G2RAY_ROUTE_HEALTH_TTL_SEC:-300}"
DNS_CACHE_TTL_SEC="${G2RAY_DNS_CACHE_TTL_SEC:-300}"
ROUTE_FAILURE_COOLDOWN_SEC="${G2RAY_ROUTE_FAILURE_COOLDOWN_SEC:-180}"
ROUTE_PROBE_CONCURRENCY="${G2RAY_ROUTE_PROBE_CONCURRENCY:-4}"
ROUTE_PROBE_JITTER_SEC="${G2RAY_ROUTE_PROBE_JITTER_SEC:-0}"
PORT_PUBLIC_TTL_SEC="${G2RAY_PORT_PUBLIC_TTL_SEC:-300}"
LAST_GOOD_ROUTE_MAX_AGE_SEC="${G2RAY_LAST_GOOD_ROUTE_MAX_AGE_SEC:-1800}"
WAKER_TEST_TIMEOUT_SEC="${G2RAY_WAKER_TEST_TIMEOUT_SEC:-180}"
RUNTIME_LOCK_WAIT_ATTEMPTS="${G2RAY_RUNTIME_LOCK_WAIT_ATTEMPTS:-900}"
PERFORMANCE_PROFILE="${G2RAY_PERFORMANCE_PROFILE:-balanced}"
LOG_MAX_BYTES="${G2RAY_LOG_MAX_BYTES:-1048576}"
LOG_ROTATE_KEEP="${G2RAY_LOG_ROTATE_KEEP:-3}"
[[ "$WAKER_TEST_TIMEOUT_SEC" =~ ^[0-9]+$ && "$WAKER_TEST_TIMEOUT_SEC" -ge 30 ]] || WAKER_TEST_TIMEOUT_SEC=180
[[ "$RUNTIME_LOCK_WAIT_ATTEMPTS" =~ ^[0-9]+$ && "$RUNTIME_LOCK_WAIT_ATTEMPTS" -ge 1 ]] || RUNTIME_LOCK_WAIT_ATTEMPTS=900
[[ "$ROUTE_READY_STABLE_PROBES" =~ ^[0-9]+$ && "$ROUTE_READY_STABLE_PROBES" -ge 1 ]] || ROUTE_READY_STABLE_PROBES=2
[[ "$ROUTE_READY_STABLE_SLEEP_SEC" =~ ^[0-9]+$ ]] || ROUTE_READY_STABLE_SLEEP_SEC=1
[[ "$DNS_CACHE_TTL_SEC" =~ ^[0-9]+$ ]] || DNS_CACHE_TTL_SEC=300
[[ "$ROUTE_PROBE_CONCURRENCY" =~ ^[0-9]+$ && "$ROUTE_PROBE_CONCURRENCY" -ge 1 ]] || ROUTE_PROBE_CONCURRENCY=4
(( ROUTE_PROBE_CONCURRENCY > 8 )) && ROUTE_PROBE_CONCURRENCY=8

umask 077
mkdir -p "$DATA_DIR" "$LOG_DIR" "$QR_DIR"
chmod 700 "$DATA_DIR" "$LOG_DIR" "$QR_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
touch "$STRUCTURED_LOG_FILE" 2>/dev/null || true
touch "$DIAGNOSTIC_LOG_FILE" 2>/dev/null || true
[[ -f "$SAVED_BYTES_FILE"   ]] || printf '{"down":0,"up":0}\n' > "$SAVED_BYTES_FILE"
[[ -f "$SESSION_BYTES_FILE" ]] || printf '{"down":0,"up":0}\n' > "$SESSION_BYTES_FILE"
[[ -f "$TOTAL_UPTIME_FILE"  ]] || printf '0\n'                 > "$TOTAL_UPTIME_FILE"
[[ -f "$SESSION_START_FILE" ]] || date +%s                     > "$SESSION_START_FILE"
chmod 600 "$LOG_FILE" "$STRUCTURED_LOG_FILE" "$DIAGNOSTIC_LOG_FILE" "$SAVED_BYTES_FILE" "$SESSION_BYTES_FILE" "$TOTAL_UPTIME_FILE" "$SESSION_START_FILE" 2>/dev/null || true

json_escape() {
    printf '%s' "${1:-}" \
        | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' \
        | tr -d '\r\n'
}

low_overhead_enabled() {
    [[ -s "$LOW_OVERHEAD_DISABLED_FILE" ]] && return 1
    [[ -s "$LOW_OVERHEAD_FILE" ]] && return 0
    [[ "${G2RAY_LOW_OVERHEAD:-0}" == "1" ]]
}

enable_low_overhead_mode() {
    rm -f "$LOW_OVERHEAD_DISABLED_FILE" 2>/dev/null || true
    printf 'enabled\n' > "$LOW_OVERHEAD_FILE"
    chmod 600 "$LOW_OVERHEAD_FILE" 2>/dev/null || true
}

disable_low_overhead_mode() {
    rm -f "$LOW_OVERHEAD_FILE" 2>/dev/null || true
    printf 'disabled\n' > "$LOW_OVERHEAD_DISABLED_FILE"
    chmod 600 "$LOW_OVERHEAD_DISABLED_FILE" 2>/dev/null || true
}

toggle_low_overhead_mode() {
    if low_overhead_enabled; then
        disable_low_overhead_mode
        return 1
    fi
    enable_low_overhead_mode
    return 0
}

low_overhead_summary() {
    if low_overhead_enabled; then
        printf 'Enabled - background route refresh and INFO log chatter are reduced\n'
    else
        printf 'Disabled - full monitoring and INFO logs are enabled\n'
    fi
}

latency_focus_enabled() {
    [[ -s "$LATENCY_FOCUS_DISABLED_FILE" ]] && return 1
    [[ -s "$LATENCY_FOCUS_FILE" ]] && return 0
    [[ "${G2RAY_LATENCY_FOCUS:-0}" == "1" ]]
}

enable_latency_focus_mode() {
    rm -f "$LATENCY_FOCUS_DISABLED_FILE" 2>/dev/null || true
    printf 'enabled\n' > "$LATENCY_FOCUS_FILE"
    chmod 600 "$LATENCY_FOCUS_FILE" 2>/dev/null || true
}

disable_latency_focus_mode() {
    rm -f "$LATENCY_FOCUS_FILE" 2>/dev/null || true
    printf 'disabled\n' > "$LATENCY_FOCUS_DISABLED_FILE"
    chmod 600 "$LATENCY_FOCUS_DISABLED_FILE" 2>/dev/null || true
}

toggle_latency_focus_mode() {
    if latency_focus_enabled; then
        disable_latency_focus_mode
        return 1
    fi
    enable_latency_focus_mode
    return 0
}

latency_focus_summary() {
    if latency_focus_enabled; then
        printf 'Enabled - keeps heartbeat/self-heal, suppresses noncritical logs, and minimizes background refreshes\n'
    else
        printf 'Disabled - normal diagnostics, route refresh, and exports are enabled\n'
    fi
}

log_structured_event() {
    local ts="$1" level="$2" msg="$3" event
    event=$(printf '%s' "$msg" | awk '{print $1; exit}' | tr -cd 'A-Za-z0-9_.:-')
    [[ -n "$event" ]] || event="event"
    rotate_log_file "$STRUCTURED_LOG_FILE"
    printf '{"ts":"%s","level":"%s","event":"%s","message":"%s"}\n' \
        "$(json_escape "$ts")" "$(json_escape "$level")" "$(json_escape "$event")" "$(json_escape "$msg")" \
        >> "$STRUCTURED_LOG_FILE" 2>/dev/null || true
}

quiet_info_event_important() {
    case "${1:-}" in
        runtime_ready*|boot_status*|background\ supervisor_started*|self_heal\ restart_ok*|recover_now*|support_bundle*)
            return 0
            ;;
    esac
    return 1
}

log_event() {
    local level="$1"; shift || true
    local ts msg
    if latency_focus_enabled && [[ "$level" != "ERROR" ]]; then
        return 0
    fi
    msg="$*"
    if low_overhead_enabled && [[ "$level" == "INFO" ]] && ! quiet_info_event_important "$msg"; then
        return 0
    fi
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    rotate_log_file "$LOG_FILE"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    log_structured_event "$ts" "$level" "$msg"
}

write_boot_status() {
    local status="${1:-unknown}" reason="${2:-unknown}" message="${3:-}" code="${4:-0}" ms="${5:-0}" ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    cat > "$BOOT_STATUS_FILE" <<JSON
{
  "ts": "$(json_escape "$ts")",
  "status": "$(json_escape "$status")",
  "reason": "$(json_escape "$reason")",
  "message": "$(json_escape "$message")",
  "route_http_status": ${code:-0},
  "route_latency_ms": ${ms:-0}
}
JSON
    chmod 600 "$BOOT_STATUS_FILE" 2>/dev/null || true
    log_event INFO "boot_status status=${status} reason=${reason} route_http=${code:-0} route_ms=${ms:-0}"
}

boot_status_summary() {
    if [[ ! -s "$BOOT_STATUS_FILE" ]]; then
        printf 'Boot status : none recorded\n'
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -r '"Boot status : \(.status) reason=\(.reason) route=HTTP \(.route_http_status) \(.route_latency_ms)ms at \(.ts)\nMessage     : \(.message)"' "$BOOT_STATUS_FILE" 2>/dev/null && return 0
    fi
    awk -F '"' '
        /"ts"/ {ts=$4}
        /"status"/ {status=$4}
        /"reason"/ {reason=$4}
        /"message"/ {message=$4}
        /"route_http_status"/ {gsub(/[^0-9]/, "", $0); code=$0}
        /"route_latency_ms"/ {gsub(/[^0-9]/, "", $0); ms=$0}
        END {
            printf "Boot status : %s reason=%s route=HTTP %s %sms at %s\n",
                (status ? status : "unknown"), (reason ? reason : "unknown"),
                (code ? code : "0"), (ms ? ms : "0"), (ts ? ts : "unknown")
            if (message) printf "Message     : %s\n", message
        }
    ' "$BOOT_STATUS_FILE" 2>/dev/null
}

rotate_log_file() {
    local file="$1" max="$LOG_MAX_BYTES" keep="$LOG_ROTATE_KEEP" size i prev next
    [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=1048576
    [[ "$keep" =~ ^[0-9]+$ && "$keep" -gt 0 ]] || keep=3
    [[ -f "$file" ]] || return 0
    size=$(wc -c < "$file" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    (( size < max )) && return 0
    rm -f "${file}.${keep}" 2>/dev/null || true
    for ((i=keep-1; i>=1; i--)); do
        prev="${file}.${i}"
        next="${file}.$((i + 1))"
        [[ -f "$prev" ]] && mv -f "$prev" "$next" 2>/dev/null || true
    done
    mv -f "$file" "${file}.1" 2>/dev/null || true
    : > "$file" 2>/dev/null || true
    chmod 600 "$file" 2>/dev/null || true
}

codespace_shared_github_token() {
    local n key="GITHUB_TOKEN"
    [[ -r "$CODESPACE_SHARED_ENV_FILE" ]] || return 1
    n=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$CODESPACE_SHARED_ENV_FILE" 2>/dev/null)
    n="${n%\"}"; n="${n#\"}"
    n="${n%\'}"; n="${n#\'}"
    [[ -n "$n" ]] || return 1
    printf '%s' "$n"
}

run_gh() {
    command -v gh >/dev/null 2>&1 || return 127
    local token_env=() shared_token=""
    if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
        shared_token=$(codespace_shared_github_token 2>/dev/null || true)
        [[ -n "$shared_token" ]] && token_env=(GH_TOKEN="$shared_token")
    fi
    if command -v timeout >/dev/null 2>&1; then
        env "${token_env[@]}" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 \
            timeout "${G2RAY_GH_TIMEOUT_SEC:-10}" gh "$@"
    else
        env "${token_env[@]}" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 gh "$@"
    fi
}

curl_http_code() {
    local url="$1" timeout_sec="${2:-5}" code
    if code=$(curl -s -m "$timeout_sec" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null); then
        if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
            printf '%s' "$code"
        else
            printf '0'
        fi
        return 0
    fi
    printf '0'
}

valid_codespace_name() {
    local name="${1:-}"
    [[ -n "$name" ]] && [[ "$name" != "null" ]]
}

fingerprint_secret() {
    local value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print substr($1,1,12)}'
    else
        printf '%s' "$value" | md5sum | awk '{print substr($1,1,12)}'
    fi
}

file_fingerprint() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$file" 2>/dev/null | awk '{print $1}'
    else
        cksum "$file" 2>/dev/null | awk '{print $1 ":" $2}'
    fi
}

detect_codespace_name_from_json_file() {
    local file="$1" n
    [[ -r "$file" ]] || return 1
    n=$(sed -nE 's/.*"CODESPACE_NAME"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$file" 2>/dev/null | head -n 1)
    [[ -n "$n" ]] || n=$(sed -nE 's/.*"codespace"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$file" 2>/dev/null | head -n 1)
    valid_codespace_name "$n" || return 1
    printf '%s' "$n"
}

detect_codespace_name_from_env_file() {
    local file="$1" n
    [[ -r "$file" ]] || return 1
    n=$(sed -nE 's/^CODESPACE_NAME=(.*)$/\1/p' "$file" 2>/dev/null | head -n 1)
    n="${n%\"}"; n="${n#\"}"
    n="${n%\'}"; n="${n#\'}"
    valid_codespace_name "$n" || return 1
    printf '%s' "$n"
}

detect_codespace_name_from_waker_metadata() {
    local n
    [[ -r "$WAKER_METADATA_FILE" ]] || return 1
    n=$(sed -nE 's/^codespace_name=(.+)$/\1/p' "$WAKER_METADATA_FILE" 2>/dev/null | head -n 1)
    valid_codespace_name "$n" || return 1
    printf '%s' "$n"
}

detect_codespace_name_from_port_stamp() {
    local stamp n
    for stamp in "$PORT_PUBLIC_STAMP_FILE".*."$XRAY_PORT"; do
        [[ -e "$stamp" ]] || continue
        n="${stamp#"$PORT_PUBLIC_STAMP_FILE".}"
        n="${n%."$XRAY_PORT"}"
        valid_codespace_name "$n" || continue
        printf '%s' "$n"
        return 0
    done
    return 1
}

_detect_codespace_name() {
    valid_codespace_name "${CODESPACE_NAME:-}" && { printf '%s' "$CODESPACE_NAME"; return; }
    local n
    n=$(detect_codespace_name_from_json_file "$CODESPACE_ENV_JSON_FILE" 2>/dev/null || true)
    valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    n=$(detect_codespace_name_from_env_file "$CODESPACE_SHARED_ENV_FILE" 2>/dev/null || true)
    valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    n=$(detect_codespace_name_from_waker_metadata 2>/dev/null || true)
    valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    n=$(detect_codespace_name_from_json_file "$CONFIG_META_FILE" 2>/dev/null || true)
    valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    n=$(detect_codespace_name_from_port_stamp 2>/dev/null || true)
    valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    if command -v gh >/dev/null 2>&1; then
        n=$(run_gh codespace list --limit 1 --json name --jq '.[0].name // ""' 2>/dev/null || true)
        valid_codespace_name "$n" && { printf '%s' "$n"; return; }
        sleep 2
        n=$(run_gh codespace list --limit 1 --json name --jq '.[0].name // ""' 2>/dev/null || true)
        valid_codespace_name "$n" && { printf '%s' "$n"; return; }
    fi
    local h; h=$(hostname 2>/dev/null || true)
    printf '%s' "${h:-unknown-codespace}"
}

CODESPACE_NAME=$(_detect_codespace_name)
PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

xray_pid_matches() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    ps -p "$p" -o args= 2>/dev/null | grep -Fq "$XRAY_BIN run -c $CONFIG_FILE"
}

xray_running() {
    local p
    if [[ -f "$XRAY_PID_FILE" ]]; then
        p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
        if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
            return 0
        fi
        rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    fi
    command -v pgrep >/dev/null 2>&1 || return 1
    p=$(pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" 2>/dev/null | head -1 || true)
    [[ -n "$p" ]]
}

owned_xray_pids() {
    local p
    p=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
    if xray_pid_matches "$p"; then
        printf '%s\n' "$p"
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" 2>/dev/null || true
    fi
}

json_dns_ips() {
    local url="$1" header="${2:-}"
    if [[ -n "$header" ]]; then
        (curl -sf -m 4 -H "$header" "$url" 2>/dev/null \
            | grep -oE '"data":"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' \
            | sed -E 's/^"data":"//;s/"$//') || true
    else
        (curl -sf -m 4 "$url" 2>/dev/null \
            | grep -oE '"data":"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' \
            | sed -E 's/^"data":"//;s/"$//') || true
    fi
}

curl_remote_ip() {
    local domain="$1" ip
    ip=$(curl -sk -m 5 -o /dev/null -w '%{remote_ip}' "https://${domain}/" 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$ ]] && printf '%s\n' "$ip"
}

dns_cache_ttl_sec() {
    [[ "${DNS_CACHE_TTL_SEC:-300}" =~ ^[0-9]+$ ]] && printf '%s' "$DNS_CACHE_TTL_SEC" || printf '300'
}

read_dns_candidate_cache() {
    local domain="${1:-}" ttl now
    [[ -n "$domain" && -s "$DNS_CANDIDATE_CACHE_FILE" ]] || return 1
    ttl=$(dns_cache_ttl_sec)
    (( ttl > 0 )) || return 1
    now=$(date +%s)
    awk -F '\t' -v domain="$domain" -v now="$now" -v ttl="$ttl" '
        $2 == domain && $1 ~ /^[0-9]+$/ && now >= $1 && now - $1 <= ttl && $3 != "" && $4 != "" {
            print $3 "\t" $4
            found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$DNS_CANDIDATE_CACHE_FILE" 2>/dev/null
}

write_dns_candidate_cache() {
    local domain="${1:-}" rows="${2:-}" ttl now tmp
    [[ -n "$domain" && -n "$rows" ]] || return 0
    ttl=$(dns_cache_ttl_sec)
    (( ttl > 0 )) || return 0
    mkdir -p "$(dirname "$DNS_CANDIDATE_CACHE_FILE")" 2>/dev/null || true
    now=$(date +%s)
    tmp=$(mktemp "${DNS_CANDIDATE_CACHE_FILE}.XXXXXX") || return 0
    if [[ -s "$DNS_CANDIDATE_CACHE_FILE" ]]; then
        awk -F '\t' -v domain="$domain" '$2 != domain {print}' "$DNS_CANDIDATE_CACHE_FILE" > "$tmp" 2>/dev/null || true
    fi
    printf '%s\n' "$rows" | while IFS=$'\t' read -r source ip; do
        valid_ipv4 "$ip" || continue
        printf '%s\t%s\t%s\t%s\n' "$now" "$domain" "${source:-unknown}" "$ip"
    done >> "$tmp"
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$DNS_CANDIDATE_CACHE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
        chmod 600 "$DNS_CANDIDATE_CACHE_FILE" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

resolve_dns_provider_ips_with_sources() {
    local domain="${1:-}" tmpdir pids=()
    [[ -n "$domain" ]] || return 0
    tmpdir=$(mktemp -d "${DATA_DIR}/dns-resolve.XXXXXX" 2>/dev/null || mktemp -d)
    if command -v dig >/dev/null 2>&1; then
        (dig +short "$domain" A 2>/dev/null | awk 'NF {print "dig\t" $0}' > "$tmpdir/dig") &
        pids+=("$!")
    fi
    (getent hosts "$domain" 2>/dev/null | awk '{print "getent\t" $1}' > "$tmpdir/getent") &
    pids+=("$!")
    ({ json_dns_ips "https://dns.google/resolve?name=${domain}&type=A" || true; } | awk 'NF {print "dns_google\t" $0}' > "$tmpdir/dns_google") &
    pids+=("$!")
    ({ json_dns_ips "https://cloudflare-dns.com/dns-query?name=${domain}&type=A" "accept: application/dns-json" || true; } | awk 'NF {print "dns_cloudflare\t" $0}' > "$tmpdir/dns_cloudflare") &
    pids+=("$!")
    ({ curl_remote_ip "$domain" || true; } | awk 'NF {print "remote_http\t" $0}' > "$tmpdir/remote_http") &
    pids+=("$!")
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    cat "$tmpdir"/* 2>/dev/null || true
    rm -rf "$tmpdir" 2>/dev/null || true
}

xhttp_config_path() {
    local cache_key cached_key cached_path path
    if [[ -f "$CONFIG_FILE" ]]; then
        cache_key=$(file_fingerprint "$CONFIG_FILE" 2>/dev/null || true)
        [[ -n "$cache_key" ]] || cache_key=$(stat -c '%Y:%s:%y' "$CONFIG_FILE" 2>/dev/null || printf '0')
        if [[ -s "$XHTTP_PATH_CACHE_FILE" ]]; then
            IFS=$'\t' read -r cached_key cached_path < "$XHTTP_PATH_CACHE_FILE" 2>/dev/null || true
            if [[ "$cached_key" == "$cache_key" && -n "${cached_path:-}" ]]; then
                printf '%s\n' "$cached_path"
                return 0
            fi
        fi
    fi
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        path=$(jq -r '.inbounds[]? | select(.tag=="vless-in") | .streamSettings.xhttpSettings.path // "/"' "$CONFIG_FILE" 2>/dev/null \
            | awk 'NF {print; exit}')
        [[ -n "$path" ]] || path="/"
        if [[ -n "${cache_key:-}" ]]; then
            printf '%s\t%s\n' "$cache_key" "$path" > "$XHTTP_PATH_CACHE_FILE" 2>/dev/null || true
            chmod 600 "$XHTTP_PATH_CACHE_FILE" 2>/dev/null || true
        fi
        printf '%s\n' "$path"
        return 0
    fi
    printf '/'
}

xhttp_probe_metrics() {
    local target="${1:-external}" address="${2:-}" path url raw code elapsed ms curl_rc=0 error_hint="" reason
    path=$(xhttp_config_path)
    [[ "$path" == /* ]] || path="/${path}"
    case "$target" in
        local) url="http://127.0.0.1:${XRAY_PORT}${path}" ;;
        *)     url="https://${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}${path}" ;;
    esac
    if [[ "$target" == "local" || -z "$address" ]]; then
        raw=$(curl -sk -m 5 -X OPTIONS -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || {
            curl_rc=$?
            raw="0 0"
        }
    else
        raw=$(curl -sk -m 5 --resolve "${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}:${address}" \
            -X OPTIONS -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null) || {
            curl_rc=$?
            raw="0 0"
        }
    fi
    code=${raw%% *}
    elapsed=${raw#* }
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
    [[ "$code" == "000" ]] && code=0
    [[ "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]] || elapsed=0
    ms=$(awk -v s="${elapsed:-0}" 'BEGIN{printf "%d", (s * 1000) + 0.5}')
    if [[ "$code" == "0" ]]; then
        case "$curl_rc" in
            28) error_hint="timeout" ;;
            6)  error_hint="dns" ;;
            7|52|56) error_hint="network" ;;
            35|51|58|60) error_hint="tls" ;;
            *)  error_hint="curl_${curl_rc}" ;;
        esac
    fi
    reason=$(route_failure_reason_for_status "$code" "$error_hint")
    printf '%s %s %s\n' "${code:-0}" "${ms:-0}" "$reason"
}

xhttp_probe_status() {
    local target="${1:-external}" address="${2:-}" code
    code=$(xhttp_probe_metrics "$target" "$address" | awk '{print $1}')
    printf '%s' "${code:-0}"
}

xhttp_status_usable() {
    local code="${1:-0}"
    [[ "$code" == "200" || "$code" == "400" ]]
}

panel_next_action_code() {
    local engine="${1:-false}" listener="${2:-false}" edge_code="${3:-0}" config_present="${4:-true}"
    if [[ "$config_present" != "true" ]]; then
        printf 'generate_config'
    elif xhttp_status_usable "$edge_code"; then
        printf 'retry_vless_config'
    elif [[ "$engine" != "true" ]]; then
        printf 'start_engine'
    elif [[ "$listener" != "true" ]]; then
        printf 'restart_engine'
    elif [[ "$edge_code" == "404" ]]; then
        printf 'wait_route_or_recover'
    elif [[ "$edge_code" == "0" || "$edge_code" == "000" ]]; then
        printf 'check_dns_or_ports'
    else
        printf 'open_diagnostics'
    fi
}

panel_next_action_text() {
    case "${1:-open_diagnostics}" in
        generate_config) printf 'Generate a config and start the engine.' ;;
        start_engine) printf 'Start the Xray engine, then check the route again.' ;;
        restart_engine) printf 'Restart the engine so the listener opens on the configured port.' ;;
        retry_vless_config) printf 'Try the same VLESS config again.' ;;
        wait_route_or_recover) printf 'Wait for the Codespaces route to settle, or run Recover Now if it stays stuck.' ;;
        check_dns_or_ports) printf 'Check DNS, GitHub port visibility, and the Codespaces Ports tab.' ;;
        *) printf 'Open diagnostics and inspect the support bundle logs.' ;;
    esac
}

increment_route_bad_count() {
    local count
    count=$(cat "$ROUTE_BAD_COUNT_FILE" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    printf '%s\n' "$count" > "$ROUTE_BAD_COUNT_FILE"
    printf '%s' "$count"
}

reset_route_bad_count() {
    rm -f "$ROUTE_BAD_COUNT_FILE" 2>/dev/null || true
}

increment_edge_bad_count() {
    local count
    count=$(cat "$EDGE_BAD_COUNT_FILE" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$((count + 1))
    printf '%s\n' "$count" > "$EDGE_BAD_COUNT_FILE"
    printf '%s' "$count"
}

reset_edge_bad_count() {
    rm -f "$EDGE_BAD_COUNT_FILE" 2>/dev/null || true
}

edge_reconnect_cooldown_active() {
    local now last cooldown="$SELF_HEAL_RECONNECT_COOLDOWN_SEC"
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    last=$(cat "$EDGE_RECONNECT_STAMP_FILE" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    now=$(date +%s)
    (( now - last < cooldown ))
}

mark_edge_reconnect_attempt() {
    date +%s > "$EDGE_RECONNECT_STAMP_FILE" 2>/dev/null || true
}

self_heal_state_summary() {
    local route_bad edge_bad now last cooldown remaining last_age threshold
    route_bad=$(cat "$ROUTE_BAD_COUNT_FILE" 2>/dev/null || echo 0)
    edge_bad=$(cat "$EDGE_BAD_COUNT_FILE" 2>/dev/null || echo 0)
    last=$(cat "$EDGE_RECONNECT_STAMP_FILE" 2>/dev/null || echo 0)
    [[ "$route_bad" =~ ^[0-9]+$ ]] || route_bad=0
    [[ "$edge_bad" =~ ^[0-9]+$ ]] || edge_bad=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    cooldown="$SELF_HEAL_RECONNECT_COOLDOWN_SEC"
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    threshold="$SELF_HEAL_EDGE_RECONNECT_THRESHOLD"
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
    now=$(date +%s)
    if (( last > 0 && now >= last )); then
        last_age="$((now - last))s"
        remaining=$((cooldown - (now - last)))
        (( remaining < 0 )) && remaining=0
    else
        last_age="never"
        remaining=0
    fi
    printf 'route_bad=%s edge_bad=%s threshold=%s cooldown_remaining=%ss last_reconnect_age=%s\n' \
        "$route_bad" "$edge_bad" "$threshold" "$remaining" "$last_age"
}

last_log_event_matching() {
    local pattern="$1" line
    [[ -s "$LOG_FILE" ]] || { printf 'none recorded'; return 0; }
    line=$(grep -E "$pattern" "$LOG_FILE" 2>/dev/null | tail -n 1 || true)
    if [[ -z "$line" ]]; then
        printf 'none recorded'
        return 0
    fi
    printf '%s' "$line" | sed -E 's/ \[(INFO|WARN|ERROR)\] / /'
}

last_known_state_summary() {
    local failure repair last_export
    failure=$(last_log_event_matching 'route_unusable|edge_unreachable|engine_not_ready|started_route_unusable|started_route_still_unusable|port_public_failed|launch_failed|timeout|failed')
    repair=$(last_log_event_matching 'route_repair public_ok|route_repair public_failed|force_reconnect verify_external|force_reconnect start_engine ok|restart_ok|started_route_ready|route_repaired|runtime_ready .*action=skip_reconnect')
    last_export=$(last_log_event_matching 'config_exports refreshed|fallback_route_unusable|fallback_route_filter')
    printf 'Last failure : %s\n' "$failure"
    printf 'Last repair  : %s\n' "$repair"
    printf 'Last export  : %s\n' "$last_export"
}

valid_ipv4() {
    local ip="${1:-}" IFS=. part count=0
    [[ -n "$ip" && "$ip" != *[!0-9.]* && "$ip" == *.*.*.* && "$ip" != *.*.*.*.* ]] || return 1
    for part in $ip; do
        [[ "$part" =~ ^[0-9]+$ ]] || return 1
        (( 10#$part >= 0 && 10#$part <= 255 )) || return 1
        count=$((count + 1))
    done
    (( count == 4 ))
}

route_file_contains() {
    local file="$1" ip="$2"
    [[ -f "$file" ]] || return 1
    grep -Fxq "$ip" "$file" 2>/dev/null
}

write_unique_route_file() {
    local file="$1" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk 'NF && !seen[$0]++ {print}' > "$tmp"
    if mv -f "$tmp" "$file"; then
        chmod 600 "$file" 2>/dev/null || true
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

append_unique_route() {
    local file="$1" ip="$2"
    valid_ipv4 "$ip" || return 1
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    route_file_contains "$file" "$ip" && return 1
    { [[ -f "$file" ]] && cat "$file"; printf '%s\n' "$ip"; } | write_unique_route_file "$file"
}

remove_route_from_file() {
    local file="$1" ip="$2" tmp
    route_file_contains "$file" "$ip" || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk -v ip="$ip" 'NF && $0 != ip && !seen[$0]++ {print}' "$file" > "$tmp"
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$file" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
        chmod 600 "$file" 2>/dev/null || true
    else
        rm -f "$tmp" "$file" 2>/dev/null || return 1
    fi
}

manual_route_candidates() {
    [[ -f "$MANUAL_ROUTE_CANDIDATES_FILE" ]] || return 0
    while IFS= read -r ip; do
        valid_ipv4 "$ip" && printf '%s\n' "$ip"
    done < "$MANUAL_ROUTE_CANDIDATES_FILE"
}

blacklisted_route_candidates() {
    [[ -f "$BLACKLISTED_ROUTE_CANDIDATES_FILE" ]] || return 0
    while IFS= read -r ip; do
        valid_ipv4 "$ip" && printf '%s\n' "$ip"
    done < "$BLACKLISTED_ROUTE_CANDIDATES_FILE"
}

cached_route_candidate_ips() {
    [[ -s "$ROUTE_HEALTH_FILE" ]] || return 0
    awk -F '\t' 'NF >= 2 {print $2}' "$ROUTE_HEALTH_FILE" 2>/dev/null \
        | while IFS= read -r ip; do
            valid_ipv4 "$ip" && printf '%s\n' "$ip"
        done
}

candidate_blacklisted() {
    local ip="${1:-}"
    valid_ipv4 "$ip" || return 1
    route_file_contains "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$ip"
}

add_manual_route_candidate() {
    local ip="${1:-}"
    valid_ipv4 "$ip" || return 1
    candidate_blacklisted "$ip" && return 1
    append_unique_route "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip" || return 1
    clear_route_candidate_cooldown "$ip"
    log_event INFO "route_candidate manual_added ip=${ip}"
    return 0
}

remove_manual_route_candidate() {
    local ip="${1:-}"
    valid_ipv4 "$ip" || return 1
    remove_route_from_file "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip" || return 1
    log_event INFO "route_candidate manual_removed ip=${ip}"
    return 0
}

pinned_route_value() {
    local ip
    ip=$(cat "$PINNED_ROUTE_FILE" 2>/dev/null | awk 'NF {print; exit}' || true)
    valid_ipv4 "$ip" || return 0
    candidate_blacklisted "$ip" && return 0
    printf '%s\n' "$ip"
}

pin_route_candidate() {
    local ip="${1:-}"
    valid_ipv4 "$ip" || return 1
    candidate_blacklisted "$ip" && return 1
    _atomic_write "$PINNED_ROUTE_FILE" "$ip" || return 1
    chmod 600 "$PINNED_ROUTE_FILE" 2>/dev/null || true
    clear_route_candidate_cooldown "$ip"
    log_event INFO "route_candidate pinned ip=${ip}"
    return 0
}

unpin_route_candidate() {
    rm -f "$PINNED_ROUTE_FILE" 2>/dev/null || return 1
    log_event INFO "route_candidate unpinned"
    return 0
}

blacklist_route_candidate() {
    local ip="${1:-}" pinned
    valid_ipv4 "$ip" || return 1
    pinned=$(cat "$PINNED_ROUTE_FILE" 2>/dev/null | awk 'NF {print; exit}' || true)
    append_unique_route "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$ip" || return 1
    if route_file_contains "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip"; then
        remove_route_from_file "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip" || return 1
    fi
    if [[ "$pinned" == "$ip" ]]; then
        rm -f "$PINNED_ROUTE_FILE" 2>/dev/null || return 1
    fi
    log_event WARN "route_candidate blacklisted ip=${ip}"
    return 0
}

unblacklist_route_candidate() {
    local ip="${1:-}"
    valid_ipv4 "$ip" || return 1
    remove_route_from_file "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$ip" || return 1
    clear_route_candidate_cooldown "$ip"
    log_event INFO "route_candidate unblacklisted ip=${ip}"
    return 0
}

reset_route_candidate_state() {
    reset_route_candidate_cache
    rm -f "$PINNED_ROUTE_FILE" "$MANUAL_ROUTE_CANDIDATES_FILE" "$BLACKLISTED_ROUTE_CANDIDATES_FILE" 2>/dev/null || true
    log_event WARN "route_candidate state_reset"
}

reset_route_candidate_cache() {
    rm -f "$ROUTE_HEALTH_FILE" "$ROUTE_STATS_FILE" "$LAST_GOOD_ROUTE_FILE" "$ROUTE_COOLDOWN_FILE" "$DNS_CANDIDATE_CACHE_FILE" 2>/dev/null || true
    log_event INFO "route_candidate cache_reset"
}

route_candidate_state_summary() {
    local pinned
    pinned=$(pinned_route_value)
    printf 'Pinned route : %s\n' "${pinned:-none}"
    printf 'Manual routes:\n'
    if [[ -s "$MANUAL_ROUTE_CANDIDATES_FILE" ]]; then
        manual_route_candidates | sed 's/^/  /'
    else
        printf '  none\n'
    fi
    printf 'Blacklisted routes:\n'
    if [[ -s "$BLACKLISTED_ROUTE_CANDIDATES_FILE" ]]; then
        blacklisted_route_candidates | sed 's/^/  /'
    else
        printf '  none\n'
    fi
}

resolve_domain_ips_with_sources() {
    local domain="$1" candidates provider_rows
    if [[ -n "$domain" ]]; then
        provider_rows=$(read_dns_candidate_cache "$domain" 2>/dev/null || true)
        if [[ -z "$provider_rows" ]]; then
            provider_rows=$(resolve_dns_provider_ips_with_sources "$domain" || true)
            [[ -n "$provider_rows" ]] && write_dns_candidate_cache "$domain" "$provider_rows"
        fi
    fi
    candidates=$({
        pinned_route_value | awk 'NF {print "pinned\t" $0}'
        manual_route_candidates | awk 'NF {print "manual\t" $0}'
        cached_route_candidate_ips | awk 'NF {print "cache\t" $0}'
        if [[ -n "${G2RAY_EXTRA_FALLBACK_IPS:-}" ]]; then
            printf '%s\n' "$G2RAY_EXTRA_FALLBACK_IPS" | tr ',; ' '\n' | awk 'NF {print "extra\t" $0}'
        fi
        [[ -n "${provider_rows:-}" ]] && printf '%s\n' "$provider_rows"
        printf '%s\n' "$DEFAULT_FALLBACK_IPS" | tr ',; ' '\n' | awk 'NF {print "builtin\t" $0}'
    } | while IFS=$'\t' read -r source ip; do
        valid_ipv4 "$ip" || continue
        candidate_blacklisted "$ip" && continue
        printf '%s\t%s\n' "${source:-unknown}" "$ip"
    done | awk -F '\t' '!seen[$2]++ {print}')
    printf '%s\n' "$candidates"
}

resolve_domain_ips() {
    local domain="$1" candidates joined
    candidates=$(resolve_domain_ips_with_sources "$domain" | awk -F '\t' '{print $2}')
    if [[ -n "$candidates" ]]; then
        joined=$(printf '%s' "$candidates" | tr '\n' ',' | sed 's/,$//')
        log_event INFO "resolver domain=${domain} fallback_candidates=${joined}"
    else
        log_event WARN "resolver domain=${domain} no-ip-candidates"
    fi
    printf '%s\n' "$candidates"
}

resolve_domain_ip() {
    local domain="$1" ip=""
    ip=$(resolve_domain_ips "$domain" | head -1 || true)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return; }
    printf '%s' "$domain"
}

_atomic_write() {
    local file="$1" content="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$file"
}

first_nonempty_line() {
    awk 'NF {print; exit}' <<< "${1:-}"
}

one_line() {
    printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

generate_wake_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 2>/dev/null && return 0
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        printf '%s%s\n' "$(uuidgen | tr -d '-')" "$(uuidgen | tr -d '-')" \
            | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    if [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
        printf '\n'
        return 0
    fi
    printf '%s%s%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$RANDOM" "$RANDOM" \
        | fingerprint_secret
}

normalize_waker_url() {
    local url host port
    url=$(one_line "${1:-}")
    [[ -n "$url" ]] || return 1
    [[ "$url" != *[[:space:]]* ]] || return 1
    [[ "$url" == http://* ]] && return 1
    [[ "$url" == https://* ]] || url="https://${url}"
    if [[ "$url" =~ ^https://([A-Za-z0-9][A-Za-z0-9.-]*[.][A-Za-z0-9.-]+)(:[0-9]+)?(/wake)?/?$ ]]; then
        host="${BASH_REMATCH[1]:-}"
        port="${BASH_REMATCH[2]:-}"
        printf 'https://%s%s/wake' "$host" "$port"
        return 0
    fi
    return 1
}

waker_metadata_value() {
    local key="$1"
    [[ -f "$WAKER_METADATA_FILE" ]] || return 0
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' \
        "$WAKER_METADATA_FILE" 2>/dev/null || true
}

save_waker_metadata() {
    local worker_url="$1" wake_fingerprint="$2" codespace="${3:-$CODESPACE_NAME}" configured_at content
    worker_url=$(normalize_waker_url "$worker_url") || return 1
    wake_fingerprint=$(one_line "$wake_fingerprint")
    codespace=$(one_line "$codespace")
    configured_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    content=$(printf 'worker_url=%s\ncodespace_name=%s\nwake_secret_fingerprint=%s\nconfigured_at=%s\n' \
        "$worker_url" "$codespace" "$wake_fingerprint" "$configured_at")
    _atomic_write "$WAKER_METADATA_FILE" "$content"
    chmod 600 "$WAKER_METADATA_FILE" 2>/dev/null || true
    log_event INFO "waker_metadata saved worker_url_hash=$(fingerprint_secret "$worker_url") codespace=${codespace}"
}

waker_metadata_summary() {
    local worker_url codespace wake_fingerprint configured_at
    worker_url=$(waker_metadata_value worker_url)
    codespace=$(waker_metadata_value codespace_name)
    wake_fingerprint=$(waker_metadata_value wake_secret_fingerprint)
    configured_at=$(waker_metadata_value configured_at)
    if [[ -n "$worker_url" ]]; then
        echo -e "Status      : configured"
        echo -e "Worker URL  : ${WHITE}${worker_url}${NC}"
        echo -e "Codespace   : ${WHITE}${codespace:-$CODESPACE_NAME}${NC}"
        echo -e "Secret      : fingerprint=${wake_fingerprint:-unknown} ${DIM}(raw secret is not stored)${NC}"
        echo -e "Last setup  : ${DIM}${configured_at:-unknown}${NC}"
    else
        echo -e "Status      : not configured"
        echo -e "Next step   : open option 15"
    fi
}

test_cloudflare_waker() {
    local worker_url="${1:-}" wake_secret="${2:-}" response status ok reason codespace route_ready route_status route_latency next_action
    worker_url=$(normalize_waker_url "${worker_url:-$(waker_metadata_value worker_url)}" 2>/dev/null || true)
    if [[ -z "$worker_url" ]]; then
        echo -ne "  ${GREEN}Worker wake URL:${NC} "
        read -r worker_url || return 1
        worker_url=$(normalize_waker_url "$worker_url" 2>/dev/null || true)
    fi
    if [[ -z "$worker_url" ]]; then
        echo -e "  ${RED}Missing Worker URL.${NC}"
        return 1
    fi
    if [[ -z "$wake_secret" ]]; then
        echo -ne "  ${GREEN}Wake secret (hidden):${NC} "
        read -r -s wake_secret || { echo ""; return 1; }
        echo ""
    fi
    if [[ -z "$wake_secret" ]]; then
        echo -e "  ${RED}Missing wake secret.${NC}"
        return 1
    fi

    echo -e "  ${DIM}Calling Worker with Authorization: Bearer ...${NC}"
    response=$(curl -sS -m "$WAKER_TEST_TIMEOUT_SEC" -X POST -H "Authorization: Bearer ${wake_secret}" "$worker_url" 2>&1) || {
        echo -e "  ${RED}Worker call failed.${NC}"
        printf '%s\n' "$response" | sed 's/^/  /'
        return 1
    }

    if command -v jq >/dev/null 2>&1 && printf '%s' "$response" | jq . >/dev/null 2>&1; then
        ok=$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null)
        status=$(printf '%s' "$response" | jq -r '.status // empty' 2>/dev/null)
        reason=$(printf '%s' "$response" | jq -r '.reason // empty' 2>/dev/null)
        codespace=$(printf '%s' "$response" | jq -r '.codespace // .body.name // empty' 2>/dev/null)
        route_ready=$(printf '%s' "$response" | jq -r '.route_ready // empty' 2>/dev/null)
        route_status=$(printf '%s' "$response" | jq -r '.route_probe.http_status // empty' 2>/dev/null)
        route_latency=$(printf '%s' "$response" | jq -r '.route_probe.latency_ms // empty' 2>/dev/null)
        next_action=$(printf '%s' "$response" | jq -r '.next_action // empty' 2>/dev/null)
        echo -e "  Result    : ${WHITE}ok=${ok} status=${status:-unknown}${NC}"
        [[ -n "$codespace" ]] && echo -e "  Codespace : ${WHITE}${codespace}${NC}"
        [[ -n "$route_ready" ]] && echo -e "  Route     : ${WHITE}ready=${route_ready} http=${route_status:-unknown} latency=${route_latency:-unknown}ms${NC}"
        [[ -n "$reason" ]] && echo -e "  Reason    : ${YELLOW}${reason}${NC}"
        [[ -n "$next_action" ]] && echo -e "  Next      : ${WHITE}${next_action}${NC}"
    else
        printf '%s\n' "$response" | sed 's/^/  /'
    fi
}

show_waker_recovery_guide() {
    refresh_screen
    echo -e "\n  ${RED}Recovery Guide${NC}\n"
    echo -e "  If configs suddenly stop working because GitHub stopped the Codespace:"
    echo -e "  1. Open your Worker wake URL in a browser."
    echo -e "  2. Paste your wake secret."
    echo -e "  3. Click Start Codespace."
    echo -e "  4. If the Worker reports ${WHITE}route_ready: true${NC}, use the same v2rayN config again."
    echo -e "  5. If it reports ${WHITE}route_ready: false${NC} or HTTP 404, wait 1-2 minutes and retry."
    echo -e "  6. If it stays stuck, open the panel and use option ${WHITE}6) Recover Now${NC}.\n"
    echo -e "  This works only if the Codespace still exists and GitHub quota/token are valid."
    echo -e "  It cannot bypass quota, billing, deletion, or account restrictions.\n"
    echo -e "  ${WHITE}${B}Quota survival${NC}"
    echo -e "  If GitHub returns ${WHITE}HTTP 402${NC}, the Codespace is quota/billing blocked."
    echo -e "  The same configs can work after the monthly reset only if this same Codespace survives."
    echo -e "  Before quota runs out, open GitHub Codespaces, use the ${WHITE}...${NC} menu, and choose ${WHITE}Keep codespace${NC}.\n"
    echo -e "  ${WHITE}${B}Saved Waker${NC}"
    waker_metadata_summary | sed 's/^/  /'
    echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

setup_cloudflare_waker() {
    local wake_secret wake_fingerprint worker_url ready do_test
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    wake_secret=$(generate_wake_secret)
    wake_fingerprint=$(fingerprint_secret "$wake_secret")

    refresh_screen
    echo -e "\n  ${RED}Cloudflare Worker Waker Setup${NC}\n"
    echo -e "  ${WHITE}Detected Codespace:${NC} ${GREEN}${CODESPACE_NAME}${NC}"
    echo -e "  ${WHITE}Codespaces app domain:${NC} ${GREEN}${PORT_DOMAIN}${NC}\n"
    echo -e "  First, set GitHub Codespaces ${WHITE}Default idle timeout${NC} to ${WHITE}240 minutes${NC}:"
    echo -e "  GitHub -> Settings -> Codespaces -> Default idle timeout -> 240 minutes.\n"
    echo -e "  To survive monthly quota exhaustion, mark this Codespace as ${WHITE}Keep codespace${NC}:"
    echo -e "  GitHub -> Codespaces -> this Codespace -> ${WHITE}...${NC} menu -> ${WHITE}Keep codespace${NC}."
    echo -e "  Same configs survive next month only if this same Codespace is not deleted.\n"
    echo -e "  ${WHITE}${B}Step 1 - Create a GitHub token${NC}"
    echo -e "  Recommended classic token path:"
    echo -e "  ${WHITE}https://github.com/settings/tokens/new?scopes=codespace${NC}"
    echo -e "  Or open GitHub -> Settings -> Developer settings -> Personal access tokens -> Tokens (classic)."
    echo -e "  Generate a new classic token and select only the ${WHITE}codespace${NC} scope."
    echo -e "  Do not paste the GitHub token into G2ray."
    echo -e "  Save it privately, then put it directly into Cloudflare as secret ${WHITE}GITHUB_TOKEN${NC}.\n"
    echo -e "  ${WHITE}${B}Step 2 - Create a Worker${NC}"
    echo -e "  In Cloudflare, create a Hello World Worker, open its editor, and replace the code with:"
    echo -e "  ${WHITE}${BASE_DIR}/worker/codespace-waker/src/index.js${NC}\n"
    echo -e "  In Cloudflare -> Worker -> Settings -> Variables and Secrets, add:"
    echo -e "  ${WHITE}CODESPACE_NAME${NC} as a ${WHITE}Plaintext${NC} variable with this value:"
    echo -e "  ${GREEN}${CODESPACE_NAME}${NC}\n"
    echo -e "  Add these as ${WHITE}Secret${NC} variables:"
    echo -e "  ${WHITE}GITHUB_TOKEN${NC} -> the GitHub token you created"
    echo -e "  ${WHITE}WAKE_SECRET${NC}  -> the wake secret below\n"
    echo -e "  Optional: if you changed XRAY_PORT, add ${WHITE}CODESPACE_PORT${NC} as a Plaintext variable."
    echo -e "  Leave it unset for the default port 443.\n"
    echo -e "  Optional: bind ${WHITE}WAKER_KV${NC} and set ${WHITE}QUOTA_SURVIVAL_CRON_ENABLED=true${NC}"
    echo -e "  only if you want quota-block history and conservative post-reset checks.\n"
    echo -e "  The wake secret is shown once. Save it now and paste it into Cloudflare:"
    echo -e "  ${GREEN}${wake_secret}${NC}"
    echo -e "  ${DIM}Fingerprint saved locally: ${wake_fingerprint}${NC}\n"
    echo -ne "  ${GREEN}Is the Worker deployed with those values? (y/n):${NC} "
    read -r ready || { touch "$WAKER_PROMPT_FILE" 2>/dev/null || true; return 0; }
    [[ "$ready" =~ ^[Yy]$ ]] || { echo -e "  ${DIM}Setup paused. Open option 15 when ready.${NC}"; sleep 2; return 0; }

    echo -ne "  ${GREEN}Worker wake URL (https optional, /wake optional):${NC} "
    read -r worker_url || { echo -e "  ${RED}Missing Worker URL.${NC}"; sleep 2; return 1; }
    worker_url=$(normalize_waker_url "$worker_url" 2>/dev/null || true)
    if [[ -z "$worker_url" ]]; then
        echo -e "  ${RED}Invalid Worker URL.${NC}"
        echo -e "  ${DIM}Example: https://your-worker.your-subdomain.workers.dev/wake${NC}"
        sleep 2
        return 1
    fi
    save_waker_metadata "$worker_url" "$(fingerprint_secret "$wake_secret")" "$CODESPACE_NAME"
    touch "$WAKER_PROMPT_FILE" 2>/dev/null || true
    echo -e "  ${GREEN}Saved non-sensitive waker metadata.${NC}"
    echo -e "  ${DIM}GitHub token and raw wake secret were not stored in G2ray.${NC}\n"
    echo -ne "  ${GREEN}Test Worker now? (y/n):${NC} "
    read -r do_test || do_test="n"
    if [[ "$do_test" =~ ^[Yy]$ ]]; then
        test_cloudflare_waker "$worker_url" "$wake_secret" || true
    fi
    echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

reset_waker_metadata() {
    local confirm
    echo -e "\n  ${YELLOW}Remove saved Worker URL/fingerprint metadata?${NC}"
    echo -ne "  ${GREEN}Proceed (y/n):${NC} "
    read -r confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    rm -f "$WAKER_METADATA_FILE" 2>/dev/null || true
    touch "$WAKER_PROMPT_FILE" 2>/dev/null || true
    log_event INFO "waker_metadata reset"
    echo -e "  ${GREEN}Waker metadata reset.${NC}"
    sleep 1
}

show_recovery_waker() {
    local choice
    while true; do
        refresh_screen
        echo -e "\n  ${RED}Recovery / Waker Setup${NC}\n"
        echo -e "  ${WHITE}${B}External Waker${NC}"
        waker_metadata_summary | sed 's/^/  /'
        echo ""
        echo -e "  ${RED}1)${NC} Setup Cloudflare Waker"
        echo -e "  ${RED}2)${NC} Show Recovery Instructions"
        echo -e "  ${RED}3)${NC} Test Worker URL"
        echo -e "  ${RED}4)${NC} Reset Saved Waker Metadata"
        echo -e "  ${RED}0)${NC} Return"
        echo -ne "  ${RED}Select:${NC} "
        read -r choice || return 0
        case "$choice" in
            1) setup_cloudflare_waker ;;
            2) show_waker_recovery_guide ;;
            3)
                test_cloudflare_waker || true
                echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
                ;;
            4) reset_waker_metadata ;;
            0) return 0 ;;
            *) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

maybe_prompt_waker_setup() {
    [[ -f "$WAKER_METADATA_FILE" || -f "$WAKER_PROMPT_FILE" ]] && return 0
    local answer
    refresh_screen
    echo -e "\n  ${RED}Optional Recovery Waker${NC}\n"
    echo -e "  GitHub can stop Codespaces when idle. This panel can guide you through"
    echo -e "  a Cloudflare Worker wake page so you can restart the Codespace from a browser."
    echo -e "  Do not paste the GitHub token into G2ray; the wizard sends it to Cloudflare only by your hand.\n"
    echo -ne "  ${GREEN}Set up the recovery waker now? (y/n):${NC} "
    read -r answer || { touch "$WAKER_PROMPT_FILE" 2>/dev/null || true; return 0; }
    touch "$WAKER_PROMPT_FILE" 2>/dev/null || true
    [[ "$answer" =~ ^[Yy]$ ]] && setup_cloudflare_waker
}

show_recovery_command_card() {
    local worker_url
    worker_url=$(waker_metadata_value worker_url)
    refresh_screen
    echo -e "\n  ${RED}First-run Recovery Card${NC}\n"
    echo -e "  ${WHITE}Keep these commands handy for the next time GitHub wakes slowly.${NC}"
    echo -e "  ${DIM}This card prints placeholders only; replace <WAKE_SECRET> with your saved secret.${NC}\n"
    echo -e "  ${WHITE}${B}copy these recovery commands${NC}"
    echo -e "  ${GREEN}bash ./g2ray.sh --doctor-json${NC}"
    echo -e "  ${GREEN}bash ./g2ray.sh --recover-now${NC}"
    echo -e "  ${GREEN}bash ./g2ray.sh --recover-now --json${NC}"
    echo -e "  ${GREEN}bash ./g2ray.sh --support-bundle${NC}"
    if [[ -n "$worker_url" ]]; then
        echo -e "  ${DIM}Linux/macOS:${NC}"
        echo -e "  ${GREEN}curl -X POST -H \"Authorization: Bearer <WAKE_SECRET>\" \"${worker_url}\"${NC}"
        echo -e "  ${DIM}Windows PowerShell:${NC}"
        echo -e "  ${GREEN}Invoke-RestMethod -Method Post -Headers @{Authorization=\"Bearer <WAKE_SECRET>\"} -Uri \"${worker_url}\"${NC}"
        echo -e "  ${DIM}Or use curl.exe instead of curl in PowerShell if you prefer curl syntax.${NC}"
    else
        echo -e "  ${DIM}Worker wake command appears here after option 15 is configured.${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}${B}Log files${NC}"
    echo -e "  ${WHITE}${LOG_FILE}${NC}"
    echo -e "  ${WHITE}${STRUCTURED_LOG_FILE}${NC}"
    echo -e "  ${WHITE}${DIAGNOSTIC_LOG_FILE}${NC}\n"
    echo -e "  ${DIM}After this, diagnostics will open automatically so you can confirm route, supervisor, and waker state.${NC}"
    echo -ne "  ${DIM}Press Enter to open diagnostics...${NC}"
    read -r || true
}

write_config_qr_png() {
    local index="$1" link="$2"
    local png_file="$QR_DIR/config-${index}.png"
    command -v qrencode >/dev/null 2>&1 || return 1
    mkdir -p "$QR_DIR" 2>/dev/null || return 1
    qrencode -m 4 -s 8 -t PNG -o "$png_file" "$link" 2>/dev/null || return 1
    chmod 600 "$png_file" 2>/dev/null || true
    printf '%s' "$png_file"
}

render_config_qr() {
    local index="$1" link="$2"
    local png_file=""
    if command -v qrencode >/dev/null 2>&1; then
        if png_file=$(write_config_qr_png "$index" "$link"); then
            echo -e "  ${DIM}High-res QR PNG:${NC} ${WHITE}${png_file}${NC}"
            echo -e "  ${DIM}Open this PNG if your phone cannot scan the terminal preview.${NC}"
        fi
        echo -e "  ${DIM}Terminal QR preview:${NC}"
        qrencode -m 2 -t UTF8 "$link" | while IFS= read -r line; do
            printf '  %s\n' "$line"
        done
    else
        echo -e "  ${DIM}(qrencode not installed - QR unavailable)${NC}"
    fi
}

render_config_entry() {
    local index="$1" label="$2" link="$3"
    local show_qr="${4:-false}"
    echo -e "  ${RED}[${index}]${NC} ${WHITE}${B}${label}${NC}"
    if [[ "$show_qr" == true ]]; then
        echo -e "  ${DIM}QR:${NC}"
        render_config_qr "$index" "$link"
    else
        echo -e "  ${DIM}QR hidden in default view. Set G2RAY_QR_MODE=all to show every QR.${NC}"
    fi
    echo -e "  ${DIM}Copy-ready link:${NC}"
    printf '%s\n' "$link"
    echo ""
}

draw_logo() {
    echo -e "${RED}${B}"
    echo -e "    ██████╗ ██████╗ ██████╗  █████╗ ██╗   ██╗"
    echo -e "   ██╔════╝ ╚════██╗██╔══██╗██╔══██╗╚██╗ ██╔╝"
    echo -e "   ██║  ███╗█████╔╝██████╔╝███████║ ╚████╔╝ "
    echo -e "   ██║   ██║██╔═══╝ ██╔══██╗██╔══██║  ╚██╔╝  "
    echo -e "   ╚██████╔╝███████╗██║  ██║██║  ██║   ██║   "
    echo -e "    ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   ${NC}"
    echo -e "       ${WHITE}${B}v1.4.3${NC} ${DIM}•${NC} ${WHITE}Educational use only${NC} ${DIM}•${NC} ${WHITE}Customized${NC}\n"
}

refresh_screen() {
    stty sane 2>/dev/null || true
    clear
    draw_logo
}

verify_update_candidate() {
    local candidate="${1:-}"
    [[ -s "$candidate" ]] || return 1
    grep -Fq 'readonly G2RAY_ID="G2ray Panel' "$candidate" 2>/dev/null || return 1
    grep -Fq 'Educational use only' "$candidate" 2>/dev/null || return 1
    grep -Fq 'detect_project_repo_default()' "$candidate" 2>/dev/null || return 1
    grep -Fq 'ensure_runtime_ready()' "$candidate" 2>/dev/null || return 1
    grep -Fq 'print_doctor_json()' "$candidate" 2>/dev/null || return 1
    grep -Fq 'recover_now_json()' "$candidate" 2>/dev/null || return 1
    bash -n "$candidate" 2>/dev/null || return 1
    return 0
}

tracked_panel_has_local_changes() {
    command -v git >/dev/null 2>&1 || return 1
    git -C "$BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "$BASE_DIR" diff --quiet -- g2ray.sh 2>/dev/null || return 0
    git -C "$BASE_DIR" diff --cached --quiet -- g2ray.sh 2>/dev/null || return 0
    return 1
}

check_for_updates() {
    [[ "${G2RAY_AUTO_UPDATE:-0}" == "1" ]] || return 0
    latency_focus_enabled && return 0
    if [[ "${G2RAY_AUTO_UPDATE_FORCE:-0}" != "1" ]] && tracked_panel_has_local_changes; then
        printf "  %b⚠%b %bAuto-update skipped because g2ray.sh has local changes. Set G2RAY_AUTO_UPDATE_FORCE=1 to override.%b\n" "$YELLOW" "$NC" "$DIM" "$NC"
        sleep 1
        return 0
    fi
    clear; draw_logo
    local tmp="" staged=""
    tmp=$(mktemp "${TMPDIR:-/tmp}/g2ray_remote.XXXXXX") || {
        printf "\r  %b✖%b %bUpdate check failed (no temp file).    %b\n" "$RED" "$NC" "$DIM" "$NC"
        sleep 1
        return 0
    }
    curl -s -m 8 -L "${RAW_BASE_URL}/g2ray.sh" -o "$tmp" &
    local pid=$! frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏") i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %b%s%b %bChecking for latest updates...%b" "$GREEN" "${frames[i]}" "$NC" "$WHITE" "$NC"
        i=$(( (i+1) % 10 )); sleep 0.1
    done
    wait "$pid" || true
    if verify_update_candidate "$tmp"; then
        if ! cmp -s "$0" "$tmp"; then
            printf "\r  %b✔%b %bUpdate found! Installing...              %b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            staged=$(mktemp "${TMPDIR:-/tmp}/g2ray_update.XXXXXX") || {
                printf "  %b✖%b %bUpdate staging failed.%b\n" "$RED" "$NC" "$DIM" "$NC"
                rm -f "$tmp" 2>/dev/null || true
                sleep 1
                return 0
            }
            cp "$tmp" "$staged"
            chmod +x "$staged"
            mv -f "$staged" "$0"
            printf "  %b✔%b %bUpdate applied! Restarting...%b\n" "$GREEN" "$NC" "$WHITE" "$NC"
            sleep 1.5; exec bash "$0" "$@"
        else
            printf "\r  %b✔%b %bSystem is fully up to date.               %b\n" "$GREEN" "$NC" "$DIM" "$NC"
        fi
    else
        printf "\r  %b✖%b %bUpdate check failed (network or 404).     %b\n" "$RED" "$NC" "$DIM" "$NC"
    fi
    rm -f "$tmp" "$staged" 2>/dev/null || true
    sleep 1
}

fetch_remote_message() {
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/g2ray_msg.XXXXXX") || return 0
    curl -s -m 4 "${RAW_BASE_URL}/assets/message.txt" \
        > "$tmp" 2>/dev/null || true
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$REMOTE_MESSAGE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

enable_anti_sleep() {
    tmux has-session -t g2ray_keepalive 2>/dev/null && return 0
    cat > "$DATA_DIR/keepalive.sh" << 'EOF'
#!/bin/bash
i=0
while true; do
    i=$(( i+1 ))
    printf "\r[G2ray] Keepalive tick: %d" "$i"
    (( i % 60 == 0 )) && curl -s -m 4 https://github.com >/dev/null 2>&1
    sleep 1
done
EOF
    chmod +x "$DATA_DIR/keepalive.sh"
    local keepalive_cmd; keepalive_cmd=$(printf 'bash %q' "$DATA_DIR/keepalive.sh")
    tmux new-session -d -s g2ray_keepalive "$keepalive_cmd" 2>/dev/null || true
}

is_port_open() {
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    else
        sudo netstat -tnl 2>/dev/null | grep -q ":${XRAY_PORT}[[:space:]]"
    fi
}

xray_listener_ready() {
    xray_running || return 1
    is_port_open || return 1
    local code
    code=$(xhttp_probe_status local)
    xhttp_status_usable "$code"
}

stamp_age_sec() {
    local file="$1" now stamp
    [[ -f "$file" ]] || { printf '999999999'; return 0; }
    now=$(date +%s 2>/dev/null || printf '0')
    stamp=$(cat "$file" 2>/dev/null || printf '0')
    [[ "$stamp" =~ ^[0-9]+$ ]] || stamp=0
    printf '%s' "$(( now - stamp ))"
}

file_age_sec() {
    local file="$1" now mtime
    [[ -f "$file" ]] || { printf '999999999'; return 0; }
    now=$(date +%s 2>/dev/null || printf '0')
    mtime=$(stat -c %Y "$file" 2>/dev/null || printf '0')
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    printf '%s' "$(( now - mtime ))"
}

write_epoch_stamp() {
    local file="$1" now
    now=$(date +%s 2>/dev/null || printf '0')
    _atomic_write "$file" "$now"
    chmod 600 "$file" 2>/dev/null || true
}

ensure_codespace_port_public() {
    local force="${1:-}" age stamp_file
    stamp_file="${PORT_PUBLIC_STAMP_FILE}.${CODESPACE_NAME}.${XRAY_PORT}"
    stamp_file=$(printf '%s' "$stamp_file" | tr -c 'A-Za-z0-9._/-' '_')
    age=$(stamp_age_sec "$stamp_file")
    if [[ "$force" != "force" && "$PORT_PUBLIC_TTL_SEC" =~ ^[0-9]+$ && "$age" -lt "$PORT_PUBLIC_TTL_SEC" ]]; then
        log_event INFO "port_public cached_ok port=${XRAY_PORT} age_sec=${age} ttl=${PORT_PUBLIC_TTL_SEC}"
        return 0
    fi
    command -v gh >/dev/null 2>&1 || {
        log_event WARN "port_public gh_missing port=${XRAY_PORT}"
        return 1
    }
    local output
    if output=$(run_gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME" </dev/null 2>&1); then
        write_epoch_stamp "$stamp_file"
        log_event INFO "port_public ok port=${XRAY_PORT} forced=${force:-false}"
        return 0
    fi
    output=$(printf '%s' "$output" | tr '\r\n' '  ' | cut -c1-180)
    log_event WARN "port_public failed port=${XRAY_PORT} detail=${output:-unknown}"
    return 1
}

repair_codespace_port_route() {
    command -v gh >/dev/null 2>&1 || return 1
    log_event WARN "route_repair begin port=${XRAY_PORT} domain=${PORT_DOMAIN}"
    run_gh codespace ports visibility "${XRAY_PORT}:private" -c "$CODESPACE_NAME" \
        </dev/null >/dev/null 2>&1 || true
    sleep 2
    if ensure_codespace_port_public force; then
        log_event INFO "route_repair public_ok port=${XRAY_PORT}"
        return 0
    fi
    log_event ERROR "route_repair public_failed port=${XRAY_PORT}"
    return 1
}

wait_for_xhttp_route_ready() {
    local reason="${1:-startup}" max_wait="${2:-$ROUTE_WAIT_SEC}" start now elapsed xcode=0 xms=0 attempt=0 stable=0
    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=120
    start=$(date +%s 2>/dev/null || printf '0')
    while true; do
        attempt=$(( attempt + 1 ))
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        now=$(date +%s 2>/dev/null || printf '0')
        elapsed=$(( now - start ))
        if xhttp_status_usable "$xcode"; then
            stable=$(( stable + 1 ))
            if (( stable >= ROUTE_READY_STABLE_PROBES )); then
                log_event INFO "runtime_ready reason=${reason} route_wait_ready xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} wait_sec=${elapsed} stable_probes=${stable}"
                record_route_settling_metric "$reason" "ready" "${xcode:-0}" "${xms:-0}" "$elapsed" "$attempt"
                return 0
            fi
        else
            stable=0
        fi
        (( elapsed >= max_wait )) && break
        if (( attempt == 1 || attempt % 5 == 0 )); then
            ensure_codespace_port_public >/dev/null 2>&1 || true
        fi
        if (( stable > 0 )); then
            sleep "$ROUTE_READY_STABLE_SLEEP_SEC"
        else
            sleep 3
        fi
    done
    log_event WARN "runtime_ready reason=${reason} route_wait_timeout xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} wait_sec=${max_wait} stable_probes=${stable}"
    record_route_settling_metric "$reason" "timeout" "${xcode:-0}" "${xms:-0}" "$max_wait" "$attempt"
    return 1
}

record_route_settling_metric() {
    local reason="$1" result="$2" code="$3" ms="$4" wait_sec="$5" attempts="$6" checked
    checked=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$checked" "$reason" "$result" "${code:-0}" "${ms:-0}" "${wait_sec:-0}" "${attempts:-0}" \
        >> "$ROUTE_SETTLING_HISTORY_FILE" 2>/dev/null || true
    chmod 600 "$ROUTE_SETTLING_HISTORY_FILE" 2>/dev/null || true
}

route_settling_history_summary() {
    if [[ ! -s "$ROUTE_SETTLING_HISTORY_FILE" ]]; then
        printf 'Last route wait : none recorded\n'
        printf 'History         : no route-settling waits have completed yet\n'
        return 0
    fi
    awk -F '\t' '
        NF >= 7 {
            n++;
            wait_sum += $6;
            last = $0;
            if ($3 == "ready") ready++;
            if ($3 == "timeout") timeout++;
        }
        END {
            if (n == 0) {
                print "Last route wait : none recorded";
                print "History         : no route-settling waits have completed yet";
                exit
            }
            split(last, f, "\t");
            printf "Last route wait : %s reason=%s result=%s http=%s wait=%ss attempts=%s\n", f[1], f[2], f[3], f[4], f[6], f[7];
            printf "Summary         : samples=%d ready=%d timeout=%d avg_wait=%ds\n", n, ready+0, timeout+0, wait_sum / n;
            print "Recent waits    :";
        }
    ' "$ROUTE_SETTLING_HISTORY_FILE" 2>/dev/null
    tail -n 6 "$ROUTE_SETTLING_HISTORY_FILE" 2>/dev/null | awk -F '\t' 'NF >= 7 {printf "  %s %-22s %-7s HTTP %-3s wait=%ss attempts=%s\n", $1, $2, $3, $4, $6, $7}'
}

save_xray_stats() {
    xray_running || return 0
    local stats sd su bd bu svd svu dd du
    stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || return 0
    [[ -z "$stats" ]] && return 0
    sd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    su=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
        grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
    sd=${sd:-0}; su=${su:-0}
    bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
    dd=$(awk -v s="$sd" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    du=$(awk -v s="$su" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    _atomic_write "$SAVED_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' \
            "$(awk -v a="$svd" -v b="$dd" 'BEGIN{printf "%.0f",a+b}')" \
            "$(awk -v a="$svu" -v b="$du" 'BEGIN{printf "%.0f",a+b}')")"
    _atomic_write "$SESSION_BYTES_FILE" \
        "$(printf '{"down":%s,"up":%s}' "$sd" "$su")"
}

get_data_usage() {
    local svd svu sd=0 su=0 stats fd fu bd bu
    svd=$(jq -r '.down//0' "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    svu=$(jq -r '.up//0'   "$SAVED_BYTES_FILE" 2>/dev/null || echo 0)
    if xray_running; then
        stats=$(sudo timeout 3 "$XRAY_BIN" api statsquery -server=127.0.0.1:10085 2>/dev/null) || true
        if [[ -n "$stats" ]]; then
            fd=$(printf '%s' "$stats" | grep -A1 'downlink' | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            fu=$(printf '%s' "$stats" | grep -A1 'uplink'   | grep 'value' | \
                grep -oE '[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?' | awk '{s+=$1}END{printf "%.0f",s+0}')
            bd=$(jq -r '.down//0' "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            bu=$(jq -r '.up//0'   "$SESSION_BYTES_FILE" 2>/dev/null || echo 0)
            sd=$(awk -v s="${fd:-0}" -v b="$bd" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
            su=$(awk -v s="${fu:-0}" -v b="$bu" 'BEGIN{d=s-b; printf "%.0f",(d<0?0:d)}')
        fi
    fi
    printf '%s %s' \
        "$(awk -v a="$svd" -v b="$sd" 'BEGIN{printf "%.0f",a+b}')" \
        "$(awk -v a="$svu" -v b="$su" 'BEGIN{printf "%.0f",a+b}')"
}

reset_session_bytes_baseline() {
    _atomic_write "$SESSION_BYTES_FILE" '{"down":0,"up":0}'
}

current_quota_cycle() {
    date -u '+%Y-%m' 2>/dev/null || date '+%Y-%m'
}

reset_monthly_quota_if_needed() {
    local current stored now
    current=$(current_quota_cycle)
    stored=$(cat "$QUOTA_CYCLE_FILE" 2>/dev/null || true)
    if [[ -z "$stored" ]]; then
        printf '%s\n' "$current" > "$QUOTA_CYCLE_FILE"
        chmod 600 "$QUOTA_CYCLE_FILE" 2>/dev/null || true
        return 0
    fi
    [[ "$stored" == "$current" ]] && return 0
    now=$(date +%s)
    printf '0\n' > "$TOTAL_UPTIME_FILE"
    printf '%s\n' "$now" > "$SESSION_START_FILE"
    printf '%s\n' "$current" > "$QUOTA_CYCLE_FILE"
    chmod 600 "$QUOTA_CYCLE_FILE" "$TOTAL_UPTIME_FILE" "$SESSION_START_FILE" 2>/dev/null || true
    log_event INFO "quota_cycle_reset old=${stored} new=${current}"
}

save_session_uptime() {
    local ss now elapsed prev
    reset_monthly_quota_if_needed
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s)
    elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    printf '%s\n' $(( prev + elapsed )) > "$TOTAL_UPTIME_FILE"
    printf '%s\n' "$now"               > "$SESSION_START_FILE"
}

acquire_runtime_lock() {
    local op="${1:-runtime}" i lock_pid attempts="$RUNTIME_LOCK_WAIT_ATTEMPTS"
    [[ "$attempts" =~ ^[0-9]+$ && "$attempts" -ge 1 ]] || attempts=20
    for ((i=1; i<=attempts; i++)); do
        if mkdir "$RUNTIME_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true
            printf '%s\n' "$op" > "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
            return 0
        fi
        lock_pid=$(cat "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -z "$lock_pid" || ! "$lock_pid" =~ ^[0-9]+$ ]]; then
            log_event WARN "runtime_lock_stale malformed pid=${lock_pid:-missing} op=${op}"
            rm -f "$RUNTIME_LOCK_DIR/pid" "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
            rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || true
            if mkdir "$RUNTIME_LOCK_DIR" 2>/dev/null; then
                printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true
                printf '%s\n' "$op" > "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
                return 0
            fi
            continue
        fi
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$RUNTIME_LOCK_DIR/pid" "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
            rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || true
            if mkdir "$RUNTIME_LOCK_DIR" 2>/dev/null; then
                printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true
                printf '%s\n' "$op" > "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
                return 0
            fi
            continue
        fi
        if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$RUNTIME_LOCK_DIR/pid" "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
            rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || true
            if mkdir "$RUNTIME_LOCK_DIR" 2>/dev/null; then
                printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true
                printf '%s\n' "$op" > "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
                return 0
            fi
            continue
        fi
        sleep 0.2
    done
    return 1
}

release_runtime_lock() {
    local lock_pid
    lock_pid=$(cat "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true)
    [[ "$lock_pid" == "$$" ]] || return 0
    rm -f "$RUNTIME_LOCK_DIR/pid" "$RUNTIME_LOCK_DIR/op" 2>/dev/null || true
    rmdir "$RUNTIME_LOCK_DIR" 2>/dev/null || true
}

with_runtime_lock() {
    local op="${1:-runtime}" rc shell_opts old_held
    if [[ "${G2RAY_RUNTIME_LOCK_HELD:-}" == "1" ]]; then
        "$@"
        return $?
    fi
    if ! acquire_runtime_lock "$op"; then
        log_event WARN "runtime_lock busy op=${op}"
        return 1
    fi
    old_held="${G2RAY_RUNTIME_LOCK_HELD-__unset__}"
    shell_opts="$-"
    G2RAY_RUNTIME_LOCK_HELD=1
    set +e
    "$@"
    rc=$?
    case "$shell_opts" in
        *e*) set -e ;;
        *) set +e ;;
    esac
    if [[ "$old_held" == "__unset__" ]]; then
        unset G2RAY_RUNTIME_LOCK_HELD
    else
        G2RAY_RUNTIME_LOCK_HELD="$old_held"
    fi
    release_runtime_lock
    return "$rc"
}

_stop_xray_impl() {
    save_xray_stats 2>/dev/null || true
    local p owned_pids=()
    mapfile -t owned_pids < <(owned_xray_pids | awk 'NF && !seen[$0]++ {print}')
    if ((${#owned_pids[@]})); then
        for p in "${owned_pids[@]}"; do
            if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
                log_event INFO "stop_xray pid=${p}"
                sudo kill "$p" >/dev/null 2>&1 || true
                sleep 0.5
                if sudo kill -0 "$p" 2>/dev/null; then
                    sudo kill -9 "$p" >/dev/null 2>&1 || true
                    log_event WARN "stop_xray forced_kill pid=${p}"
                fi
            fi
        done
    else
        log_event INFO "stop_xray no-owned-process"
    fi
    if ((${#owned_pids[@]})); then
        for p in "${owned_pids[@]}"; do
            if xray_pid_matches "$p" && sudo kill -0 "$p" 2>/dev/null; then
                log_event ERROR "stop_xray still_alive pid=${p}"
                return 1
            fi
        done
    fi
    rm -f "$XRAY_PID_FILE" 2>/dev/null || true
    sleep 0.5
}

stop_xray() {
    with_runtime_lock _stop_xray_impl "$@"
}

upgrade_config_dns() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    if ! command -v jq >/dev/null 2>&1; then
        log_event WARN "config_dns jq_unavailable"
        return 0
    fi

    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.dns.XXXXXX") || return 0
    if jq '
      .dns = {
        "hosts": {
          "dns.google": ["8.8.8.8", "8.8.4.4"],
          "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]
        },
        "servers": [
          { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
          { "address": "https+local://dns.google/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
          { "address": "1.0.0.1", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
          { "address": "8.8.4.4", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
          "localhost"
        ],
        "queryStrategy": "UseIPv4",
        "disableFallback": false,
        "disableFallbackIfMatch": false,
        "enableParallelQuery": true
      }
    ' "$CONFIG_FILE" > "$tmp" 2>/dev/null; then
        if cmp -s "$CONFIG_FILE" "$tmp"; then
            rm -f "$tmp" 2>/dev/null || true
        else
            mv -f "$tmp" "$CONFIG_FILE"
            log_event INFO "config_dns refreshed"
        fi
    else
        rm -f "$tmp" 2>/dev/null || true
        log_event WARN "config_dns refresh_failed"
    fi
}

_start_xray_impl() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_event WARN "start_xray missing_config path=${CONFIG_FILE}"
        echo -e "  ${RED}✖ No config found. Generate one first (Option 2).${NC}"
        return 1
    fi
    local launch_cmd pid
    log_event INFO "start_xray requested port=${XRAY_PORT} config=${CONFIG_FILE}"
    launch_cmd=$(printf 'nohup %q run -c %q </dev/null >%q 2>&1 & printf "%%s\n" "$!"' \
        "$XRAY_BIN" "$CONFIG_FILE" "$LOG_DIR/xray.log")
    if ! stop_xray; then
        log_event ERROR "start_xray stop_previous_failed"
        echo -e "  ${RED}✖ Could not stop previous Xray process.${NC}"
        return 1
    fi
    upgrade_config_dns >/dev/null 2>&1 || true
    reset_session_bytes_baseline
    pid=$(sudo bash -c "$launch_cmd" 2>/dev/null || true)
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        log_event ERROR "start_xray launch_failed"
        echo -e "  ${RED}✖ Failed to start Xray.${NC}"
        return 1
    fi
    printf '%s\n' "$pid" > "$XRAY_PID_FILE"
    log_event INFO "xray launched pid=${pid} port=${XRAY_PORT}"
}

start_xray() {
    with_runtime_lock _start_xray_impl "$@"
}

wait_for_port() {
    local i=0 frame_index=0
    local frames=("-" "\\" "|" "/")
    while ! xray_listener_ready && (( i < 15 )); do
        printf "\r  ${GREEN}%s${NC} ${DIM}Initializing engine... (${i}s)${NC}" "${frames[$frame_index]}"
        frame_index=$(( (frame_index + 1) % ${#frames[@]} ))
        sleep 1
        i=$((i + 1))
    done
    printf "\r  ${GREEN}%s${NC} ${DIM}Initializing engine... (${i}s)${NC}        \n" "${frames[$frame_index]}"
    if xray_listener_ready; then
        log_event INFO "wait_for_port open port=${XRAY_PORT} seconds=${i}"
        return 0
    fi
    log_event ERROR "wait_for_port timeout port=${XRAY_PORT} seconds=${i}"
    return 1
}

health_probe() {
    local engine="stopped" listener="closed" code xcode xms xhttp_route_usable=false
    xray_running && engine="running"
    is_port_open && listener="open"
    code=$(curl_http_code "https://${PORT_DOMAIN}" 5)
    read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
    xhttp_status_usable "$xcode" && xhttp_route_usable=true
    log_event INFO "health engine=${engine} listener=${listener} external_code=${code:-0} xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} xhttp_route_usable=${xhttp_route_usable} domain=${PORT_DOMAIN}"
}

self_heal_once() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local reason="" code xcode xms bad_count threshold

    if ! ensure_codespace_port_public >/dev/null 2>&1; then
        log_event WARN "self_heal port_public_failed port=${XRAY_PORT}"
    fi

    if ! xray_running; then
        reason=xray_stopped
    elif ! xray_listener_ready; then
        reason=listener_closed
    fi

    if [[ -n "$reason" ]]; then
        log_event WARN "self_heal restart reason=${reason}"
        if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
            log_event INFO "self_heal restart_ok reason=${reason}"
            ensure_codespace_port_public >/dev/null 2>&1 || true
        else
            log_event ERROR "self_heal restart_failed reason=${reason}"
            return 1
        fi
    fi

    read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
    if xhttp_status_usable "$xcode"; then
        reset_route_bad_count
        reset_edge_bad_count
        return 0
    fi

    code=$(curl_http_code "https://${PORT_DOMAIN}" 5)
    if [[ "$code" == "000" || "$code" == "0" ]]; then
        threshold="$SELF_HEAL_EDGE_RECONNECT_THRESHOLD"
        [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
        bad_count=$(increment_edge_bad_count)
        if edge_reconnect_cooldown_active; then
            log_event WARN "self_heal edge_unreachable code=${code:-0} bad_count=${bad_count} xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=cooldown"
            return 0
        fi
        if (( bad_count < threshold )); then
            log_event WARN "self_heal edge_unreachable code=${code:-0} bad_count=${bad_count} action=observe xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0}"
            return 0
        fi
        log_event WARN "self_heal edge_unreachable code=${code:-0} bad_count=${bad_count} action=force_reconnect xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0}"
        mark_edge_reconnect_attempt
        if force_reconnect --no-prompt >/dev/null 2>&1; then
            reset_edge_bad_count
        else
            log_event ERROR "self_heal force_reconnect_failed code=${code:-0}"
        fi
        return 0
    fi

    reset_edge_bad_count
    bad_count=$(increment_route_bad_count)
    log_event WARN "self_heal route_unusable xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} bad_count=${bad_count} action=observe"
    if (( bad_count >= 2 )); then
        log_event WARN "self_heal route_unusable action=repair port=${XRAY_PORT}"
        repair_codespace_port_route >/dev/null 2>&1 || true
        reset_route_bad_count
    fi
}

_background_tasks() {
    set +e
    local tick=0 health_tick=0 export_tick=0 route_tick=0
    write_background_supervisor_heartbeat
    if [[ -f "$CONFIG_FILE" ]]; then
        self_heal_once >/dev/null 2>&1 || true
        if ! latency_focus_enabled; then
            refresh_route_candidate_health >/dev/null 2>&1 || true
            refresh_config_exports >/dev/null 2>&1 || true
            health_probe >/dev/null 2>&1 || true
        fi
    fi
    while true; do
        sleep 60
        if ! background_supervisor_token_current; then
            log_event WARN "background supervisor_superseded pid=$$"
            exit 0
        fi
        write_background_supervisor_heartbeat
        rotate_log_file "$LOG_FILE"
        rotate_log_file "$LOG_DIR/xray-error.log"
        if [[ "$PORT_DOMAIN" == unknown-codespace* ]]; then
            local n; n=$(_detect_codespace_name 2>/dev/null || true)
            if [[ -n "$n" && "$n" != "unknown-codespace" ]]; then
                CODESPACE_NAME="$n"
                PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
            fi
        fi
        [[ -f "$CONFIG_FILE" ]] || continue
        self_heal_once >/dev/null 2>&1 || true
        save_xray_stats    >/dev/null 2>&1 || true
        save_session_uptime >/dev/null 2>&1 || true
        if latency_focus_enabled; then
            (( ++health_tick >= 15 )) && { health_probe >/dev/null 2>&1; health_tick=0; }
            continue
        fi
        (( ++health_tick >= 5 )) && { health_probe >/dev/null 2>&1; health_tick=0; }
        if low_overhead_enabled; then
            (( ++route_tick >= 15 )) && { refresh_route_candidate_health >/dev/null 2>&1 || true; route_tick=0; }
            (( ++export_tick >= 15 )) && { refresh_config_exports >/dev/null 2>&1 || true; export_tick=0; }
        else
            (( ++route_tick >= 5 )) && { refresh_route_candidate_health >/dev/null 2>&1 || true; route_tick=0; }
            (( ++export_tick >= 5 )) && { refresh_config_exports >/dev/null 2>&1 || true; export_tick=0; }
            (( ++tick >= 3 )) && { fetch_remote_message; tick=0; }
        fi
    done
}

acquire_bg_tasks_lock() {
    local i lock_pid
    for i in {1..20}; do
        if mkdir "$BG_TASKS_LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
        lock_pid=$(cat "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -z "$lock_pid" || ! "$lock_pid" =~ ^[0-9]+$ ]]; then
            log_event WARN "background_lock_stale malformed pid=${lock_pid:-missing}"
            rm -f "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true
            rmdir "$BG_TASKS_LOCK_DIR" 2>/dev/null || true
            if mkdir "$BG_TASKS_LOCK_DIR" 2>/dev/null; then
                printf '%s\n' "$$" > "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true
                return 0
            fi
            continue
        fi
        if ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -f "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true
            rmdir "$BG_TASKS_LOCK_DIR" 2>/dev/null || true
            continue
        fi
        sleep 0.1
    done
    log_event WARN "background lock_busy"
    return 1
}

release_bg_tasks_lock() {
    rm -f "$BG_TASKS_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$BG_TASKS_LOCK_DIR" 2>/dev/null || true
}

start_background_tasks() {
    local token bg_pid
    if ! acquire_bg_tasks_lock; then
        return 0
    fi
    if [[ -f "$BG_TASKS_PID" ]]; then
        local p; p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
        if bg_tasks_running "$p" || background_supervisor_heartbeat_running "$p"; then
            if background_supervisor_version_matches; then
                release_bg_tasks_lock
                return 0
            fi
            log_event WARN "background supervisor_stale pid=${p}"
            stop_background_tasks
        elif legacy_bg_tasks_running "$p"; then
            log_event WARN "background legacy_supervisor_stale pid=${p}"
            stop_background_tasks
        fi
    fi
    token=$(uuidgen 2>/dev/null || printf '%s-%s-%s' "$$" "$RANDOM" "$(date +%s)")
    printf '%s\n' "$token" > "$BG_TASKS_TOKEN_FILE"
    G2RAY_BG_TASK_TOKEN="$token" nohup bash "$BASE_DIR/g2ray.sh" --background-supervisor </dev/null >/dev/null 2>&1 &
    bg_pid=$!
    printf '%s\n' "$bg_pid" > "$BG_TASKS_PID"
    background_supervisor_version > "$BG_TASKS_VERSION_FILE" 2>/dev/null || true
    log_event INFO "background supervisor_started pid=${bg_pid}"
    release_bg_tasks_lock
    disown 2>/dev/null || true
}

background_supervisor_version() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$BASE_DIR/g2ray.sh" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$BASE_DIR/g2ray.sh" 2>/dev/null | awk '{print $1}'
    elif command -v git >/dev/null 2>&1; then
        git -C "$BASE_DIR" rev-parse HEAD 2>/dev/null || true
    fi
}

background_supervisor_version_matches() {
    local expected current
    expected=$(cat "$BG_TASKS_VERSION_FILE" 2>/dev/null || true)
    current=$(background_supervisor_version)
    [[ -n "$expected" && -n "$current" && "$expected" == "$current" ]]
}

stop_background_tasks() {
    local p
    p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
    if bg_tasks_running "$p" || background_supervisor_heartbeat_running "$p" || legacy_bg_tasks_running "$p"; then
        kill "$p" >/dev/null 2>&1 || true
        sleep 1
        (bg_tasks_running "$p" || background_supervisor_heartbeat_running "$p" || legacy_bg_tasks_running "$p") && kill -9 "$p" >/dev/null 2>&1 || true
    fi
    rm -f "$BG_TASKS_PID" "$BG_TASKS_VERSION_FILE" "$BG_TASKS_TOKEN_FILE" 2>/dev/null || true
}

legacy_bg_tasks_running() {
    local p="${1:-}" args tty
    [[ -f "$BG_TASKS_TOKEN_FILE" ]] && return 1
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    args=$(ps -p "$p" -o args= 2>/dev/null || true)
    tty=$(ps -p "$p" -o tty= 2>/dev/null | awk '{print $1}' || true)
    [[ "$tty" == "?" && ( "$args" == *"$BASE_DIR/g2ray.sh"* || "$args" == *"g2ray.sh"* ) ]]
}

bg_tasks_running() {
    local p="${1:-}" expected
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    expected=$(cat "$BG_TASKS_TOKEN_FILE" 2>/dev/null || true)
    if [[ -n "$expected" && -r "/proc/$p/environ" ]]; then
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -Fxq "G2RAY_BG_TASK_TOKEN=$expected"
        return
    fi
    return 1
}

background_supervisor_token_current() {
    local expected
    expected=$(cat "$BG_TASKS_TOKEN_FILE" 2>/dev/null || true)
    [[ -n "${G2RAY_BG_TASK_TOKEN:-}" && -n "$expected" && "$G2RAY_BG_TASK_TOKEN" == "$expected" ]]
}

write_background_supervisor_heartbeat() {
    local now
    now=$(date +%s)
    printf '%s %s %s\n' "${BASHPID:-$$}" "${G2RAY_BG_TASK_TOKEN:-}" "$now" > "$BG_TASKS_HEARTBEAT_FILE" 2>/dev/null || true
}

background_supervisor_heartbeat_timestamp() {
    local raw hb_pid hb_token hb_ts
    raw=$(cat "$BG_TASKS_HEARTBEAT_FILE" 2>/dev/null || true)
    read -r hb_pid hb_token hb_ts _ <<< "$raw"
    if [[ "$hb_ts" =~ ^[0-9]+$ ]]; then
        printf '%s' "$hb_ts"
    elif [[ "$hb_pid" =~ ^[0-9]+$ ]]; then
        printf '%s' "$hb_pid"
    else
        return 1
    fi
}

background_supervisor_recent_heartbeat() {
    local hb now max_age="${1:-180}"
    hb=$(background_supervisor_heartbeat_timestamp 2>/dev/null || true)
    [[ "$hb" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    (( now >= hb && now - hb <= max_age ))
}

background_supervisor_heartbeat_matches() {
    local p="${1:-}" raw hb_pid hb_token hb_ts expected
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    expected=$(cat "$BG_TASKS_TOKEN_FILE" 2>/dev/null || true)
    [[ -n "$expected" ]] || return 1
    raw=$(cat "$BG_TASKS_HEARTBEAT_FILE" 2>/dev/null || true)
    read -r hb_pid hb_token hb_ts _ <<< "$raw"
    [[ "$hb_pid" == "$p" && "$hb_token" == "$expected" && "$hb_ts" =~ ^[0-9]+$ ]] || return 1
    background_supervisor_recent_heartbeat
}

background_supervisor_heartbeat_running() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    background_supervisor_heartbeat_matches "$p" || return 1
}

background_supervisor_status() {
    local p running="false" token_state="missing" version_state="missing" heartbeat_age="unknown" hb now expected current
    p=$(cat "$BG_TASKS_PID" 2>/dev/null || true)
    if bg_tasks_running "$p"; then
        running="true"
    elif legacy_bg_tasks_running "$p"; then
        running="legacy"
    elif background_supervisor_heartbeat_running "$p"; then
        running="heartbeat"
    fi
    [[ -s "$BG_TASKS_TOKEN_FILE" ]] && token_state="present"
    expected=$(cat "$BG_TASKS_VERSION_FILE" 2>/dev/null || true)
    current=$(background_supervisor_version)
    if [[ -n "$expected" && -n "$current" ]]; then
        [[ "$expected" == "$current" ]] && version_state="ok" || version_state="stale"
    fi
    hb=$(background_supervisor_heartbeat_timestamp 2>/dev/null || true)
    if [[ "$hb" =~ ^[0-9]+$ ]]; then
        now=$(date +%s)
        heartbeat_age="$((now - hb))s"
    fi
    printf 'pid=%s running=%s version=%s token=%s heartbeat_age=%s\n' "${p:-none}" "$running" "$version_state" "$token_state" "$heartbeat_age"
}

format_duration_compact() {
    local seconds="${1:-0}" days hours minutes
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    minutes=$(( (seconds % 3600) / 60 ))
    if (( days > 0 )); then
        printf '%dd %dh %dm' "$days" "$hours" "$minutes"
    elif (( hours > 0 )); then
        printf '%dh %dm' "$hours" "$minutes"
    else
        printf '%dm %ds' "$minutes" "$((seconds % 60))"
    fi
}

resume_gap_threshold_sec() {
    local threshold="${G2RAY_RESUME_GAP_WARN_SEC:-300}"
    [[ "$threshold" =~ ^[0-9]+$ && "$threshold" -gt 0 ]] || threshold=300
    printf '%s' "$threshold"
}

record_resume_gap() {
    local reason="${1:-startup}" hb now gap threshold detected
    hb=$(background_supervisor_heartbeat_timestamp 2>/dev/null || true)
    [[ "$hb" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s 2>/dev/null || echo 0)
    [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$hb" ]] || return 0
    gap=$((now - hb))
    threshold=$(resume_gap_threshold_sec)
    (( gap < threshold )) && return 0
    detected=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    printf 'reason=%s gap_sec=%s gap=%s previous_heartbeat=%s detected_at=%s\n' \
        "$reason" "$gap" "$(format_duration_compact "$gap")" "$hb" "$detected" > "$RESUME_GAP_FILE" 2>/dev/null || true
    chmod 600 "$RESUME_GAP_FILE" 2>/dev/null || true
    log_event WARN "resume_gap reason=${reason} gap_sec=${gap} previous_heartbeat=${hb} likely=stopped_or_suspended"
}

resume_gap_summary() {
    local line
    if [[ ! -s "$RESUME_GAP_FILE" ]]; then
        printf 'Last gap : none recorded\n'
        printf 'Meaning  : no long supervisor heartbeat gap has been observed yet\n'
        return 0
    fi
    line=$(tail -n 1 "$RESUME_GAP_FILE" 2>/dev/null || true)
    printf 'Last gap : %s\n' "${line:-none recorded}"
    printf 'Meaning  : a gap means the supervisor could not heartbeat, usually because the Codespace was stopped, suspended, rebuilding, or quota-blocked\n'
}

format_bytes() {
    awk -v b="${1:-0}" 'BEGIN{
        if      (b < 1048576)    printf "%.2f KB", b / 1024
        else if (b < 1073741824) printf "%.2f MB", b / 1048576
        else                     printf "%.2f GB", b / 1073741824
    }'
}

estimate_quota() {
    local prev ss now elapsed total rem h_used m_used h_left m_left dtime quota_seconds quota_hours
    reset_monthly_quota_if_needed
    quota_seconds="${G2RAY_QUOTA_SECONDS:-216000}"
    [[ "$quota_seconds" =~ ^[0-9]+$ && "$quota_seconds" -gt 0 ]] || quota_seconds=216000
    quota_hours=$(( quota_seconds / 3600 ))
    prev=$(cat "$TOTAL_UPTIME_FILE" 2>/dev/null || echo 0)
    ss=$(cat "$SESSION_START_FILE" 2>/dev/null || date +%s)
    now=$(date +%s); elapsed=$(( now - ss ))
    (( elapsed < 0    )) && elapsed=0
    (( elapsed > 3600 )) && elapsed=3600
    total=$(( prev + elapsed ))
    rem=$(( quota_seconds - total )); (( rem < 0 )) && rem=0
    h_used=$(( total / 3600 ));   m_used=$(( (total % 3600) / 60 ))
    h_left=$(( rem   / 3600 ));   m_left=$(( (rem   % 3600) / 60 ))
    dtime=$(date -d "+${rem} seconds" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A")
    echo -e "  ${GREEN}● Local 2-core quota estimate${NC}"
    echo -e "  Total Used : ${WHITE}${h_used}h ${m_used}m${NC}"
    echo -e "  Remaining  : ${GREEN}${h_left}h ${m_left}m${NC} ${DIM}(of local ${quota_hours}h estimate)${NC}"
    echo -e "  Depletion  : ${DIM}${dtime}${NC}"
    echo -e "  ${DIM}GitHub billing is authoritative; 15 GB-month is storage quota, not traffic quota.${NC}"
    echo -e "  ${DIM}If quota blocks starts, mark the Codespace as Keep codespace so the same configs can survive until reset.${NC}"
}

show_resource_stats() {
    refresh_screen
    echo -e "\n  ${GREEN}● Live Resource Stats${NC}"
    local xpid cpu mem_kb mem_mb
    xpid=""
    if [[ -f "$XRAY_PID_FILE" ]]; then
        xpid=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
        xray_pid_matches "$xpid" || xpid=""
    fi
    if [[ -z "$xpid" ]]; then
        xpid=$(owned_xray_pids | head -1 || true)
    fi
    if [[ -n "$xpid" ]]; then
        read -r cpu mem_kb <<< "$(ps -p "$xpid" -o %cpu,rss --no-headers 2>/dev/null || echo '0 0')"
        mem_mb=$(awk "BEGIN{printf \"%.1f\",${mem_kb:-0}/1024}")
        echo -e "  Engine : ${GREEN}Active${NC} (PID $xpid)"
        echo -e "  CPU    : ${WHITE}${cpu}%${NC}"
        echo -e "  Memory : ${WHITE}${mem_mb} MB${NC}"
    else
        echo -e "  Engine : ${RED}Offline${NC}"
    fi
    echo ""
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

check_port_visibility() {
    if ! xray_listener_ready; then
        log_event WARN "check_port_visibility engine_not_running port=${XRAY_PORT}"
        refresh_screen
        echo -e "  ${RED}✖ Engine is not ready!${NC}"
        echo -e "  ${DIM}Start or reconnect the engine first (Option 3 or 6).${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
        return 1
    fi
    if ! ensure_codespace_port_public; then
        log_event WARN "check_port_visibility port_public_failed port=${XRAY_PORT}"
        refresh_screen
        echo -e "  ${YELLOW}⚠ Could not set Codespaces port ${XRAY_PORT} public.${NC}"
        echo -e "  ${DIM}Open the PORTS tab and set port ${XRAY_PORT} visibility to Public.${NC}\n"
        echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
        return 1
    fi
}

performance_profile_settings() {
    local profile="${1:-$PERFORMANCE_PROFILE}"
    case "$profile" in
        low_latency|latency)
            printf 'name=low_latency\nmaxUploadSize=3000000\nmaxConcurrentUploads=24\nhandshake=3\nconnIdle=600\nuplinkOnly=1\ndownlinkOnly=2\nbufferSize=512\nsniffQuic=true\nloglevel=warning\n'
            ;;
        streaming|video)
            printf 'name=streaming\nmaxUploadSize=4000000\nmaxConcurrentUploads=20\nhandshake=4\nconnIdle=900\nuplinkOnly=1\ndownlinkOnly=4\nbufferSize=768\nsniffQuic=true\nloglevel=warning\n'
            ;;
        unstable_mobile|mobile)
            printf 'name=unstable_mobile\nmaxUploadSize=1500000\nmaxConcurrentUploads=12\nhandshake=4\nconnIdle=900\nuplinkOnly=2\ndownlinkOnly=4\nbufferSize=512\nsniffQuic=false\nloglevel=warning\n'
            ;;
        low_overhead|minimal)
            printf 'name=low_overhead\nmaxUploadSize=1000000\nmaxConcurrentUploads=8\nhandshake=3\nconnIdle=420\nuplinkOnly=1\ndownlinkOnly=2\nbufferSize=256\nsniffQuic=false\nloglevel=error\n'
            ;;
        *)
            printf 'name=balanced\nmaxUploadSize=2000000\nmaxConcurrentUploads=16\nhandshake=3\nconnIdle=600\nuplinkOnly=1\ndownlinkOnly=2\nbufferSize=512\nsniffQuic=true\nloglevel=warning\n'
            ;;
    esac
}

generate_config() {
    uuidgen > "$UUID_FILE"
    local uuid; uuid=$(cat "$UUID_FILE")
    local profile_name max_upload_size max_concurrent_uploads handshake conn_idle uplink_only downlink_only buffer_size sniff_quic loglevel sniff_dest key value
    while IFS='=' read -r key value; do
        case "$key" in
            name) profile_name="$value" ;;
            maxUploadSize) max_upload_size="$value" ;;
            maxConcurrentUploads) max_concurrent_uploads="$value" ;;
            handshake) handshake="$value" ;;
            connIdle) conn_idle="$value" ;;
            uplinkOnly) uplink_only="$value" ;;
            downlinkOnly) downlink_only="$value" ;;
            bufferSize) buffer_size="$value" ;;
            sniffQuic) sniff_quic="$value" ;;
            loglevel) loglevel="$value" ;;
        esac
    done < <(performance_profile_settings "$PERFORMANCE_PROFILE")
    profile_name="${profile_name:-balanced}"
    max_upload_size="${max_upload_size:-2000000}"
    max_concurrent_uploads="${max_concurrent_uploads:-16}"
    handshake="${handshake:-3}"
    conn_idle="${conn_idle:-600}"
    uplink_only="${uplink_only:-1}"
    downlink_only="${downlink_only:-2}"
    buffer_size="${buffer_size:-512}"
    sniff_quic="${sniff_quic:-true}"
    loglevel="${loglevel:-warning}"
    sniff_dest='["http", "tls"]'
    [[ "$sniff_quic" == "true" ]] && sniff_dest='["http", "tls", "quic"]'
    local uuid_hash; uuid_hash=$(fingerprint_secret "$uuid")
    log_event INFO "generate_config uuid_hash=${uuid_hash} port=${XRAY_PORT} domain=${PORT_DOMAIN} profile=${profile_name}"
    cat > "$CONFIG_FILE" << JSONEOF
{
  "log": { "loglevel": "${loglevel}", "access": "none", "error": "${LOG_DIR}/xray-error.log" },
  "stats": {},
  "api": { "tag": "api", "services": ["StatsService"] },
  "policy": {
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true },
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true, "handshake": ${handshake}, "connIdle": ${conn_idle}, "uplinkOnly": ${uplink_only}, "downlinkOnly": ${downlink_only}, "bufferSize": ${buffer_size} } }
  },
  "dns": {
    "hosts": {
      "dns.google": ["8.8.8.8", "8.8.4.4"],
      "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]
    },
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
      { "address": "https+local://dns.google/dns-query", "queryStrategy": "UseIPv4", "timeoutMs": 2500 },
      { "address": "1.0.0.1", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
      { "address": "8.8.4.4", "queryStrategy": "UseIPv4", "timeoutMs": 2000 },
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableFallback": false,
    "disableFallbackIfMatch": false,
    "enableParallelQuery": true
  },
  "inbounds": [
    {
      "tag": "vless-in", "port": ${XRAY_PORT}, "listen": "0.0.0.0", "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${uuid}", "flow": "", "level": 0, "email": "user@G2rayXCodeLeafy" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp", "security": "none",
        "xhttpSettings": { "mode": "packet-up", "path": "/", "maxUploadSize": ${max_upload_size}, "maxConcurrentUploads": ${max_concurrent_uploads} }
      },
      "sniffing": { "enabled": true, "destOverride": ${sniff_dest}, "routeOnly": false }
    },
    { "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" }, "tag": "api" }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",   "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole",  "settings": { "response": { "type": "http" } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "inboundTag": ["api"],                                   "outboundTag": "api",    "type": "field" },
      { "type": "field", "ip":       ["geoip:private"],          "outboundTag": "block"  },
      { "type": "field", "protocol": ["bittorrent"],             "outboundTag": "block"  },
      { "type": "field", "domain":   ["geosite:category-ads-all"], "outboundTag": "block" }
    ]
  }
}
JSONEOF
    chmod 600 "$UUID_FILE" "$CONFIG_FILE" 2>/dev/null || true
    if start_xray && wait_for_port >/dev/null 2>&1; then
        log_event INFO "generate_config engine_started port=${XRAY_PORT}"
        echo -e "  ${GREEN}✔ Engine started on port ${XRAY_PORT}.${NC}"
    else
        log_event WARN "generate_config engine_maybe_not_bound port=${XRAY_PORT}"
        echo -e "  ${YELLOW}⚠ Engine may not have bound to port ${XRAY_PORT}.${NC}"
    fi
    if ensure_codespace_port_public; then
        log_event INFO "generate_config port_public port=${XRAY_PORT}"
    else
        log_event WARN "generate_config port_public_failed port=${XRAY_PORT}"
        echo -e "  ${YELLOW}⚠ Could not set Codespaces port ${XRAY_PORT} public. Check the PORTS tab.${NC}"
    fi
    refresh_config_exports >/dev/null 2>&1 || true
}

url_encode_query_value() {
    local value="$1" encoded="" i char hex
    local LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
        esac
    done
    printf '%s' "$encoded"
}

generate_link_for_address() {
    local address="$1" label_suffix="${2:-}" uuid path encoded_path
    uuid=$(cat "$UUID_FILE" 2>/dev/null) || { printf ''; return 1; }
    [[ -z "$uuid" ]] && { printf ''; return 1; }
    path=$(xhttp_config_path)
    [[ "$path" == /* ]] || path="/${path}"
    encoded_path=$(url_encode_query_value "$path")
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2&insecure=0&allowInsecure=0&type=xhttp&host=%s&path=%s&mode=packet-up#G2rayXCodeLeafy|%s' \
        "$uuid" "$address" "$CODESPACES_EDGE_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN" "$encoded_path" "${GITHUB_USER:-User}${label_suffix}"
}

generate_domain_link() {
    generate_link_for_address "$PORT_DOMAIN"
}

route_monitor_max_candidates() {
    local max="$ROUTE_MONITOR_MAX_CANDIDATES"
    [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=24
    (( max > 32 )) && max=32
    printf '%s' "$max"
}

route_failure_reason_for_status() {
    local code="${1:-0}" error="${2:-}" lowered
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
    lowered=$(printf '%s' "$error" | tr '[:upper:]' '[:lower:]')
    if xhttp_status_usable "$code"; then
        printf 'ready'
    elif [[ "$code" == "404" ]]; then
        printf 'route_settling_404'
    elif [[ "$code" == "0" ]]; then
        if [[ "$lowered" == *"timed"* || "$lowered" == *"timeout"* || "$lowered" == *"network"* || "$lowered" == *"connect"* ]]; then
            printf 'timeout_or_unreachable'
        else
            printf 'dns_tls_or_network_unreachable'
        fi
    elif (( code >= 500 )); then
        printf 'edge_or_origin_error'
    elif (( code == 401 || code == 403 )); then
        printf 'auth_or_visibility_blocked'
    else
        printf 'unexpected_http_status'
    fi
}

route_candidate_cooldown_active() {
    local ip="$1" now until reason
    [[ -s "$ROUTE_COOLDOWN_FILE" ]] || return 1
    now=$(date +%s)
    while IFS=$'\t' read -r until _ip reason; do
        [[ "$_ip" == "$ip" && "$until" =~ ^[0-9]+$ ]] || continue
        if (( now < until )); then
            return 0
        fi
    done < "$ROUTE_COOLDOWN_FILE"
    return 1
}

route_candidate_cooldown_bypass() {
    local ip="$1" source="${2:-}"
    [[ "$source" == "pinned" || "$source" == "manual" ]] && return 0
    [[ "$(pinned_route_value)" == "$ip" ]] && return 0
    route_file_contains "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip" && return 0
    return 1
}

record_route_candidate_cooldown() {
    local ip="$1" reason="${2:-unknown}" now until ttl tmp
    valid_ipv4 "$ip" || return 0
    ttl="$ROUTE_FAILURE_COOLDOWN_SEC"
    [[ "$ttl" =~ ^[0-9]+$ && "$ttl" -gt 0 ]] || ttl=180
    now=$(date +%s)
    until=$((now + ttl))
    tmp=$(mktemp "$DATA_DIR/route_cooldown.XXXXXX") || return 0
    awk -F '\t' -v OFS='\t' -v now="$now" -v target="$ip" '$1 ~ /^[0-9]+$/ && $1 > now && $2 != target {print}' "$ROUTE_COOLDOWN_FILE" 2>/dev/null > "$tmp" || true
    printf '%s\t%s\t%s\n' "$until" "$ip" "$reason" >> "$tmp"
    mv "$tmp" "$ROUTE_COOLDOWN_FILE" 2>/dev/null || rm -f "$tmp"
    chmod 600 "$ROUTE_COOLDOWN_FILE" 2>/dev/null || true
}

clear_route_candidate_cooldown() {
    local ip="$1" now tmp
    valid_ipv4 "$ip" || return 0
    [[ -s "$ROUTE_COOLDOWN_FILE" ]] || return 0
    now=$(date +%s)
    tmp=$(mktemp "$DATA_DIR/route_cooldown.XXXXXX") || return 0
    awk -F '\t' -v OFS='\t' -v now="$now" -v target="$ip" \
        '$1 ~ /^[0-9]+$/ && $1 > now && $2 != target {print}' "$ROUTE_COOLDOWN_FILE" 2>/dev/null > "$tmp" || true
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$ROUTE_COOLDOWN_FILE" 2>/dev/null || rm -f "$tmp"
        chmod 600 "$ROUTE_COOLDOWN_FILE" 2>/dev/null || true
    else
        rm -f "$tmp" "$ROUTE_COOLDOWN_FILE" 2>/dev/null || true
    fi
}

update_route_candidate_stats() {
    local ip="$1" code="${2:-0}" ms="${3:-0}" source="${4:-probe}" reason="${5:-}" usable=false checked tmp
    valid_ipv4 "$ip" || return 0
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=0
    [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
    [[ -n "$reason" ]] || reason=$(route_failure_reason_for_status "$code")
    xhttp_status_usable "$code" && usable=true
    checked=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
    mkdir -p "$DATA_DIR" 2>/dev/null || true
    [[ -f "$ROUTE_STATS_FILE" ]] || : > "$ROUTE_STATS_FILE"
    tmp=$(mktemp "$DATA_DIR/route_stats.XXXXXX") || return 1
    awk -F '\t' -v OFS='\t' \
        -v target="$ip" -v code="$code" -v ms="$ms" -v usable="$usable" -v checked="$checked" -v source="$source" -v reason="$reason" '
        function emit(ip, samples, successes, failures, avg, min, max, last_ms, last_code, last_usable, last_checked, ewma, recent_failures, last_reason) {
            if (samples < 1) samples = 1
            printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%s\n",
                ip, samples, successes, failures, avg, min, max,
                last_ms, last_code, last_usable, last_checked,
                ewma, recent_failures, last_reason
        }
        $1 == target {
            found = 1
            samples = ($2 ~ /^[0-9]+$/) ? $2 + 1 : 1
            successes = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
            failures = ($4 ~ /^[0-9]+$/) ? $4 + 0 : 0
            avg = ($5 ~ /^[0-9]+$/) ? $5 + 0 : 0
            min = ($6 ~ /^[0-9]+$/) ? $6 + 0 : 0
            max = ($7 ~ /^[0-9]+$/) ? $7 + 0 : 0
            ewma = ($12 ~ /^[0-9]+$/) ? $12 + 0 : avg
            recent_failures = ($13 ~ /^[0-9]+$/) ? $13 + 0 : 0
            if (usable == "true") {
                successes += 1
                avg = (successes == 1) ? ms : int((((avg * (successes - 1)) + ms) / successes) + 0.5)
                min = (min == 0 || ms < min) ? ms : min
                max = (ms > max) ? ms : max
                ewma = (ewma == 0) ? ms : int(((ewma * 7 + ms * 3) / 10) + 0.5)
                recent_failures = int((recent_failures * 7) / 10)
            } else {
                failures += 1
                penalty_ms = (ms > 0) ? ms : 9999
                ewma = (ewma == 0) ? penalty_ms : int(((ewma * 7 + penalty_ms * 3) / 10) + 0.5)
                recent_failures += 1
            }
            emit(target, samples, successes, failures, avg, min, max, ms, code, usable, checked, ewma, recent_failures, reason)
            next
        }
        NF >= 1 { print }
        END {
            if (!found) {
                samples = 1
                successes = (usable == "true") ? 1 : 0
                failures = (usable == "true") ? 0 : 1
                avg = (usable == "true") ? ms : 0
                min = (usable == "true") ? ms : 0
                max = (usable == "true") ? ms : 0
                ewma = (usable == "true") ? ms : ((ms > 0) ? ms : 9999)
                recent_failures = (usable == "true") ? 0 : 1
                emit(target, samples, successes, failures, avg, min, max, ms, code, usable, checked, ewma, recent_failures, reason)
            }
        }
    ' "$ROUTE_STATS_FILE" 2>/dev/null > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$ROUTE_STATS_FILE" || { rm -f "$tmp"; return 1; }
    chmod 600 "$ROUTE_STATS_FILE" 2>/dev/null || true
}

record_route_candidate_health() {
    local ip="$1" code="$2" ms="$3" source="${4:-probe}" reason="${5:-}" usable=false checked
    checked=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
    [[ -n "$reason" ]] || reason=$(route_failure_reason_for_status "$code")
    xhttp_status_usable "$code" && usable=true
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$checked" "$ip" "${code:-0}" "${ms:-0}" "$usable" "$source" "$reason" >> "${route_health_tmp:-$ROUTE_HEALTH_FILE}"
    update_route_candidate_stats "$ip" "$code" "$ms" "$source" "$reason" || true
    if [[ "$reason" == "timeout_or_unreachable" || "$reason" == "dns_tls_or_network_unreachable" ]]; then
        record_route_candidate_cooldown "$ip" "$reason"
    fi
}

save_last_good_route() {
    local ip="$1" code="${2:-0}" ms="${3:-0}" source="${4:-probe}" checked content
    [[ -n "$ip" ]] || return 0
    checked=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
    content=$(printf 'ip=%s\nhttp_status=%s\nlatency_ms=%s\nsource=%s\nchecked_at=%s\n' \
        "$ip" "$code" "$ms" "$source" "$checked")
    _atomic_write "$LAST_GOOD_ROUTE_FILE" "$content"
    chmod 600 "$LAST_GOOD_ROUTE_FILE" 2>/dev/null || true
    log_event INFO "last_good_route saved ip=${ip} http=${code} latency_ms=${ms} source=${source}"
}

last_good_route_value() {
    [[ -f "$LAST_GOOD_ROUTE_FILE" ]] || return 0
    awk -F= '$1 == "ip" {print $2; exit}' "$LAST_GOOD_ROUTE_FILE" 2>/dev/null || true
}

last_good_route_fresh_value() {
    local age checked checked_epoch max now ip
    [[ -f "$LAST_GOOD_ROUTE_FILE" ]] || return 0
    max="$LAST_GOOD_ROUTE_MAX_AGE_SEC"
    [[ "$max" =~ ^[0-9]+$ ]] || max=1800
    (( max > 0 )) || return 0
    checked=$(awk -F= '$1 == "checked_at" {print $2; exit}' "$LAST_GOOD_ROUTE_FILE" 2>/dev/null || true)
    if [[ -n "$checked" ]] && checked_epoch=$(date -u -d "$checked" +%s 2>/dev/null); then
        now=$(date -u +%s 2>/dev/null || printf '0')
        [[ "$now" =~ ^[0-9]+$ ]] || now=0
        age=$(( now - checked_epoch ))
        (( age >= 0 )) || return 0
    else
        age=$(file_age_sec "$LAST_GOOD_ROUTE_FILE")
    fi
    (( age <= max )) || return 0
    ip=$(last_good_route_value)
    valid_ipv4 "$ip" || return 0
    candidate_blacklisted "$ip" && return 0
    printf '%s\n' "$ip"
}

last_good_route_summary() {
    if [[ ! -s "$LAST_GOOD_ROUTE_FILE" ]]; then
        printf 'Last good route : none recorded\n'
        return 0
    fi
    awk -F= '
        $1 == "ip" {ip=$2}
        $1 == "http_status" {code=$2}
        $1 == "latency_ms" {ms=$2}
        $1 == "source" {source=$2}
        $1 == "checked_at" {checked=$2}
        END {
            printf "Last good route : %s HTTP %s %sms source=%s checked=%s\n",
                (ip ? ip : "unknown"), (code ? code : "unknown"),
                (ms ? ms : "0"), (source ? source : "unknown"),
                (checked ? checked : "unknown")
        }
    ' "$LAST_GOOD_ROUTE_FILE" 2>/dev/null
}

route_probe_jitter_sleep() {
    local delay="${ROUTE_PROBE_JITTER_SEC:-0}"
    [[ "$delay" == "0" || "$delay" == "0.0" ]] && return 0
    sleep "$delay" 2>/dev/null || true
}

probe_route_candidate_worker() {
    local ip="$1" source="$2" outfile="$3" code ms reason
    route_probe_jitter_sleep
    read -r code ms reason < <(xhttp_probe_metrics external "$ip")
    [[ -n "$reason" ]] || reason=$(route_failure_reason_for_status "$code")
    printf '%s\t%s\t%s\t%s\t%s\n' "$ip" "${source:-probe}" "${code:-0}" "${ms:-0}" "$reason" > "$outfile"
}

route_refresh_probe_candidates() {
    local candidates="$1" max="${2:-24}"
    [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=24
    printf '%s\n' "$candidates" | awk -F '\t' -v max="$max" '
        function store(bucket, line, ip) {
            if (bucket == 1) { b1[++n1] = line; i1[n1] = ip }
            else if (bucket == 2) { b2[++n2] = line; i2[n2] = ip }
            else if (bucket == 3) { b3[++n3] = line; i3[n3] = ip }
            else { b4[++n4] = line; i4[n4] = ip }
        }
        function emit(line, ip) {
            if (count >= max || ip == "" || seen[ip]++) return
            print line
            count++
        }
        NF >= 2 {
            if ($1 == "pinned" || $1 == "manual") store(1, $0, $2)
            else if ($1 == "cache") store(3, $0, $2)
            else if ($1 == "builtin") store(4, $0, $2)
            else store(2, $0, $2)
        }
        END {
            for (idx = 1; idx <= n1; idx++) emit(b1[idx], i1[idx])
            for (idx = 1; idx <= n2; idx++) emit(b2[idx], i2[idx])
            for (idx = 1; idx <= n3; idx++) emit(b3[idx], i3[idx])
            for (idx = 1; idx <= n4; idx++) emit(b4[idx], i4[idx])
        }
    '
}

refresh_route_candidate_health() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local candidates probe_candidates source ip ip_probe ip_ms reason count=0 max route_health_tmp best_ip="" best_code=0 best_ms=99999999
    local concurrency pids=() files=() active=0 file result probed_count=0
    max=$(route_monitor_max_candidates)
    concurrency="$ROUTE_PROBE_CONCURRENCY"
    [[ "$concurrency" =~ ^[0-9]+$ && "$concurrency" -gt 0 ]] || concurrency=4
    (( concurrency > 8 )) && concurrency=8
    candidates=$(resolve_domain_ips_with_sources "$PORT_DOMAIN" || true)
    [[ -n "$candidates" ]] || return 0
    route_health_tmp=$(mktemp "$DATA_DIR/route_health.XXXXXX") || return 1

    collect_route_probe_batch() {
        local idx f row _ip _source _code _ms _reason
        for idx in "${!pids[@]}"; do
            wait "${pids[$idx]}" 2>/dev/null || true
            f="${files[$idx]}"
            [[ -s "$f" ]] || { rm -f "$f"; continue; }
            row=$(cat "$f" 2>/dev/null || true)
            rm -f "$f" 2>/dev/null || true
            IFS=$'\t' read -r _ip _source _code _ms _reason <<< "$row"
            valid_ipv4 "$_ip" || continue
            probed_count=$((probed_count + 1))
            record_route_candidate_health "$_ip" "$_code" "$_ms" "$_source" "$_reason"
            if xhttp_status_usable "$_code" && [[ "$_ms" =~ ^[0-9]+$ ]] && (( _ms < best_ms )); then
                best_ip="$_ip"
                best_code="$_code"
                best_ms="$_ms"
            fi
        done
        pids=()
        files=()
        active=0
    }

    probe_candidates=$(route_refresh_probe_candidates "$candidates" "$max")
    while IFS=$'\t' read -r source ip; do
        [[ -n "$ip" ]] || continue
        candidate_blacklisted "$ip" && continue
        route_candidate_cooldown_active "$ip" && ! route_candidate_cooldown_bypass "$ip" "$source" && continue
        file=$(mktemp "$DATA_DIR/route_probe.XXXXXX") || continue
        probe_route_candidate_worker "$ip" "$source" "$file" &
        pids+=("$!")
        files+=("$file")
        active=$((active + 1))
        count=$((count + 1))
        if (( active >= concurrency )); then
            collect_route_probe_batch
        fi
        (( count >= max )) && break
    done <<< "$probe_candidates"
    (( active > 0 )) && collect_route_probe_batch
    if (( probed_count == 0 )); then
        rm -f "$route_health_tmp" 2>/dev/null || true
        log_event WARN "route_candidate_monitor skipped_all_candidates count=${count} max=${max}"
        return 0
    fi
    if [[ -z "$best_ip" && -s "$ROUTE_HEALTH_FILE" ]] \
        && awk -F '\t' '$5 == "true" { found=1 } END { exit found ? 0 : 1 }' "$ROUTE_HEALTH_FILE" 2>/dev/null; then
        rm -f "$route_health_tmp" 2>/dev/null || true
        log_event WARN "route_candidate_monitor all_unusable_preserved_cache count=${count} max=${max}"
        return 0
    fi
    mv "$route_health_tmp" "$ROUTE_HEALTH_FILE"
    chmod 600 "$ROUTE_HEALTH_FILE" 2>/dev/null || true
    [[ -n "$best_ip" ]] && save_last_good_route "$best_ip" "$best_code" "$best_ms" "route_candidate_monitor"
    log_event INFO "route_candidate_monitor refreshed count=${count} max=${max}"
}

route_health_cache_fresh() {
    local age
    [[ -s "$ROUTE_HEALTH_FILE" ]] || return 1
    age=$(file_age_sec "$ROUTE_HEALTH_FILE")
    [[ "$ROUTE_HEALTH_TTL_SEC" =~ ^[0-9]+$ ]] || ROUTE_HEALTH_TTL_SEC=300
    (( age <= ROUTE_HEALTH_TTL_SEC ))
}

cached_usable_fallback_ips() {
    [[ -s "$ROUTE_HEALTH_FILE" ]] || return 1
    local last_good pinned stats_input
    pinned=$(pinned_route_value)
    last_good=$(last_good_route_fresh_value)
    stats_input="$ROUTE_STATS_FILE"
    [[ -s "$stats_input" ]] || stats_input="/dev/null"
    awk -F '\t' -v pinned="$pinned" -v last_good="$last_good" -v stats_file="$stats_input" '
        FILENAME == stats_file {
            if (NF >= 11) {
                samples[$1] = ($2 ~ /^[0-9]+$/) ? $2 + 0 : 0
                successes[$1] = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
                avg[$1] = ($5 ~ /^[0-9]+$/) ? $5 + 0 : 0
                latest[$1] = ($8 ~ /^[0-9]+$/) ? $8 + 0 : 0
                ewma[$1] = ($12 ~ /^[0-9]+$/) ? $12 + 0 : avg[$1]
                recent_failures[$1] = ($13 ~ /^[0-9]+$/) ? $13 + 0 : 0
            }
            next
        }
        NF >= 5 && $5 == "true" {
            ip = $2
            latency = ($4 ~ /^[0-9]+$/) ? $4 + 0 : 99999999
            total = ((ip in samples) && samples[ip] > 0) ? samples[ip] : 1
            ok = (ip in successes) ? successes[ip] : 1
            recent = (ip in recent_failures) ? recent_failures[ip] : 0
            success_penalty = int(((total - ok) * 1000) / total) + (recent * 75)
            avg_ms = ((ip in avg) && avg[ip] > 0) ? avg[ip] : latency
            score_ms = ((ip in ewma) && ewma[ip] > 0) ? ewma[ip] : avg_ms
            last_ms = ((ip in latest) && latest[ip] > 0) ? latest[ip] : latency
            pinned_rank = (ip == pinned) ? 0 : 1
            last_good_rank = (ip == last_good) ? 0 : 1
            printf "%d\t%04d\t%08d\t%08d\t%d\t%s\t%s\t%s\n",
                pinned_rank, success_penalty, score_ms, last_ms, last_good_rank, ip, $3, $4
        }
    ' "$stats_input" "$ROUTE_HEALTH_FILE" 2>/dev/null | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
        | while IFS=$'\t' read -r _pinned _success _avg _latest _last_good ip _code _ms; do
            valid_ipv4 "$ip" || continue
            candidate_blacklisted "$ip" && continue
            printf '%s\n' "$ip"
        done | awk '!seen[$0]++ {print}'
}

route_candidate_health_summary() {
    local pinned stats_input
    pinned=$(pinned_route_value)
    printf 'Pinned route : %s\n' "${pinned:-none}"
    if [[ ! -s "$ROUTE_HEALTH_FILE" ]]; then
        printf 'Last refresh : none recorded\n'
        printf 'Candidates   : no cached candidate route probes yet\n'
        return 0
    fi

    local last
    last=$(awk -F '\t' 'END{print $1}' "$ROUTE_HEALTH_FILE" 2>/dev/null)
    printf 'Last refresh : %s\n' "${last:-unknown}"
    printf 'Candidates   : pinned first, then best reliable usable routes\n'
    stats_input="$ROUTE_STATS_FILE"
    [[ -s "$stats_input" ]] || stats_input="/dev/null"
    awk -F '\t' -v pinned="$pinned" -v stats_file="$stats_input" '
        FILENAME == stats_file {
            if (NF >= 11) {
                samples[$1] = ($2 ~ /^[0-9]+$/) ? $2 + 0 : 0
                successes[$1] = ($3 ~ /^[0-9]+$/) ? $3 + 0 : 0
                avg[$1] = ($5 ~ /^[0-9]+$/) ? $5 + 0 : 0
                latest[$1] = ($8 ~ /^[0-9]+$/) ? $8 + 0 : 0
                ewma[$1] = ($12 ~ /^[0-9]+$/) ? $12 + 0 : avg[$1]
                recent_failures[$1] = ($13 ~ /^[0-9]+$/) ? $13 + 0 : 0
                last_reason[$1] = (NF >= 14 && $14 != "") ? $14 : "unknown"
            }
            next
        }
        NF >= 5 {
            ip = $2
            usable_rank = ($5 == "true") ? 0 : 1
            latency = ($4 ~ /^[0-9]+$/) ? $4 + 0 : 99999999
            total = ((ip in samples) && samples[ip] > 0) ? samples[ip] : 1
            ok = (ip in successes) ? successes[ip] : (($5 == "true") ? 1 : 0)
            recent = (ip in recent_failures) ? recent_failures[ip] : 0
            success_penalty = int(((total - ok) * 1000) / total) + (recent * 75)
            avg_ms = ((ip in avg) && avg[ip] > 0) ? avg[ip] : latency
            score_ms = ((ip in ewma) && ewma[ip] > 0) ? ewma[ip] : avg_ms
            last_ms = ((ip in latest) && latest[ip] > 0) ? latest[ip] : latency
            pinned_rank = (ip == pinned) ? 0 : 1
            source = (NF >= 6 && $6 != "") ? $6 : "unknown"
            reason = (NF >= 7 && $7 != "") ? $7 : ((ip in last_reason) ? last_reason[ip] : "unknown")
            line = sprintf("%-15s HTTP %-3s last=%sms avg=%sms success=%s/%s recent=%sms recent_fail=%s usable=%s source=%s reason=%s",
                ip, $3, last_ms, avg_ms, ok, total, score_ms, recent, $5, source, reason)
            printf "%d\t%d\t%04d\t%08d\t%08d\t%s\t%s\n",
                pinned_rank, usable_rank, success_penalty, score_ms, last_ms, ip, line
        }
    ' "$stats_input" "$ROUTE_HEALTH_FILE" 2>/dev/null | sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
        | while IFS=$'\t' read -r _pinned _usable _success _avg _latest ip line; do
            candidate_blacklisted "$ip" && continue
            printf '%s\n' "$line"
        done
}

show_route_candidate_manager() {
    local choice ip
    while true; do
        refresh_screen
        echo -e "\n  ${RED}Route Candidates${NC}\n"
        echo -e "  ${WHITE}${B}Manual and pinned routes${NC}"
        route_candidate_state_summary | sed 's/^/  /'
        echo ""
        echo -e "  ${WHITE}${B}Measured candidates${NC}"
        route_candidate_health_summary | sed 's/^/  /'
        echo ""
        echo -e "  ${RED}1)${NC} Refresh Route Probes"
        echo -e "  ${RED}2)${NC} Add Manual IPv4 Candidate"
        echo -e "  ${RED}3)${NC} Pin Preferred Route"
        echo -e "  ${RED}4)${NC} Blacklist Bad Route"
        echo -e "  ${RED}5)${NC} Remove Manual Route"
        echo -e "  ${RED}6)${NC} Unblacklist Route"
        echo -e "  ${RED}7)${NC} Reset Route Health Cache"
        echo -e "  ${RED}8)${NC} Reset All Route Preferences"
        echo -e "  ${RED}9)${NC} Refresh Exports"
        echo -e "  ${RED}0)${NC} Return"
        echo -ne "  ${RED}Select:${NC} "
        read -r choice || return 0
        case "$choice" in
            1)
                refresh_route_candidate_health >/dev/null 2>&1 || true
                echo -e "  ${GREEN}Route probes refreshed.${NC}"; sleep 1
                ;;
            2)
                echo -ne "  ${GREEN}Manual IPv4:${NC} "
                read -r ip || continue
                if add_manual_route_candidate "$ip"; then
                    refresh_route_candidate_health >/dev/null 2>&1 || true
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}Added.${NC}"
                else
                    echo -e "  ${RED}Invalid, duplicate, or blacklisted IPv4.${NC}"
                fi
                sleep 1
                ;;
            3)
                echo -ne "  ${GREEN}IPv4 to pin:${NC} "
                read -r ip || continue
                if pin_route_candidate "$ip"; then
                    refresh_route_candidate_health >/dev/null 2>&1 || true
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}Pinned preferred route.${NC}"
                else
                    echo -e "  ${RED}Invalid or blacklisted IPv4.${NC}"
                fi
                sleep 1
                ;;
            4)
                echo -ne "  ${YELLOW}IPv4 to blacklist:${NC} "
                read -r ip || continue
                if blacklist_route_candidate "$ip"; then
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${YELLOW}Blacklisted.${NC}"
                else
                    echo -e "  ${RED}Invalid IPv4.${NC}"
                fi
                sleep 1
                ;;
            5)
                echo -ne "  ${GREEN}Manual IPv4 to remove:${NC} "
                read -r ip || continue
                if remove_manual_route_candidate "$ip"; then
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}Removed.${NC}"
                else
                    echo -e "  ${RED}Invalid IPv4.${NC}"
                fi
                sleep 1
                ;;
            6)
                echo -ne "  ${GREEN}IPv4 to unblacklist:${NC} "
                read -r ip || continue
                if unblacklist_route_candidate "$ip"; then
                    refresh_route_candidate_health >/dev/null 2>&1 || true
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}Unblacklisted.${NC}"
                else
                    echo -e "  ${RED}Invalid IPv4 or route is not blacklisted.${NC}"
                fi
                sleep 1
                ;;
            7)
                echo -ne "  ${YELLOW}Reset measured route health cache only? (y/n):${NC} "
                read -r ip || continue
                if [[ "$ip" =~ ^[Yy]$ ]]; then
                    reset_route_candidate_cache
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}Route health cache reset. Manual, pinned, and blacklisted routes were kept.${NC}"
                    sleep 1
                fi
                ;;
            8)
                echo -ne "  ${YELLOW}Reset manual routes, blacklist, pin, and route cache? (y/n):${NC} "
                read -r ip || continue
                if [[ "$ip" =~ ^[Yy]$ ]]; then
                    reset_route_candidate_state
                    refresh_config_exports >/dev/null 2>&1 || true
                    echo -e "  ${GREEN}All route preferences and cached measurements reset.${NC}"
                    sleep 1
                fi
                ;;
            9)
                refresh_route_candidate_health >/dev/null 2>&1 || true
                refresh_config_exports >/dev/null 2>&1 || true
                echo -e "  ${GREEN}Routes and exports refreshed.${NC}"; sleep 1
                ;;
            0) return 0 ;;
            *) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

show_live_monitor() {
    local choice tick=1 local_code local_ms edge_code edge_ms engine listener
    while true; do
        if [[ -f "$CONFIG_FILE" && $((tick % 6)) -eq 0 ]]; then
            refresh_route_candidate_health >/dev/null 2>&1 || true
        fi
        read -r local_code local_ms _probe_reason < <(xhttp_probe_metrics local)
        read -r edge_code edge_ms _probe_reason < <(xhttp_probe_metrics external)
        xray_running && engine="running" || engine="stopped"
        is_port_open && listener="open" || listener="closed"
        refresh_screen
        echo -e "\n  ${RED}Live Monitor${NC}"
        echo -e "  ${DIM}Refreshes every 10 seconds. Press Enter or q to return.${NC}\n"
        echo -e "  Engine        : ${WHITE}${engine}${NC}"
        echo -e "  Listener      : ${WHITE}${listener}${NC}"
        echo -e "  Local XHTTP   : HTTP ${local_code:-0} ${local_ms:-0}ms usable=$(xhttp_status_usable "$local_code" && printf true || printf false)"
        echo -e "  Edge XHTTP    : HTTP ${edge_code:-0} ${edge_ms:-0}ms usable=$(xhttp_status_usable "$edge_code" && printf true || printf false)"
        echo -e "  Supervisor    : ${WHITE}$(background_supervisor_status)${NC}"
        echo -e "  Self-heal     : ${WHITE}$(self_heal_state_summary)${NC}\n"
        echo -e "  ${WHITE}${B}Best Route Candidates${NC}"
        route_candidate_health_summary | sed 's/^/  /'
        echo -e "\n  ${WHITE}${B}Route Settling${NC}"
        route_settling_history_summary | sed 's/^/  /'
        echo -e "\n  ${WHITE}${B}Recent Events${NC}"
        if [[ -s "$LOG_FILE" ]]; then
            tail -n 8 "$LOG_FILE" | sed 's/^/  /'
        else
            echo -e "  ${DIM}No events logged yet.${NC}"
        fi
        echo -ne "\n  ${DIM}Press Enter/q to return, or wait to refresh...${NC} "
        if IFS= read -r -t 10 choice; then
            [[ -z "$choice" || "$choice" =~ ^[Qq]$ ]] && return 0
        fi
        tick=$((tick + 1))
    done
}

safe_max_fallback_links() {
    local max="${1:-$MAX_FALLBACK_LINKS}"
    [[ "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || max=20
    (( max > 64 )) && max=64
    printf '%s' "$max"
}

usable_fallback_ips() {
    local ip ip_probe ip_ms reason count=0 max_links candidates usable probe_cap min_probe_cap probed=0 emitted=""
    max_links=$(safe_max_fallback_links)
    probe_cap=$(route_monitor_max_candidates)
    min_probe_cap=$(( max_links * 3 ))
    (( probe_cap < min_probe_cap )) && probe_cap=$min_probe_cap
    (( probe_cap > 64 )) && probe_cap=64
    if ! route_health_cache_fresh; then
        refresh_route_candidate_health >/dev/null 2>&1 || true
    fi
    if route_health_cache_fresh && cached_usable_fallback_ips >/dev/null 2>&1; then
        while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            printf '%s\n' "$ip"
            emitted="${emitted} ${ip}"
            usable=true
            count=$((count + 1))
            (( count >= max_links )) && return 0
        done < <(cached_usable_fallback_ips)
    fi

    candidates=$(resolve_domain_ips "$PORT_DOMAIN" || true)
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        [[ " $emitted " == *" $ip "* ]] && continue
        candidate_blacklisted "$ip" && continue
        route_candidate_cooldown_active "$ip" && ! route_candidate_cooldown_bypass "$ip" && continue
        if (( probed >= probe_cap )); then
            log_event WARN "fallback_route_filter probe_cap_reached probed=${probed} max=${probe_cap}"
            break
        fi
        probed=$((probed + 1))
        read -r ip_probe ip_ms reason < <(xhttp_probe_metrics external "$ip")
        [[ -n "$reason" ]] || reason=$(route_failure_reason_for_status "$ip_probe")
        update_route_candidate_stats "$ip" "$ip_probe" "$ip_ms" "live_fallback_probe" "$reason" || true
        if xhttp_status_usable "$ip_probe"; then
            printf '%s\n' "$ip"
            emitted="${emitted} ${ip}"
            save_last_good_route "$ip" "$ip_probe" "$ip_ms" "live_fallback_probe"
            usable=true
            count=$((count + 1))
        else
            [[ "$reason" == "timeout_or_unreachable" || "$reason" == "dns_tls_or_network_unreachable" ]] \
                && record_route_candidate_cooldown "$ip" "$reason"
            log_event WARN "fallback_route_unusable ip=${ip} xhttp_probe=${ip_probe:-0} xhttp_probe_ms=${ip_ms:-0} reason=${reason}"
        fi
        (( count >= max_links )) && return 0
    done <<< "$candidates"
    if [[ "${usable:-false}" != true ]]; then
        log_event WARN "fallback_route_filter no-usable-probes action=domain-only"
    fi
}

generate_ip_link() {
    local address; address=$(usable_fallback_ips | head -1 || true)
    [[ -n "$address" ]] || return 1
    generate_link_for_address "$address" "-ip1"
}

generate_ip_links() {
    local address index=1 printed=false max_links
    max_links=$(safe_max_fallback_links)
    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        (( index > max_links )) && break
        [[ "$printed" == true ]] && printf '\n'
        generate_link_for_address "$address" "-ip${index}"
        printed=true
        index=$(( index + 1 ))
    done < <(usable_fallback_ips)
}

generate_ordered_links() {
    local domain_link ip_links
    ip_links=$(generate_ip_links || true)
    printf '%s\n' "$ip_links" | awk 'NF'
    domain_link=$(generate_domain_link || true)
    if [[ -n "$domain_link" ]] && ! printf '%s\n' "$ip_links" | grep -Fxq "$domain_link"; then
        printf '%s\n' "$domain_link"
    fi
}

write_config_metadata() {
    local count="$1" hash="$2" generated max_links
    max_links=$(safe_max_fallback_links)
    generated=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    cat > "$CONFIG_META_FILE" <<JSON
{
  "generated_at": "$(json_escape "$generated")",
  "codespace": "$(json_escape "$CODESPACE_NAME")",
  "domain": "$(json_escape "$PORT_DOMAIN")",
  "port": ${XRAY_PORT},
  "config_count": ${count:-0},
  "max_fallback_links": ${max_links},
  "hash": "$(json_escape "$hash")",
  "mobile_config_file": "$(json_escape "$MOBILE_CONFIG_FILE")",
  "subscription_file": "$(json_escape "$SUBSCRIPTION_FILE")",
  "subscription_scope": "local_codespace_only",
  "performance_profile": "$(json_escape "$PERFORMANCE_PROFILE")",
  "low_overhead": $(low_overhead_enabled && printf true || printf false),
  "latency_focus": $(latency_focus_enabled && printf true || printf false)
}
JSON
    chmod 600 "$CONFIG_META_FILE" 2>/dev/null || true
}

write_config_exports_from_links() {
    local links encoded count hash
    links=$(printf '%s\n' "$@" | awk 'NF')
    [[ -n "$links" ]] || return 1
    _atomic_write "$MOBILE_CONFIG_FILE" "$links"
    if command -v base64 >/dev/null 2>&1; then
        encoded=$(printf '%s\n' "$links" | base64 | tr -d '\n')
        _atomic_write "$SUBSCRIPTION_FILE" "$encoded"
    fi
    count=$(printf '%s\n' "$links" | awk 'NF {c++} END {print c+0}')
    hash=$(fingerprint_secret "$links")
    write_config_metadata "$count" "$hash"
    log_event INFO "config_exports refreshed count=${count} hash=${hash}"
}

refresh_config_exports() {
    [[ -f "$UUID_FILE" ]] || return 0
    local link_array=()
    mapfile -t link_array < <(generate_ordered_links | awk 'NF' || true)
    ((${#link_array[@]})) || return 1
    write_config_exports_from_links "${link_array[@]}"
}

generate_link() {
    generate_domain_link
}

generate_links_for_display() {
    local uuid; uuid=$(cat "$UUID_FILE" 2>/dev/null) || { printf ''; return 1; }
    [[ -z "$uuid" ]] && { printf ''; return 1; }
    printf '%s\n' "$(generate_domain_link)"
    generate_ip_links
}

log_diagnostic_snapshot() {
    local reason="${1:-diagnostics}" local_probe local_ms edge_probe edge_ms engine listener supervisor ts
    local waker_url waker_codespace waker_fp waker_at
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    read -r local_probe local_ms _probe_reason < <(xhttp_probe_metrics local)
    read -r edge_probe edge_ms _probe_reason < <(xhttp_probe_metrics external)
    xray_running && engine=running || engine=stopped
    is_port_open && listener=open || listener=closed
    supervisor=$(background_supervisor_status | tr '\r\n' ' ' | cut -c1-180)
    log_event INFO "diagnostic_snapshot reason=${reason} engine=${engine} listener=${listener} local_probe=${local_probe:-0} local_ms=${local_ms:-0} edge_probe=${edge_probe:-0} edge_ms=${edge_ms:-0} supervisor=${supervisor:-unknown} last_good=$(last_good_route_value)"
    waker_url=$(waker_metadata_value worker_url)
    waker_codespace=$(waker_metadata_value codespace_name)
    waker_fp=$(waker_metadata_value wake_secret_fingerprint)
    waker_at=$(waker_metadata_value configured_at)
    rotate_log_file "$DIAGNOSTIC_LOG_FILE"
    {
        printf '===== Diagnostic Snapshot %s =====\n' "$ts"
        printf 'reason: %s\n' "$reason"
        printf 'identity: %s\n' "$CODESPACE_NAME"
        printf 'domain: %s\n' "$PORT_DOMAIN"
        printf 'port: %s\n' "$XRAY_PORT"
        printf 'engine: %s\n' "$engine"
        printf 'listener: %s\n' "$listener"
        printf 'local_xhttp_options: HTTP %s latency_ms=%s usable=%s\n' "${local_probe:-0}" "${local_ms:-0}" "$(xhttp_status_usable "$local_probe" && printf true || printf false)"
        printf 'edge_xhttp_options: HTTP %s latency_ms=%s usable=%s\n' "${edge_probe:-0}" "${edge_ms:-0}" "$(xhttp_status_usable "$edge_probe" && printf true || printf false)"
        printf 'supervisor: %s\n' "${supervisor:-unknown}"
        printf 'self_heal: %s\n' "$(self_heal_state_summary)"
        printf 'resume_gap:\n'
        resume_gap_summary | sed 's/^/  /'
        printf 'last_known_state:\n'
        last_known_state_summary | sed 's/^/  /'
        printf 'external_waker:\n'
        if [[ -n "$waker_url" ]]; then
            printf '  status: configured\n'
            printf '  worker_url: %s\n' "$waker_url"
            printf '  codespace: %s\n' "${waker_codespace:-$CODESPACE_NAME}"
            printf '  secret: fingerprint=%s raw_secret_stored=false\n' "${waker_fp:-unknown}"
            printf '  last_setup: %s\n' "${waker_at:-unknown}"
        else
            printf '  status: not configured\n'
        fi
        printf 'last_good_route:\n'
        last_good_route_summary | sed 's/^/  /'
        printf 'route_settling_history:\n'
        route_settling_history_summary | sed 's/^/  /'
        printf 'recent_events:\n'
        if [[ -s "$LOG_FILE" ]]; then
            tail -n 12 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
        else
            printf '  none\n'
        fi
        printf '\n'
    } >> "$DIAGNOSTIC_LOG_FILE" 2>/dev/null || true
    chmod 600 "$DIAGNOSTIC_LOG_FILE" 2>/dev/null || true
}

redact_sensitive_text() {
    sed -E \
        -e "s#vless://[^[:space:]\"'{},]+#<vless-redacted>#g" \
        -e "s#(\"?authorization\"?[[:space:]]*:[[:space:]]*\"?bearer[[:space:]]+)[^\"'[:space:],}]+#\\1<bearer-redacted>#Ig" \
        -e "s#(\"?GITHUB_TOKEN\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"'[:space:],}]+#\\1<github-token-redacted>#Ig" \
        -e "s#(\"?token\"?[[:space:]]*:[[:space:]]*\"?)[^\"'[:space:],}]+#\\1<token-redacted>#Ig" \
        -e "s#(\"?WAKE_SECRET\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"'[:space:],}]+#\\1<wake-secret-redacted>#Ig" \
        -e "s#(\"?wake_secret\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"'[:space:],}]+#\\1<wake-secret-redacted>#Ig" \
        -e 's#github_pat_[A-Za-z0-9_]+#github_pat_<redacted>#g' \
        -e 's#gh[pousr]_[A-Za-z0-9_]+#gh_<redacted>#g' \
        -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}#<uuid-redacted>#g' \
        -e 's#(^|[^0-9A-Fa-f])([0-9A-Fa-f]{48,})([^0-9A-Fa-f]|$)#\1<hex-secret-redacted>\3#g'
}

copy_redacted_file() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true
    if [[ -f "$src" ]]; then
        if [[ -r "$src" ]] && redact_sensitive_text < "$src" > "$dst" 2>/dev/null; then
            :
        else
            printf 'unreadable: %s\n' "$src" > "$dst" 2>/dev/null || true
        fi
    else
        printf 'missing: %s\n' "$src" > "$dst"
    fi
    chmod 600 "$dst" 2>/dev/null || true
}

copy_redacted_log_family() {
    local src="$1" dst="$2" keep="$LOG_ROTATE_KEEP" i
    [[ "$keep" =~ ^[0-9]+$ && "$keep" -gt 0 ]] || keep=3
    copy_redacted_file "$src" "$dst"
    for ((i=1; i<=keep; i++)); do
        [[ -e "${src}.${i}" ]] || continue
        copy_redacted_file "${src}.${i}" "${dst}.${i}"
    done
}

create_support_bundle() {
    local ts out tmp git_rev xray_ver
    ts=$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date '+%Y%m%dT%H%M%S')
    out="${1:-$LOG_DIR/g2ray-support-${ts}.tar.gz}"
    tmp=$(mktemp -d "$DATA_DIR/support-bundle.XXXXXX") || return 1
    mkdir -p "$tmp/logs" "$tmp/state" "$tmp/runtime" 2>/dev/null || { rm -rf "$tmp"; return 1; }

    git_rev=$(git -C "$BASE_DIR" log --oneline -1 2>/dev/null || printf 'unknown')
    xray_ver="unknown"
    if [[ -x "$XRAY_BIN" ]]; then
        xray_ver=$("$XRAY_BIN" version 2>/dev/null | head -1 || true)
        [[ -n "$xray_ver" ]] || xray_ver="unknown"
    fi
    {
        printf 'created_at=%s\n' "$ts"
        printf 'project=%s\n' "$PROJECT_REPO"
        printf 'git=%s\n' "$git_rev"
        printf 'codespace=%s\n' "$CODESPACE_NAME"
        printf 'domain=%s\n' "$PORT_DOMAIN"
        printf 'port=%s\n' "$XRAY_PORT"
        printf 'xray=%s\n' "$xray_ver"
        printf 'note=Sensitive VLESS links, UUIDs, bearer tokens, GitHub tokens, and wake secrets are redacted.\n'
    } | redact_sensitive_text > "$tmp/metadata.txt"

    print_doctor_json | redact_sensitive_text > "$tmp/doctor.json" 2>/dev/null || printf '{}\n' > "$tmp/doctor.json"
    copy_redacted_log_family "$LOG_FILE" "$tmp/logs/g2ray.log"
    copy_redacted_log_family "$STRUCTURED_LOG_FILE" "$tmp/logs/g2ray-events.jsonl"
    copy_redacted_log_family "$DIAGNOSTIC_LOG_FILE" "$tmp/logs/g2ray-diagnostics.log"
    copy_redacted_log_family "$LOG_DIR/xray.log" "$tmp/logs/xray.log"
    copy_redacted_log_family "$LOG_DIR/xray-error.log" "$tmp/logs/xray-error.log"
    copy_redacted_file "$ROUTE_HEALTH_FILE" "$tmp/state/route_candidate_health.tsv"
    copy_redacted_file "$ROUTE_STATS_FILE" "$tmp/state/route_candidate_stats.tsv"
    copy_redacted_file "$LAST_GOOD_ROUTE_FILE" "$tmp/state/last_good_route.txt"
    copy_redacted_file "$DNS_CANDIDATE_CACHE_FILE" "$tmp/state/dns_candidate_cache.tsv"
    copy_redacted_file "$ROUTE_SETTLING_HISTORY_FILE" "$tmp/state/route_settling_history.tsv"
    copy_redacted_file "$PINNED_ROUTE_FILE" "$tmp/state/pinned_route.txt"
    copy_redacted_file "$MANUAL_ROUTE_CANDIDATES_FILE" "$tmp/state/manual_route_candidates.txt"
    copy_redacted_file "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$tmp/state/blacklisted_route_candidates.txt"
    copy_redacted_file "$WAKER_METADATA_FILE" "$tmp/state/waker_metadata.txt"
    route_candidate_health_summary | redact_sensitive_text > "$tmp/runtime/route_candidates.txt" 2>/dev/null || true
    route_settling_history_summary | redact_sensitive_text > "$tmp/runtime/route_settling_summary.txt" 2>/dev/null || true
    last_known_state_summary | redact_sensitive_text > "$tmp/runtime/last_known_state.txt" 2>/dev/null || true

    mkdir -p "$(dirname "$out")" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    if tar -C "$tmp" -czf "$out" .; then
        chmod 600 "$out" 2>/dev/null || true
        rm -rf "$tmp"
        log_event INFO "support_bundle created path=${out}"
        printf '%s\n' "$out"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

show_diagnostics() {
    refresh_screen
    log_event INFO "diagnostics opened"
    log_diagnostic_snapshot "interactive"
    echo -e "\n  ${RED}● Diagnostics${NC}\n"
    echo -e "  Identity : ${WHITE}${CODESPACE_NAME}${NC}"
    echo -e "  Domain   : ${WHITE}${PORT_DOMAIN}${NC}"
    echo -e "  Port     : ${WHITE}${XRAY_PORT}${NC}"
    if command -v git >/dev/null 2>&1; then
        echo -e "  Git      : ${DIM}$(git -C "$BASE_DIR" log --oneline -1 2>/dev/null || echo unknown)${NC}"
    fi
    if xray_running; then
        local xpid; xpid=$(cat "$XRAY_PID_FILE" 2>/dev/null || true)
        if [[ -z "$xpid" ]] && command -v pgrep >/dev/null 2>&1; then
            xpid=$(pgrep -f "$XRAY_BIN run -c $CONFIG_FILE" 2>/dev/null | head -1 || true)
        fi
        echo -e "  Engine   : ${GREEN}Running${NC} ${DIM}(PID ${xpid:-unknown})${NC}"
    else
        echo -e "  Engine   : ${RED}Stopped${NC}"
    fi
    is_port_open \
        && echo -e "  Listener : ${GREEN}Port ${XRAY_PORT} open${NC}" \
        || echo -e "  Listener : ${RED}Port ${XRAY_PORT} closed${NC}"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        local cfg_line cfg_network cfg_security cfg_path cfg_mode cfg_uuid
        cfg_line=$(jq -r '.inbounds[]? | select(.tag=="vless-in") |
            [.streamSettings.network // "-", .streamSettings.security // "-",
             .streamSettings.xhttpSettings.path // "-", .streamSettings.xhttpSettings.mode // "-",
             .settings.clients[0].id // ""] | @tsv' "$CONFIG_FILE" 2>/dev/null | head -1)
        if [[ -n "$cfg_line" ]]; then
            IFS=$'\t' read -r cfg_network cfg_security cfg_path cfg_mode cfg_uuid <<< "$cfg_line"
            echo -e "  Config    : ${WHITE}${cfg_network}/${cfg_security}${NC} ${DIM}path=${cfg_path} mode=${cfg_mode} uuid_hash=$(fingerprint_secret "$cfg_uuid")${NC}"
        fi
    fi

    echo -e "\n  ${WHITE}${B}Background Supervisor${NC}"
    echo -e "  ${DIM}$(background_supervisor_status)${NC}"

    echo -e "\n  ${WHITE}${B}Codespaces Ports${NC}"
    if command -v gh >/dev/null 2>&1; then
        run_gh codespace ports -c "$CODESPACE_NAME" 2>/dev/null | sed 's/^/  /' \
            || echo -e "  ${YELLOW}Could not query gh codespace ports.${NC}"
    else
        echo -e "  ${DIM}gh CLI unavailable.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}XHTTP Probes${NC}"
    local local_probe local_ms edge_probe edge_ms local_usable=false edge_usable=false
    read -r local_probe local_ms _probe_reason < <(xhttp_probe_metrics local)
    read -r edge_probe edge_ms _probe_reason < <(xhttp_probe_metrics external)
    xhttp_status_usable "$local_probe" && local_usable=true
    xhttp_status_usable "$edge_probe" && edge_usable=true
    echo -e "  Local OPTIONS : ${WHITE}HTTP ${local_probe}${NC} ${DIM}(${local_ms:-0}ms usable=${local_usable})${NC}"
    echo -e "  Edge OPTIONS  : ${WHITE}HTTP ${edge_probe}${NC} ${DIM}(${edge_ms:-0}ms usable=${edge_usable})${NC}"
    echo -e "  ${DIM}HTTP 404 here means the Codespaces edge has not routed this Host/path to Xray yet.${NC}"

    echo -e "\n  ${WHITE}${B}Self-Heal State${NC}"
    echo -e "  ${DIM}$(self_heal_state_summary)${NC}"

    echo -e "\n  ${WHITE}${B}Resume Gap${NC}"
    resume_gap_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Boot Status${NC}"
    boot_status_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Last Known State${NC}"
    last_known_state_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}External Waker${NC}"
    waker_metadata_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Fallback IP Candidates${NC}"
    echo -e "  ${DIM}(includes resolved, manual, and built-in fallbacks)${NC}"
    local ips; ips=$(resolve_domain_ips "$PORT_DOMAIN" || true)
    if [[ -n "$ips" ]]; then
        printf '%s\n' "$ips" | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}No IP candidates resolved from this environment.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}Fallback Route Probes${NC}"
    if [[ -n "$ips" ]]; then
        local ip ip_probe ip_ms ip_usable probed=0 max_probe="$DIAGNOSTIC_MAX_FALLBACK_PROBES"
        [[ "$max_probe" =~ ^[0-9]+$ && "$max_probe" -gt 0 ]] || max_probe=12
        while IFS= read -r ip; do
            [[ -n "$ip" ]] || continue
            if (( probed >= max_probe )); then
                echo -e "  ${DIM}...additional candidates skipped; set G2RAY_DIAGNOSTIC_MAX_FALLBACK_PROBES to raise this cap.${NC}"
                break
            fi
            read -r ip_probe ip_ms _probe_reason < <(xhttp_probe_metrics external "$ip")
            ip_usable=false
            xhttp_status_usable "$ip_probe" && ip_usable=true
            printf '  %-15s HTTP %-3s %4sms usable=%s\n' "$ip" "${ip_probe:-0}" "${ip_ms:-0}" "$ip_usable"
            probed=$((probed + 1))
        done <<< "$ips"
    else
        echo -e "  ${DIM}No fallback IPs to probe.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}Best Route Candidates${NC}"
    route_candidate_health_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Last Good Route${NC}"
    last_good_route_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Route Settling History${NC}"
    route_settling_history_summary | sed 's/^/  /'

    echo -e "\n  ${WHITE}${B}Persistent Logs${NC}"
    echo -e "  App events      : ${WHITE}${LOG_FILE}${NC}"
    echo -e "  Structured JSONL: ${WHITE}${STRUCTURED_LOG_FILE}${NC}"
    echo -e "  Diagnostics    : ${WHITE}${DIAGNOSTIC_LOG_FILE}${NC}"
    echo -e "  Xray errors     : ${WHITE}${LOG_DIR}/xray-error.log${NC}"
    echo -e "  ${DIM}These files persist across panel screens and are rotated by size.${NC}"

    echo -e "\n  ${WHITE}${B}Runtime Tuning${NC}"
    echo -e "  Performance profile : ${WHITE}${PERFORMANCE_PROFILE}${NC}"
    echo -e "  Low-overhead mode   : ${WHITE}$(low_overhead_summary)${NC}"
    echo -e "  Latency focus mode  : ${WHITE}$(latency_focus_summary)${NC}"
    echo -e "  Local subscription file : ${WHITE}${SUBSCRIPTION_FILE}${NC}"
    echo -e "  ${DIM}Generated exports stay local in this Codespace and are ignored by git.${NC}"

    echo -e "\n  ${WHITE}${B}Recent G2ray Events${NC}"
    if [[ -s "$LOG_FILE" ]]; then
        tail -n 18 "$LOG_FILE" | sed 's/^/  /'
    else
        echo -e "  ${DIM}No G2ray app events yet.${NC}"
    fi

    echo -e "\n  ${WHITE}${B}Recent Xray Errors${NC}"
    if [[ -s "$LOG_DIR/xray-error.log" ]]; then
        tail -n 10 "$LOG_DIR/xray-error.log" | sed 's/^/  /'
    else
        echo -e "  ${DIM}No Xray errors logged.${NC}"
    fi
    echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
}

_recover_now_impl() {
    local no_prompt="${1:-}" failed=0 expose_failed=false route_ready=false engine_started=false xcode=0 xms=0
    log_event INFO "recover_now begin no_prompt=${no_prompt:-false}"
    echo -e "\n  ${GREEN}*${NC} ${WHITE}Running Soft Recover Sequence...${NC}\n"

    echo -ne "  ${DIM}|-${NC} Detect Identity   : "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    log_event INFO "recover_now identity codespace=${CODESPACE_NAME} domain=${PORT_DOMAIN}"
    [[ "$CODESPACE_NAME" == "unknown-codespace" ]] \
        && echo -e "${RED}Failed${NC}" \
        || echo -e "${GREEN}${CODESPACE_NAME}${NC}"

    echo -ne "  ${DIM}|-${NC} Verify Engine     : "
    if xray_listener_ready; then
        echo -e "${GREEN}Running${NC}"
    else
        if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1 && xray_listener_ready; then
            engine_started=true
            log_event INFO "recover_now engine_started port=${XRAY_PORT}"
            echo -e "${GREEN}Started${NC}"
        else
            failed=1
            log_event ERROR "recover_now engine_unavailable port=${XRAY_PORT}"
            echo -e "${RED}Failed${NC}"
        fi
    fi

    echo -ne "  ${DIM}|-${NC} Expose Tunnel     : "
    if ensure_codespace_port_public force >/dev/null 2>&1; then
        echo -e "${GREEN}Done${NC}"
    else
        expose_failed=true
        failed=1
        log_event WARN "recover_now expose_tunnel failed port=${XRAY_PORT}"
        echo -e "${YELLOW}Needs PORTS tab${NC}"
    fi

    echo -ne "  ${DIM}|-${NC} Wait Route        : "
    if wait_for_xhttp_route_ready "recover_now" "$ROUTE_WAIT_SEC" >/dev/null 2>&1; then
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        route_ready=true
        echo -e "${GREEN}Ready (HTTP ${xcode})${NC}"
    else
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        echo -e "${YELLOW}Settling (HTTP ${xcode:-0})${NC}"
    fi

    if [[ "$route_ready" != true ]]; then
        echo -ne "  ${DIM}|-${NC} Repair Route      : "
        repair_codespace_port_route >/dev/null 2>&1 || true
        if wait_for_xhttp_route_ready "recover_now_repair" "$FORCE_RECONNECT_ROUTE_WAIT_SEC" >/dev/null 2>&1; then
            read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
            route_ready=true
            echo -e "${GREEN}Ready (HTTP ${xcode})${NC}"
        else
            read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
            echo -e "${YELLOW}Still settling (HTTP ${xcode:-0})${NC}"
        fi
    fi

    echo -ne "  ${DIM}|-${NC} Refresh Routes    : "
    refresh_route_candidate_health >/dev/null 2>&1 || true
    echo -e "${GREEN}Done${NC}"

    echo -ne "  ${DIM}\\-${NC} Refresh Exports   : "
    if refresh_config_exports >/dev/null 2>&1; then
        echo -e "${GREEN}Done${NC}"
    else
        log_event WARN "recover_now export_refresh_failed"
        echo -e "${YELLOW}Skipped${NC}"
    fi

    log_diagnostic_snapshot "recover_now"
    log_event INFO "recover_now complete route_ready=${route_ready} xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} engine_started=${engine_started} expose_failed=${expose_failed}"

    if [[ "$route_ready" == true ]]; then
        failed=0
        reset_route_bad_count
        reset_edge_bad_count
        echo -e "\n  ${GREEN}Soft recover complete. Try the same config again.${NC}\n"
    else
        failed=1
        echo -e "\n  ${YELLOW}Route is still settling. Waiting usually fixes this; hard restart is available if it stays stuck.${NC}\n"
    fi

    if [[ "$no_prompt" == "--no-prompt" ]]; then
        return "$failed"
    fi

    if [[ "$route_ready" != true ]]; then
        echo -ne "  ${GREEN}Run hard restart now?${NC} (y/n): "
        local hard
        read -r hard
        if [[ "$hard" =~ ^[Yy]$ ]]; then
            force_reconnect
            return $?
        fi
    else
        echo -ne "  ${DIM}Press Enter to return...${NC}"
        read -r
    fi
    return "$failed"
}

recover_now() {
    with_runtime_lock _recover_now_impl "$@"
}

recover_now_json() {
    local recover_rc=0 rc=0 xcode=0 xms=0 route_ready=false engine=false listener=false status next_action next_action_code ok_bool=false
    if recover_now --no-prompt >/dev/null 2>&1; then
        recover_rc=0
    else
        recover_rc=$?
    fi
    read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
    if xhttp_status_usable "$xcode"; then
        route_ready=true
        status="ready"
        rc=0
    elif [[ "$xcode" == "404" ]]; then
        status="settling"
        rc="$recover_rc"
    else
        status="failed"
        rc="$recover_rc"
    fi
    [[ "$route_ready" != true && "$rc" -eq 0 ]] && rc=1
    xray_running && engine=true
    is_port_open && listener=true
    if [[ "$route_ready" == true ]]; then
        next_action_code="retry_vless_config"
    elif [[ "$xcode" == "404" ]]; then
        next_action_code="wait_route_or_recover"
    else
        next_action_code=$(panel_next_action_code "$engine" "$listener" "$xcode" true)
    fi
    next_action=$(panel_next_action_text "$next_action_code")
    [[ "$route_ready" == true && "$rc" -eq 0 ]] && ok_bool=true
    log_event INFO "recover_now_json requested ok=${ok_bool} status=${status} route_ready=${route_ready} xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} rc=${rc} recover_rc=${recover_rc}"
    cat <<JSON
{
  "ok": ${ok_bool},
  "status": "$(json_escape "$status")",
  "route_ready": ${route_ready},
  "engine_running": ${engine},
  "listener_open": ${listener},
  "edge_probe": {"http_status": ${xcode:-0}, "latency_ms": ${xms:-0}, "usable": $(xhttp_status_usable "$xcode" && printf true || printf false)},
  "exit_code": ${rc},
  "recover_exit_code": ${recover_rc},
  "next_action_code": "$(json_escape "$next_action_code")",
  "next_action": "$(json_escape "$next_action")",
  "log_file": "$(json_escape "$LOG_FILE")",
  "structured_log_file": "$(json_escape "$STRUCTURED_LOG_FILE")",
  "diagnostic_log_file": "$(json_escape "$DIAGNOSTIC_LOG_FILE")"
}
JSON
    return "$rc"
}

_force_reconnect_impl() {
    local no_prompt="${1:-}" failed=0 expose_failed=false hard_failed=false
    log_event INFO "force_reconnect begin no_prompt=${no_prompt:-false}"
    echo -e "\n  ${GREEN}⠋${NC} ${WHITE}Running Clean Hard Restart & Reconnect Sequence...${NC}\n"

    echo -ne "  ${DIM}├─${NC} Detect Identity   : "
    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"
    log_event INFO "force_reconnect identity codespace=${CODESPACE_NAME} domain=${PORT_DOMAIN}"
    [[ "$CODESPACE_NAME" == "unknown-codespace" ]] \
        && echo -e "${RED}Failed${NC}" \
        || echo -e "${GREEN}${CODESPACE_NAME}${NC}"

    echo -ne "  ${DIM}├─${NC} Force Kill Engine : "
    if stop_xray >/dev/null 2>&1; then
        log_event INFO "force_reconnect stopped_previous_engine"
        echo -e "${GREEN}Done${NC}"
    else
        failed=1
        hard_failed=true
        log_event ERROR "force_reconnect stop_engine failed"
        echo -e "${RED}Failed${NC}"
    fi

    echo -ne "  ${DIM}├─${NC} Start Engine      : "
    if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
        log_event INFO "force_reconnect start_engine ok port=${XRAY_PORT}"
        echo -e "${GREEN}OK${NC}"
    else
        failed=1
        hard_failed=true
        log_event ERROR "force_reconnect start_engine failed port=${XRAY_PORT}"
        echo -e "${RED}Failed${NC}"
    fi

    echo -ne "  ${DIM}├─${NC} Expose Tunnel     : "
    if ensure_codespace_port_public force >/dev/null 2>&1; then
        log_event INFO "force_reconnect expose_tunnel ok port=${XRAY_PORT}"
        echo -e "${GREEN}Done${NC}"
    else
        expose_failed=true
        failed=1
        log_event WARN "force_reconnect expose_tunnel failed port=${XRAY_PORT}"
        echo -e "${YELLOW}Needs PORTS tab${NC}"
    fi

    echo -ne "  ${DIM}╰─${NC} Verify External   : "
    local edge_reachable=false xhttp_route_usable=false code xcode xms
    for _i in 1 2 3 4; do
        code=$(curl_http_code "https://${PORT_DOMAIN}" 5)
        [[ "$code" != "000" && "$code" != "0" ]] && edge_reachable=true
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        if xhttp_status_usable "$xcode"; then
            xhttp_route_usable=true
            break
        fi
        sleep 2
    done
    if [[ "$edge_reachable" == true && "$xhttp_route_usable" != true ]]; then
        repair_codespace_port_route >/dev/null 2>&1 || true
        sleep 3
        if wait_for_xhttp_route_ready "force_reconnect" "$FORCE_RECONNECT_ROUTE_WAIT_SEC" >/dev/null 2>&1; then
            read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
            xhttp_route_usable=true
        else
            read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
            xhttp_status_usable "$xcode" && xhttp_route_usable=true
        fi
    fi
    log_event INFO "force_reconnect verify_external edge_reachable=${edge_reachable} code=${code:-none} xhttp_probe=${xcode:-none} xhttp_probe_ms=${xms:-0} xhttp_route_usable=${xhttp_route_usable} domain=${PORT_DOMAIN}"
    [[ "$edge_reachable" == true && "$xhttp_route_usable" == true ]] || failed=1
    if [[ "$xhttp_route_usable" == true ]]; then
        [[ "$expose_failed" == true && "$hard_failed" != true ]] && failed=0
        reset_route_bad_count
        echo -e "${GREEN}XHTTP route usable (HTTP ${xcode})${NC}\n"
    elif [[ "$edge_reachable" == true ]]; then
        echo -e "${YELLOW}Edge reachable but route settling (HTTP ${xcode:-0})${NC}\n"
    else
        echo -e "${YELLOW}Pending / delayed (HTTP ${code:-0})${NC}\n"
    fi

    [[ "$no_prompt" == "--no-prompt" ]] && { sleep 1; return "$failed"; }
    echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
    return "$failed"
}

force_reconnect() {
    with_runtime_lock _force_reconnect_impl "$@"
}

_ensure_runtime_ready_impl() {
    local reason="${1:-startup}" xcode xms
    record_resume_gap "$reason"
    [[ -f "$CONFIG_FILE" ]] || return 0

    CODESPACE_NAME=$(_detect_codespace_name 2>/dev/null || true)
    PORT_DOMAIN="${CODESPACE_NAME}-${XRAY_PORT}.app.github.dev"

    if xray_listener_ready; then
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        if xhttp_status_usable "$xcode"; then
            ensure_codespace_port_public >/dev/null 2>&1 \
                || log_event WARN "runtime_ready reason=${reason} port_public_failed port=${XRAY_PORT}"
            reset_route_bad_count
            reset_edge_bad_count
            log_event INFO "runtime_ready reason=${reason} engine=running xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=skip_reconnect"
            return 0
        fi

        log_event WARN "runtime_ready reason=${reason} route_unusable xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=repair"
        repair_codespace_port_route >/dev/null 2>&1 || true
        if wait_for_xhttp_route_ready "$reason"; then
            reset_route_bad_count
            log_event INFO "runtime_ready reason=${reason} route_repaired"
            return 0
        fi
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        log_event WARN "runtime_ready reason=${reason} route_still_unusable xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=observe"
        return 1
    fi

    log_event WARN "runtime_ready reason=${reason} engine_not_ready action=start"
    if start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1; then
        ensure_codespace_port_public >/dev/null 2>&1 \
            || log_event WARN "runtime_ready reason=${reason} port_public_failed port=${XRAY_PORT}"
        read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        if ! xhttp_status_usable "$xcode"; then
            log_event WARN "runtime_ready reason=${reason} started_route_unusable xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=repair"
            repair_codespace_port_route >/dev/null 2>&1 || true
            wait_for_xhttp_route_ready "$reason" >/dev/null 2>&1 || true
            read -r xcode xms _probe_reason < <(xhttp_probe_metrics external)
        fi
        if xhttp_status_usable "$xcode"; then
            reset_route_bad_count
            reset_edge_bad_count
            log_event INFO "runtime_ready reason=${reason} started_route_ready xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0}"
            log_event INFO "runtime_ready reason=${reason} engine=started xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0}"
            return 0
        fi
        log_event WARN "runtime_ready reason=${reason} started_route_still_unusable xhttp_probe=${xcode:-0} xhttp_probe_ms=${xms:-0} action=observe"
        return 1
    fi

    log_event ERROR "runtime_ready reason=${reason} start_failed port=${XRAY_PORT}"
    return 1
}

ensure_runtime_ready() {
    with_runtime_lock _ensure_runtime_ready_impl "$@"
}

print_doctor_json() {
    local engine=false listener=false local_probe=0 local_ms=0 edge_probe=0 edge_ms=0 supervisor last_good waker_url doctor_port config_present=false next_action_code next_action
    doctor_port="$XRAY_PORT"
    [[ "$doctor_port" =~ ^[0-9]+$ && "$doctor_port" -gt 0 && "$doctor_port" -le 65535 ]] || doctor_port=443
    xray_running && engine=true
    is_port_open && listener=true
    [[ -f "$CONFIG_FILE" ]] && config_present=true
    read -r local_probe local_ms _probe_reason < <(xhttp_probe_metrics local)
    read -r edge_probe edge_ms _probe_reason < <(xhttp_probe_metrics external)
    supervisor=$(background_supervisor_status | tr '\r\n' ' ' | cut -c1-180)
    last_good=$(last_good_route_value)
    waker_url=$(waker_metadata_value worker_url)
    next_action_code=$(panel_next_action_code "$engine" "$listener" "$edge_probe" "$config_present")
    next_action=$(panel_next_action_text "$next_action_code")
    log_event INFO "doctor_json requested engine=${engine} listener=${listener} edge_probe=${edge_probe:-0} edge_ms=${edge_ms:-0} next_action_code=${next_action_code}"
    cat <<JSON
{
  "ok": true,
  "codespace": "$(json_escape "$CODESPACE_NAME")",
  "domain": "$(json_escape "$PORT_DOMAIN")",
  "port": ${doctor_port},
  "engine_running": ${engine},
  "listener_open": ${listener},
  "config_present": ${config_present},
  "local_probe": {"http_status": ${local_probe:-0}, "latency_ms": ${local_ms:-0}, "usable": $(xhttp_status_usable "$local_probe" && printf true || printf false)},
  "edge_probe": {"http_status": ${edge_probe:-0}, "latency_ms": ${edge_ms:-0}, "usable": $(xhttp_status_usable "$edge_probe" && printf true || printf false)},
  "next_action_code": "$(json_escape "$next_action_code")",
  "next_action": "$(json_escape "$next_action")",
  "supervisor": "$(json_escape "$supervisor")",
  "last_good_route": "$(json_escape "$last_good")",
  "waker_configured": $([[ -n "$waker_url" ]] && printf true || printf false),
  "low_overhead": $(low_overhead_enabled && printf true || printf false),
  "latency_focus": $(latency_focus_enabled && printf true || printf false),
  "performance_profile": "$(json_escape "$PERFORMANCE_PROFILE")",
  "log_file": "$(json_escape "$LOG_FILE")",
  "structured_log_file": "$(json_escape "$STRUCTURED_LOG_FILE")",
  "diagnostic_log_file": "$(json_escape "$DIAGNOSTIC_LOG_FILE")"
}
JSON
}

bench_now_ns() {
    date +%s%N 2>/dev/null || awk 'BEGIN{srand(); printf "%.0f\n", systime() * 1000000000}'
}

bench_elapsed_ms() {
    local start="$1" end="$2"
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$end" -ge "$start" ]] || { printf '0'; return 0; }
    printf '%s' "$(( (end - start) / 1000000 ))"
}

bench_budget_value() {
    local value="$1" fallback="$2"
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

bench_budget_ms() {
    local name="$1"
    case "$name" in
        config_path_cache) bench_budget_value "${G2RAY_BENCH_BUDGET_CONFIG_PATH_MS:-800}" 800 ;;
        route_ordering) bench_budget_value "${G2RAY_BENCH_BUDGET_ROUTE_ORDERING_MS:-500}" 500 ;;
        export_generation) bench_budget_value "${G2RAY_BENCH_BUDGET_EXPORT_MS:-3500}" 3500 ;;
        doctor_json) bench_budget_value "${G2RAY_BENCH_BUDGET_DOCTOR_MS:-1800}" 1800 ;;
        recover_json_contract) bench_budget_value "${G2RAY_BENCH_BUDGET_RECOVER_JSON_MS:-1800}" 1800 ;;
        *) bench_budget_value "${G2RAY_BENCH_BUDGET_DEFAULT_MS:-1000}" 1000 ;;
    esac
}

bench_case_json() {
    local name="$1" command="$2" start end elapsed budget ok rc=0
    budget=$(bench_budget_ms "$name")
    start=$(bench_now_ns)
    eval "$command" >/dev/null 2>&1 || rc=$?
    end=$(bench_now_ns)
    elapsed=$(bench_elapsed_ms "$start" "$end")
    ok=false
    [[ "$budget" =~ ^[0-9]+$ && "$elapsed" =~ ^[0-9]+$ && "$elapsed" -le "$budget" && "$rc" -eq 0 ]] && ok=true
    printf '{"name":"%s","elapsed_ms":%s,"budget_ms":%s,"ok":%s,"exit_code":%s}' \
        "$(json_escape "$name")" "$elapsed" "$budget" "$ok" "$rc"
}

bench_prepare_mock_state() {
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$BASE_DIR/data/qr" 2>/dev/null || true
    [[ -s "$UUID_FILE" ]] || printf '00000000-0000-4000-8000-000000000001\n' > "$UUID_FILE"
    cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"vless-in","port":443,"protocol":"vless","settings":{"clients":[{"id":"00000000-0000-4000-8000-000000000001"}]},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/","mode":"packet-up"}}}]}
JSON
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-06-01T00:00:00Z	20.0.0.1	200	40	true	dns	ready
2026-06-01T00:00:00Z	20.0.0.2	200	70	true	dns	ready
2026-06-01T00:00:00Z	20.0.0.3	404	20	false	dns	route_settling_404
EOF
    cat > "$ROUTE_STATS_FILE" <<'EOF'
20.0.0.1	8	8	0	40	35	60	40	200	true	2026-06-01T00:00:00Z	40	0	ready
20.0.0.2	8	7	1	70	60	120	70	200	true	2026-06-01T00:00:00Z	75	0	ready
EOF
}

bench_rebind_runtime_paths() {
    BASE_DIR="$1"
    DATA_DIR="$BASE_DIR/data"
    CONFIG_FILE="$DATA_DIR/config.json"
    UUID_FILE="$DATA_DIR/uuid.txt"
    BG_TASKS_PID="$DATA_DIR/bg_tasks.pid"
    BG_TASKS_VERSION_FILE="$DATA_DIR/bg_tasks.version"
    BG_TASKS_LOCK_DIR="$DATA_DIR/bg_tasks.lock"
    RUNTIME_LOCK_DIR="$DATA_DIR/runtime.lock"
    BG_TASKS_TOKEN_FILE="$DATA_DIR/bg_tasks.token"
    BG_TASKS_HEARTBEAT_FILE="$DATA_DIR/bg_tasks.heartbeat"
    RESUME_GAP_FILE="$DATA_DIR/resume_gap.txt"
    WAKER_METADATA_FILE="$DATA_DIR/waker_metadata.txt"
    WAKER_PROMPT_FILE="$DATA_DIR/.waker_setup_prompted"
    REMOTE_MESSAGE_FILE="$DATA_DIR/message.txt"
    ROUTE_BAD_COUNT_FILE="$DATA_DIR/xhttp_route_bad_count"
    EDGE_BAD_COUNT_FILE="$DATA_DIR/edge_bad_count"
    EDGE_RECONNECT_STAMP_FILE="$DATA_DIR/edge_reconnect_last"
    ROUTE_HEALTH_FILE="$DATA_DIR/route_candidate_health.tsv"
    ROUTE_STATS_FILE="$DATA_DIR/route_candidate_stats.tsv"
    ROUTE_COOLDOWN_FILE="$DATA_DIR/route_candidate_cooldowns.tsv"
    DNS_CANDIDATE_CACHE_FILE="$DATA_DIR/dns_candidate_cache.tsv"
    BOOT_STATUS_FILE="$DATA_DIR/boot_status.json"
    XHTTP_PATH_CACHE_FILE="$DATA_DIR/xhttp_path_cache"
    LOW_OVERHEAD_FILE="$DATA_DIR/low_overhead_mode"
    LOW_OVERHEAD_DISABLED_FILE="$DATA_DIR/low_overhead_mode_disabled"
    LATENCY_FOCUS_FILE="$DATA_DIR/latency_focus_mode"
    LATENCY_FOCUS_DISABLED_FILE="$DATA_DIR/latency_focus_mode_disabled"
    LAST_GOOD_ROUTE_FILE="$DATA_DIR/last_good_route.txt"
    PINNED_ROUTE_FILE="$DATA_DIR/pinned_route.txt"
    MANUAL_ROUTE_CANDIDATES_FILE="$DATA_DIR/manual_route_candidates.txt"
    BLACKLISTED_ROUTE_CANDIDATES_FILE="$DATA_DIR/blacklisted_route_candidates.txt"
    ROUTE_SETTLING_HISTORY_FILE="$DATA_DIR/route_settling_history.tsv"
    PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
    QUOTA_CYCLE_FILE="$DATA_DIR/quota_cycle.txt"
    XRAY_PID_FILE="$DATA_DIR/xray.pid"
    SAVED_BYTES_FILE="$DATA_DIR/saved_bytes.json"
    SESSION_BYTES_FILE="$DATA_DIR/session_bytes.json"
    TOTAL_UPTIME_FILE="$DATA_DIR/total_uptime_sec.txt"
    SESSION_START_FILE="$DATA_DIR/session_start.txt"
    LOG_DIR="$BASE_DIR/logs"
    LOG_FILE="$LOG_DIR/g2ray.log"
    STRUCTURED_LOG_FILE="$LOG_DIR/g2ray-events.jsonl"
    DIAGNOSTIC_LOG_FILE="$LOG_DIR/g2ray-diagnostics.log"
    QR_DIR="$DATA_DIR/qr"
    MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
    SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
    CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
}

bench_json_impl() {
    local mock="${1:-false}" first=true case_json cases="" overall=true
    if [[ "$mock" == "true" ]]; then
        bench_prepare_mock_state
        MAX_FALLBACK_LINKS=2
        ROUTE_MONITOR_MAX_CANDIDATES=3
        ROUTE_HEALTH_TTL_SEC=3600
        CODESPACE_NAME="bench-space"
        PORT_DOMAIN="bench-space-443.app.github.dev"
        log_event() { return 0; }
        xhttp_probe_metrics() { printf '200 1 ready\n'; }
        ensure_codespace_port_public() { return 0; }
        xray_running() { return 0; }
        is_port_open() { return 0; }
        xray_listener_ready() { return 0; }
        wait_for_xhttp_route_ready() { printf '200 1\n'; return 0; }
        refresh_route_candidate_health() { return 0; }
        background_supervisor_status() { printf 'pid=1 running=true version=ok token=present heartbeat_age=1s\n'; }
        recover_now() { return 0; }
    fi
    for spec in \
        'config_path_cache|for _i in $(seq 1 5); do xhttp_config_path >/dev/null; done' \
        'route_ordering|cached_usable_fallback_ips >/dev/null || true' \
        'export_generation|refresh_config_exports' \
        'doctor_json|print_doctor_json' \
        'recover_json_contract|recover_now_json || true'
    do
        local name="${spec%%|*}" cmd="${spec#*|}"
        case_json=$(bench_case_json "$name" "$cmd")
        [[ "$case_json" == *'"ok":false'* ]] && overall=false
        if [[ "$first" == true ]]; then
            cases="    ${case_json}"
            first=false
        else
            cases="${cases},\n    ${case_json}"
        fi
    done
    printf '{\n  "ok": %s,\n  "mocked": %s,\n  "cases": [\n%b\n  ],\n  "budgets_ok": %s\n}\n' \
        "$overall" "$mock" "$cases" "$overall"
    [[ "$overall" == true ]]
}

bench_json() {
    local mock=false tmp rc
    [[ "${1:-}" == "--mock" || "${G2RAY_BENCH_MOCK:-0}" == "1" ]] && mock=true
    if [[ "$mock" == "true" ]]; then
        tmp="${G2RAY_BENCH_PREINIT_TMP:-}"
        if [[ -z "$tmp" ]]; then
            tmp=$(mktemp -d "${TMPDIR:-/tmp}/g2ray-bench.XXXXXX") || return 1
        fi
        (
            export G2RAY_BENCH_ISOLATED=1
            bench_rebind_runtime_paths "$tmp"
            bench_json_impl true
        )
        rc=$?
        rm -rf -- "$tmp"
        return "$rc"
    fi
    bench_json_impl "$mock"
}

if [[ "${G2RAY_SOURCE_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

if [[ "${1:-}" == "--doctor-json" || "${1:-}" == "--status-json" || ( "${1:-}" == "doctor" && "${2:-}" == "--json" ) ]]; then
    print_doctor_json
    exit 0
fi

if [[ "${1:-}" == "--status" || "${1:-}" == "status" ]]; then
    print_doctor_json
    exit 0
fi

if [[ "${1:-}" == "--bench" || "${1:-}" == "bench" ]]; then
    if [[ "${2:-}" == "--json" ]]; then
        bench_json "${3:-}"
    else
        bench_json "${2:-}"
    fi
    exit $?
fi

if [[ "${1:-}" == "--refresh-exports" || "${1:-}" == "--export" || "${1:-}" == "export" ]]; then
    refresh_config_exports
    printf 'Exports refreshed: %s\n' "$SUBSCRIPTION_FILE"
    exit 0
fi

if [[ "${1:-}" == "--support-bundle" || "${1:-}" == "support-bundle" ]]; then
    create_support_bundle
    exit $?
fi

if [[ ( "${1:-}" == "--recover-now" || "${1:-}" == "recover" ) && "${2:-}" == "--json" ]]; then
    recover_now_json
    exit $?
fi

if [[ "${1:-}" == "--recover-now" || "${1:-}" == "recover" ]]; then
    recover_now --no-prompt
    exit $?
fi

if [[ "${1:-}" == "--start" || "${1:-}" == "start" ]]; then
    [[ -f "$CONFIG_FILE" ]] || { echo "No config exists yet. Run the panel and generate one first." >&2; exit 1; }
    ensure_runtime_ready "headless_start"
    start_background_tasks
    exit $?
fi

if [[ "${1:-}" == "--latency-focus" || "${1:-}" == "latency-focus" ]]; then
    case "${2:-toggle}" in
        on|enable|enabled) enable_latency_focus_mode; printf 'latency_focus=enabled\n' ;;
        off|disable|disabled) disable_latency_focus_mode; printf 'latency_focus=disabled\n' ;;
        status) latency_focus_enabled && printf 'latency_focus=enabled\n' || printf 'latency_focus=disabled\n' ;;
        *) toggle_latency_focus_mode && printf 'latency_focus=enabled\n' || printf 'latency_focus=disabled\n' ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "--background-supervisor" ]]; then
    _background_tasks
    exit 0
fi

if [[ "${1:-}" == "--silent-start" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        write_boot_status "no_config" "silent_start" "No config exists yet; open the panel and generate one." "0" "0"
    elif ensure_runtime_ready "silent_start" >/dev/null 2>&1; then
        read -r _boot_code _boot_ms _boot_reason < <(xhttp_probe_metrics external)
        write_boot_status "ready" "silent_start" "Xray started and the Codespaces route is usable." "${_boot_code:-0}" "${_boot_ms:-0}"
    else
        read -r _boot_code _boot_ms _boot_reason < <(xhttp_probe_metrics external)
        if [[ "${_boot_code:-0}" == "404" ]]; then
            write_boot_status "route_settling" "silent_start" "Xray is up, but GitHub's app route is still settling. Wait, check health, or run Recover Now." "${_boot_code:-0}" "${_boot_ms:-0}"
        else
            write_boot_status "needs_attention" "silent_start" "Startup completed but the external route is not usable yet." "${_boot_code:-0}" "${_boot_ms:-0}"
        fi
    fi
    start_background_tasks
    exit 0
fi

cleanup() {
    local code=$?
    save_xray_stats 2>/dev/null || true
    save_session_uptime 2>/dev/null || true
    echo -e "\n  ${DIM}Goodbye.${NC}"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_for_updates "$@"
ensure_runtime_ready "interactive_attach" >/dev/null 2>&1 || true
start_background_tasks
fetch_remote_message
enable_anti_sleep

if [[ ! -f "$CONFIG_FILE" ]]; then
    refresh_screen
    echo -e "  ${GREEN}● Welcome to G2ray${NC}"
    echo -e "  ${WHITE}No configuration found. First run setup.${NC}\n"
    echo -e "  ${RED}1)${NC} Generate Config & Start"
    echo -e "  ${DIM}2)${NC} Exit\n"
    echo -ne "  ${RED}╰─❯${NC} "
    read -r setup
    if [[ "$setup" == "1" ]]; then
        generate_config
        echo -e "\n  ${GREEN}✔ Setup complete!${NC}"
        sleep 1
        maybe_prompt_waker_setup
        show_recovery_command_card
        show_diagnostics
    else
        exit 0
    fi
else
    refresh_screen
    maybe_prompt_waker_setup
fi

while true; do
    refresh_screen

    if xray_running; then
        _STATUS="${GREEN}▶ RUNNING${NC}"
    else
        _STATUS="${RED}■ STOPPED${NC}"
    fi

    if tmux has-session -t g2ray_keepalive 2>/dev/null; then
        _KA="${GREEN}Enabled${NC}"
        _KA_LABEL="${GREEN}currently Enabled${NC}"
    else
        _KA="${DIM}Disabled${NC}"
        _KA_LABEL="${DIM}currently Disabled${NC}"
    fi
    if low_overhead_enabled; then
        _LOW_LABEL="${GREEN}currently Enabled${NC}"
    else
        _LOW_LABEL="${DIM}currently Disabled${NC}"
    fi
    if latency_focus_enabled; then
        _LATENCY_LABEL="${GREEN}currently Enabled${NC}"
    else
        _LATENCY_LABEL="${DIM}currently Disabled${NC}"
    fi

    echo -e "  ${WHITE}${B}Engine Status  :${NC} $(echo -e "$_STATUS")"
    echo -e "  ${WHITE}${B}Anti-Sleep Mode:${NC} $(echo -e "$_KA")\n"
    echo -e "  ${DIM}Educational/research use only. Follow local laws and platform rules.${NC}\n"
    echo -e "  ${WHITE}${B}● CORE CONTROLS${NC}"
    echo -e "   ${RED}1)${NC} View Config & QR Code       ${RED}4)${NC} Stop Engine"
    echo -e "   ${RED}2)${NC} Generate New Config         ${RED}5)${NC} Restart Engine"
    echo -e "   ${RED}3)${NC} Start Engine                ${RED}6)${NC} Recover Now"
    echo ""
    echo -e "  ${WHITE}${B}● SYSTEM CONFIGURATION${NC}"
    echo -e "   ${RED}7)${NC} Toggle Anti-Sleep Mode ($(echo -e "$_KA_LABEL"))"
    echo -e "   ${DIM}Generated configs stay local; do not publish live links.${NC}"
    echo -e "  ${RED}18)${NC} Toggle Low-Overhead Mode ($(echo -e "$_LOW_LABEL"))"
    echo -e "  ${RED}49)${NC} Toggle Latency Focus Mode ($(echo -e "$_LATENCY_LABEL"))"
    echo ""
    echo -e "  ${WHITE}${B}● ANALYTICS & TOOLS${NC}"
    echo -e "   ${RED}9)${NC} Data Usage                 ${RED}12)${NC} Server Location"
    echo -e "  ${RED}10)${NC} Resource Stats             ${RED}13)${NC} View Engine Logs"
    echo -e "  ${RED}14)${NC} Diagnostics                ${RED}15)${NC} Recovery / Waker Setup"
    echo -e "  ${RED}11)${NC} Quota & Uptime             ${RED}16)${NC} Live Monitor"
    echo -e "                                      ${RED}17)${NC} Route Candidates"
    echo ""
    echo -e "   ${RED}0)${NC} Exit Panel"
    echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"

    if [[ -s "$REMOTE_MESSAGE_FILE" ]]; then
        local_msg=$(sed 's/\r//g' "$REMOTE_MESSAGE_FILE" 2>/dev/null)
        if [[ "$local_msg" != *"404"* && -n "$(printf '%s' "$local_msg" | tr -d ' \n\t')" ]]; then
            echo -e "  ${YELLOW}📢 Dev Note: ${WHITE}${local_msg}${NC}"
            echo -e "  ${DIM}───────────────────────────────────────────────────────────${NC}"
        fi
    fi

    echo -ne "  ${RED}╰─❯${NC} "
    read -r _choice

    case $_choice in
        1)
            check_port_visibility || continue
            _VLESS_DOMAIN=$(generate_domain_link) || _VLESS_DOMAIN=""
            _VLESS_IPS=$(generate_ip_links) || _VLESS_IPS=""
            mapfile -t _VLESS_IP_ARRAY < <(printf '%s\n' "$_VLESS_IPS" | awk 'NF')
            _CONFIG_LINKS=()
            _CONFIG_LABELS=()
            _DOMAIN_ALREADY=false
            for _LINK in "${_VLESS_IP_ARRAY[@]}"; do
                [[ -n "$_LINK" ]] || continue
                if ((${#_CONFIG_LINKS[@]} == 0)); then
                    _CONFIG_LABELS+=("Recommended IP link (try this first)")
                else
                    _CONFIG_LABELS+=("IP fallback link $((${#_CONFIG_LINKS[@]} + 1))")
                fi
                _CONFIG_LINKS+=("$_LINK")
                [[ "$_LINK" == "$_VLESS_DOMAIN" ]] && _DOMAIN_ALREADY=true
            done
            if [[ -n "$_VLESS_DOMAIN" && "$_DOMAIN_ALREADY" != true ]]; then
                if ((${#_CONFIG_LINKS[@]} == 0)); then
                    _CONFIG_LABELS+=("Recommended domain link")
                else
                    _CONFIG_LABELS+=("Domain link (try only if app.github.dev is allowed)")
                fi
                _CONFIG_LINKS+=("$_VLESS_DOMAIN")
            fi
            _VLESS_PRIMARY="${_CONFIG_LINKS[0]:-}"
            [[ -z "$_VLESS_PRIMARY" ]] && { echo -e "  ${RED}✖ Error generating link.${NC}"; sleep 2; continue; }
            write_config_exports_from_links "${_CONFIG_LINKS[@]}" >/dev/null 2>&1 || true
            refresh_screen
            echo -e "  ${RED}● Configs & QR Codes${NC}"
            echo -e "  ${DIM}Raw links are printed without color codes and saved locally to:${NC}"
            echo -e "  ${DIM}Local base64 subscription file:${NC} ${WHITE}${SUBSCRIPTION_FILE}${NC}"
            echo -e "  ${DIM}Generated exports are ignored by git and are not published through the repo.${NC}"
            echo -e "  ${WHITE}${MOBILE_CONFIG_FILE}${NC}\n"
            _INDEX=1
            _QR_MODE="${G2RAY_QR_MODE:-recommended}"
            for _LINK in "${_CONFIG_LINKS[@]}"; do
                _SHOW_QR=false
                [[ "$_QR_MODE" == "all" || ( "$_QR_MODE" != "none" && $_INDEX -eq 1 ) ]] && _SHOW_QR=true
                render_config_entry "$_INDEX" "${_CONFIG_LABELS[$((_INDEX - 1))]}" "$_LINK" "$_SHOW_QR"
                _INDEX=$((_INDEX + 1))
            done
            echo -e "  ${DIM}IP links keep ${PORT_DOMAIN} as SNI/Host for Codespaces routing.${NC}\n"
            echo -e "  ${DIM}QR PNG files are saved under ${QR_DIR}.${NC}"
            echo -e "  ${DIM}If phone QR scanning fails, open the PNG, import the copy-ready link, or${NC}"
            echo -e "  ${DIM}${MOBILE_CONFIG_FILE} instead. Terminal zoom/theme can make QR scanning unreliable.${NC}\n"
            echo -e "  ${DIM}For exit location details, use option 12) Server Location.${NC}\n"
            echo -e "  ${DIM}Not working? Visit:${NC} ${GREEN}https://code-leafy.github.io/NetLeafy${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        2)
            echo -e "\n  ${YELLOW}⚠ Overwrite current config and restart engine?${NC}"
            echo -ne "  ${GREEN}╰─❯${NC} Proceed (y/n): "
            read -r _confirm
            [[ "$_confirm" =~ ^[Yy]$ ]] && { generate_config; sleep 1; }
            ;;
        3)
            if xray_running; then
                echo -e "\n  ${WHITE}Engine is already running.${NC}"
            else
                if start_xray && wait_for_port; then
                    ensure_codespace_port_public \
                        || echo -e "  ${YELLOW}⚠ Could not set port public. Use the PORTS tab.${NC}"
                fi
            fi
            sleep 1
            ;;
        4)
            if stop_xray; then
                echo -e "\n  ${RED}■ Engine stopped.${NC}"
            else
                echo -e "\n  ${RED}✖ Could not fully stop the engine. Check diagnostics.${NC}"
            fi
            sleep 1
            ;;
        5)
            if start_xray && wait_for_port; then
                ensure_codespace_port_public \
                    || echo -e "  ${YELLOW}⚠ Could not set port public. Use the PORTS tab.${NC}"
            fi
            sleep 1
            ;;
        6) recover_now ;;
        7)
            if tmux has-session -t g2ray_keepalive 2>/dev/null; then
                tmux kill-session -t g2ray_keepalive
                echo -e "\n  ${RED}■ Anti-Sleep disabled.${NC}"
            else
                enable_anti_sleep
                echo -e "\n  ${GREEN}▶ Anti-Sleep enabled.${NC}"
            fi
            sleep 2
            ;;
        8)
            echo -e "\n  ${DIM}This old public-sharing option has been removed. Keep generated configs for personal/test use only.${NC}"
            sleep 2
            ;;
        9)
            refresh_screen
            read -r _TD _TU <<< "$(get_data_usage)"
            _TD=${_TD:-0}; _TU=${_TU:-0}
            if (( _TD == 0 && _TU == 0 )); then
                echo -e "\n  ${DIM}No traffic data recorded yet. Connect and browse first.${NC}\n"
            else
                _TT=$(( _TD + _TU ))
                echo -e "\n  ${GREEN}● Data Usage (All Sessions)${NC}"
                echo -e "  Download (RX) : ${WHITE}$(format_bytes "$_TD")${NC}"
                echo -e "  Upload   (TX) : ${WHITE}$(format_bytes "$_TU")${NC}"
                echo -e "  Total Traffic : ${GREEN}$(format_bytes "$_TT")${NC}\n"
            fi
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        10) show_resource_stats ;;
        11)
            refresh_screen; echo ""
            estimate_quota
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        12)
            refresh_screen
            echo -e "\n  ${DIM}Fetching server details...${NC}\n"
            if command -v jq >/dev/null 2>&1; then
                _RES=$(curl -sf -m 5 https://ipinfo.io/json 2>/dev/null || echo "{}")
                _IP=$(printf '%s' "$_RES" | jq -r '.ip // empty' 2>/dev/null || true)
                if [[ -z "$_IP" ]]; then
                    echo -e "  ${RED}✖ Could not fetch location.${NC}"
                else
                    echo -e "  ${GREEN}● Server Location${NC}"
                    echo -e "  IP       : ${GREEN}$(printf '%s' "$_RES" | jq -r '.ip')${NC}"
                    echo -e "  Location : ${WHITE}$(printf '%s' "$_RES" | jq -r '.city'), $(printf '%s' "$_RES" | jq -r '.country')${NC}"
                    echo -e "  ISP/Host : ${WHITE}$(printf '%s' "$_RES" | jq -r '.org')${NC}"
                fi
            else
                echo -e "  ${RED}✖ jq not installed.${NC}"
            fi
            echo ""; echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        13)
            refresh_screen
            echo -e "\n  ${GREEN}● Live Engine Logs${NC}"
            rotate_log_file "$LOG_DIR/xray-error.log"
            if [[ -s "$LOG_DIR/xray.log" ]]; then
                echo -e "  ${WHITE}${B}Runtime log${NC}"
                tail -n 15 "$LOG_DIR/xray.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}Log file empty or missing.${NC}"
            fi
            echo -e "\n  ${WHITE}${B}Error log${NC}"
            if [[ -s "$LOG_DIR/xray-error.log" ]]; then
                tail -n 15 "$LOG_DIR/xray-error.log" | sed 's/^/  /'
            else
                echo -e "  ${DIM}No Xray errors logged.${NC}"
            fi
            echo -e "\n  ${DIM}(Xray access log is disabled; diagnostics shows probe and supervisor state.)${NC}\n"
            echo -ne "  ${DIM}Press Enter to return...${NC}"; read -r
            ;;
        14) show_diagnostics ;;
        15) show_recovery_waker ;;
        16) show_live_monitor ;;
        17) show_route_candidate_manager ;;
        18)
            if toggle_low_overhead_mode; then
                echo -e "\n  ${GREEN}Low-overhead mode enabled.${NC}"
                echo -e "  ${DIM}Background route refresh and INFO logs are reduced.${NC}"
            else
                echo -e "\n  ${WHITE}Low-overhead mode disabled.${NC}"
                echo -e "  ${DIM}Full background monitoring is restored.${NC}"
            fi
            sleep 2
            ;;
        49)
            if toggle_latency_focus_mode; then
                echo -e "\n  ${GREEN}Latency focus mode enabled.${NC}"
                echo -e "  ${DIM}Heartbeat and self-heal stay on; noncritical logs, route scans, exports, and remote messages are minimized.${NC}"
                echo -e "  ${DIM}Use this only while actively testing latency. Disable it before collecting support logs.${NC}"
            else
                echo -e "\n  ${WHITE}Latency focus mode disabled.${NC}"
                echo -e "  ${DIM}Normal diagnostics, route scans, exports, and logs are restored.${NC}"
            fi
            sleep 3
            ;;
        0) echo -e "\n  ${GREEN}Exiting G2ray Panel...${NC}"; exit 0 ;;
        *) echo -e "  ${RED}✖ Invalid option.${NC}"; sleep 1 ;;
    esac
done
