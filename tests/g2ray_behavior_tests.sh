#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/g2ray.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

reset_runtime_paths() {
    DATA_DIR="$TMP_ROOT/data"
    LOG_DIR="$TMP_ROOT/logs"
    QR_DIR="$DATA_DIR/qr"
    CONFIG_FILE="$DATA_DIR/config.json"
    UUID_FILE="$DATA_DIR/uuid.txt"
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
    SUBSCRIPTION_FILE="$TMP_ROOT/configs-subscription-base64.txt"
    CONFIG_META_FILE="$TMP_ROOT/configs-meta.json"
    LAST_GOOD_ROUTE_FILE="$DATA_DIR/last_good_route.txt"
    PINNED_ROUTE_FILE="$DATA_DIR/pinned_route.txt"
    MANUAL_ROUTE_CANDIDATES_FILE="$DATA_DIR/manual_route_candidates.txt"
    BLACKLISTED_ROUTE_CANDIDATES_FILE="$DATA_DIR/blacklisted_route_candidates.txt"
    ROUTE_SETTLING_HISTORY_FILE="$DATA_DIR/route_settling_history.tsv"
    PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
    RUNTIME_LOCK_DIR="$DATA_DIR/runtime.lock"
    LOG_FILE="$LOG_DIR/g2ray.log"
    STRUCTURED_LOG_FILE="$LOG_DIR/g2ray-events.jsonl"
    DIAGNOSTIC_LOG_FILE="$LOG_DIR/g2ray-diagnostics.log"
    WAKER_METADATA_FILE="$DATA_DIR/waker_metadata.txt"
    XRAY_PID_FILE="$DATA_DIR/xray.pid"
    rm -rf "$DATA_DIR" "$LOG_DIR"
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$QR_DIR"
    : > "$LOG_FILE"
    : > "$STRUCTURED_LOG_FILE"
    : > "$DIAGNOSTIC_LOG_FILE"
    LOG_MAX_BYTES=1048576
    LOG_ROTATE_KEEP=3
    MAX_FALLBACK_LINKS=20
    ROUTE_MONITOR_MAX_CANDIDATES=24
    ROUTE_HEALTH_TTL_SEC=300
    DNS_CACHE_TTL_SEC=300
    ROUTE_FAILURE_COOLDOWN_SEC=180
    LAST_GOOD_ROUTE_MAX_AGE_SEC=1800
    unset G2RAY_LOW_OVERHEAD G2RAY_LATENCY_FOCUS G2RAY_BENCH_MOCK G2RAY_BENCH_ISOLATED
}

export CODESPACE_NAME="behavior-space"
export XRAY_PORT="443"
export G2RAY_SOURCE_ONLY=1
export G2RAY_DATA_DIR="$TMP_ROOT/bootstrap-data"
export G2RAY_LOG_DIR="$TMP_ROOT/bootstrap-logs"
source "$SCRIPT"
ORIGINAL_RUN_GH="$(declare -f run_gh)"
reset_runtime_paths

test_port_visibility_is_throttled() {
    reset_runtime_paths
    PORT_PUBLIC_TTL_SEC=300
    XRAY_PORT=443
    CODESPACE_NAME="behavior-space"
    local calls_file="$TMP_ROOT/gh-calls.txt"
    : > "$calls_file"
    run_gh() {
        printf 'call\n' >> "$calls_file"
        return 0
    }

    ensure_codespace_port_public >/dev/null || fail "first public-port call failed"
    ensure_codespace_port_public >/dev/null || fail "cached public-port call failed"
    local calls
    calls=$(wc -l < "$calls_file" | tr -d ' ')
    [[ "$calls" -eq 1 ]] || fail "expected cached port visibility to avoid second gh call, got $calls"

    ensure_codespace_port_public force >/dev/null || fail "forced public-port call failed"
    calls=$(wc -l < "$calls_file" | tr -d ' ')
    [[ "$calls" -eq 2 ]] || fail "expected forced port visibility to call gh again, got $calls"
    pass "port visibility calls are throttled and forceable"
}

test_codespace_detection_uses_shared_environment_in_headless_ssh() {
    (
        reset_runtime_paths
        CODESPACE_NAME=""
        CODESPACE_ENV_JSON_FILE="$TMP_ROOT/shared-environment-variables.json"
        CODESPACE_SHARED_ENV_FILE="$TMP_ROOT/missing-shared.env"
        CONFIG_META_FILE="$TMP_ROOT/missing-configs-meta.json"
        WAKER_METADATA_FILE="$DATA_DIR/missing-waker-metadata.txt"
        PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
        printf '{ "CODESPACE_NAME": "real-codespace-name-123" }\n' > "$CODESPACE_ENV_JSON_FILE"
        run_gh() { return 1; }
        hostname() { printf 'codespaces-container-hostname\n'; }

        local detected
        detected="$(_detect_codespace_name)"
        [[ "$detected" == "real-codespace-name-123" ]] \
            || fail "headless detection used '$detected' instead of Codespaces shared environment"
    )
    pass "codespace detection uses shared environment in headless SSH sessions"
}

test_codespace_detection_uses_local_metadata_when_gh_is_unauthenticated() {
    (
        reset_runtime_paths
        CODESPACE_NAME=""
        CODESPACE_ENV_JSON_FILE="$TMP_ROOT/missing-shared-environment.json"
        CODESPACE_SHARED_ENV_FILE="$TMP_ROOT/missing-shared.env"
        CONFIG_META_FILE="$TMP_ROOT/missing-configs-meta.json"
        PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
        printf 'worker_url=https://example.invalid/wake\ncodespace_name=metadata-codespace-name\n' > "$WAKER_METADATA_FILE"
        run_gh() { return 1; }
        hostname() { printf 'codespaces-container-hostname\n'; }

        local detected
        detected="$(_detect_codespace_name)"
        [[ "$detected" == "metadata-codespace-name" ]] \
            || fail "headless detection used '$detected' instead of local waker metadata"
    )
    pass "codespace detection uses local metadata when gh is unauthenticated"
}

test_run_gh_uses_shared_codespaces_token_when_shell_is_unauthenticated() {
    (
        reset_runtime_paths
        eval "$ORIGINAL_RUN_GH"
        unset GH_TOKEN GITHUB_TOKEN
        CODESPACE_SHARED_ENV_FILE="$TMP_ROOT/shared.env"
        printf 'GITHUB_TOKEN=shared-token-for-test\n' > "$CODESPACE_SHARED_ENV_FILE"
        cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${GH_TOKEN:-}" != "shared-token-for-test" ]]; then
    echo "missing shared GH_TOKEN" >&2
    exit 31
fi
printf 'ok\n'
SH
        chmod +x "$TMP_ROOT/bin/gh"
        local output
        output="$(run_gh codespace ports -c behavior-space)" \
            || fail "run_gh did not use the shared Codespaces token when shell auth was missing"
        [[ "$output" == "ok" ]] || fail "run_gh returned unexpected output: $output"
    )
    pass "run_gh uses shared Codespaces token when shell is unauthenticated"
}

test_runtime_lock_serializes_operations_and_allows_reentry() {
    reset_runtime_paths
    RUNTIME_LOCK_WAIT_ATTEMPTS=1
    local owner_pid
    sleep 10 &
    owner_pid=$!
    mkdir -p "$RUNTIME_LOCK_DIR"
    printf '%s\n' "$owner_pid" > "$RUNTIME_LOCK_DIR/pid"
    local ran_file="$TMP_ROOT/runtime-lock-ran.txt"
    runtime_lock_probe() { printf 'ran\n' > "$ran_file"; }

    if with_runtime_lock runtime_lock_probe; then
        kill "$owner_pid" 2>/dev/null || true
        fail "runtime lock allowed operation while a live owner held the lock"
    fi
    kill "$owner_pid" 2>/dev/null || true
    [[ ! -e "$ran_file" ]] || fail "runtime operation ran while lock was busy"

    rm -rf "$RUNTIME_LOCK_DIR"
    mkdir -p "$RUNTIME_LOCK_DIR"
    printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid"
    with_runtime_lock runtime_lock_probe || fail "runtime lock did not clean up stale same-process lock"
    grep -Fxq 'ran' "$ran_file" || fail "runtime operation did not run after stale same-process lock cleanup"
    [[ ! -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not released after successful command"
    rm -f "$ran_file"

    rm -rf "$RUNTIME_LOCK_DIR"
    mkdir -p "$RUNTIME_LOCK_DIR"
    with_runtime_lock runtime_lock_probe || fail "runtime lock did not recover an empty lock directory"
    grep -Fxq 'ran' "$ran_file" || fail "runtime operation did not run after empty lock recovery"
    [[ ! -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not released after empty lock recovery"
    rm -f "$ran_file"

    rm -rf "$RUNTIME_LOCK_DIR"
    mkdir -p "$RUNTIME_LOCK_DIR"
    printf 'not-a-pid\n' > "$RUNTIME_LOCK_DIR/pid"
    with_runtime_lock runtime_lock_probe || fail "runtime lock did not recover malformed pid lock"
    grep -Fxq 'ran' "$ran_file" || fail "runtime operation did not run after malformed lock recovery"
    [[ ! -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not released after malformed lock recovery"
    rm -f "$ran_file"

    rm -rf "$RUNTIME_LOCK_DIR"
    runtime_lock_inner() { printf 'inner\n' > "$ran_file"; }
    runtime_lock_outer() { with_runtime_lock runtime_lock_inner; }
    with_runtime_lock runtime_lock_outer || fail "runtime lock was not reentrant for nested runtime operations"
    grep -Fxq 'inner' "$ran_file" || fail "nested runtime operation did not run"
    [[ ! -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not released after nested successful command"

    rm -rf "$RUNTIME_LOCK_DIR"
    runtime_lock_assert_held_and_fail() {
        [[ -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not held while command ran"
        [[ "$(cat "$RUNTIME_LOCK_DIR/pid" 2>/dev/null || true)" == "$$" ]] || fail "runtime lock owner was not current shell"
        return 7
    }
    local rc=0
    if with_runtime_lock runtime_lock_assert_held_and_fail; then
        fail "runtime lock wrapper swallowed command failure"
    else
        rc=$?
    fi
    [[ "$rc" -eq 7 ]] || fail "runtime lock wrapper did not preserve command failure status, got $rc"
    [[ ! -d "$RUNTIME_LOCK_DIR" ]] || fail "runtime lock was not released after a failing command"

    pass "runtime lock serializes operations and allows same-process reentry"
}

test_port_visibility_cache_is_scoped_by_codespace_and_port() {
    reset_runtime_paths
    PORT_PUBLIC_TTL_SEC=300
    CODESPACE_NAME="behavior-space-a"
    XRAY_PORT=443
    local calls_file="$TMP_ROOT/gh-scoped-calls.txt"
    : > "$calls_file"
    run_gh() {
        printf '%s:%s\n' "$CODESPACE_NAME" "$XRAY_PORT" >> "$calls_file"
        return 0
    }

    ensure_codespace_port_public >/dev/null || fail "first scoped public-port call failed"
    CODESPACE_NAME="behavior-space-b"
    ensure_codespace_port_public >/dev/null || fail "second codespace public-port call failed"
    CODESPACE_NAME="behavior-space-a"
    XRAY_PORT=8443
    ensure_codespace_port_public >/dev/null || fail "second port public-port call failed"

    local calls
    calls=$(wc -l < "$calls_file" | tr -d ' ')
    [[ "$calls" -eq 3 ]] || fail "expected port-public cache to be scoped by codespace and port, got $calls calls"
    pass "port visibility cache is scoped by codespace and port"
}

test_cached_route_order_uses_reliability_then_average_latency() {
    reset_runtime_paths
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	10	true
2026-05-30T00:00:00Z	20.0.0.2	200	80	true
2026-05-30T00:00:00Z	20.0.0.3	404	10	false
EOF
    cat > "$ROUTE_STATS_FILE" <<'EOF'
20.0.0.1	5	1	4	10	10	10	10	200	true	2026-05-30T00:00:00Z
20.0.0.2	5	5	0	80	70	90	80	200	true	2026-05-30T00:00:00Z
EOF
    cat > "$LAST_GOOD_ROUTE_FILE" <<'EOF'
ip=20.0.0.1
http_status=200
latency_ms=10
source=test
checked_at=2026-05-30T00:00:00Z
EOF
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.2" ]] || fail "reliable route was not preferred over a flaky fast last probe"
    [[ "${routes[1]:-}" == "20.0.0.1" ]] || fail "flaky route was not kept after reliable route"
    pass "cached route health orders exports by reliability and average latency"
}

test_cached_route_order_uses_recent_weighted_score() {
    reset_runtime_paths
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	120	true	dns	ready
2026-05-30T00:00:00Z	20.0.0.2	200	260	true	dns	ready
EOF
    cat > "$ROUTE_STATS_FILE" <<'EOF'
20.0.0.1	10	10	0	100	80	900	120	200	true	2026-05-30T00:00:00Z	900	0	ready
20.0.0.2	10	10	0	250	220	300	260	200	true	2026-05-30T00:00:00Z	250	0	ready
EOF
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.2" ]] || fail "recent weighted route score did not outrank stale cumulative average"
    [[ "${routes[1]:-}" == "20.0.0.1" ]] || fail "route with stale cumulative average was not kept second"
    pass "cached route health orders exports by recent weighted score"
}

test_last_good_route_decays_before_breaking_ties() {
    reset_runtime_paths
    LAST_GOOD_ROUTE_MAX_AGE_SEC=60
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	50	true	dns	ready
2026-05-30T00:00:00Z	20.0.0.2	200	50	true	dns	ready
EOF
    cat > "$LAST_GOOD_ROUTE_FILE" <<EOF
ip=20.0.0.2
http_status=200
latency_ms=50
source=test
checked_at=$now
EOF
    local routes
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.2" ]] || fail "fresh last-good route did not break an equal route tie"

    sed -i 's/^checked_at=.*/checked_at=2000-01-01T00:00:00Z/' "$LAST_GOOD_ROUTE_FILE"
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.1" ]] || fail "stale last-good route still influenced equal route ordering"
    pass "last-good route preference decays before breaking route ties"
}

test_route_candidate_stats_track_average_and_success_rate() {
    reset_runtime_paths
    update_route_candidate_stats 20.0.0.1 200 100
    update_route_candidate_stats 20.0.0.1 404 900
    update_route_candidate_stats 20.0.0.1 200 300

    local row
    row=$(awk -F '\t' '$1 == "20.0.0.1" {print $0}' "$ROUTE_STATS_FILE")
    [[ "$row" == $'20.0.0.1\t3\t2\t1\t200\t100\t300\t300\t200\ttrue\t'* ]] \
        || fail "route stats did not track samples/success/failure/average/min/max/last: $row"
    printf '2026-05-30T00:00:00Z\t20.0.0.1\t200\t300\ttrue\n' > "$ROUTE_HEALTH_FILE"
    route_candidate_health_summary | grep -Fq 'avg=200ms success=2/3' \
        || fail "route candidate summary does not show average latency and success ratio"
    pass "route candidate stats track rolling average and reliability"
}

test_route_health_records_source_reason_and_recent_average() {
    reset_runtime_paths
    record_route_candidate_health 20.0.0.1 200 100 dns ready
    record_route_candidate_health 20.0.0.1 0 900 dns timeout
    record_route_candidate_health 20.0.0.1 200 300 dns ready

    local health_row stats_row
    health_row=$(tail -n 1 "$ROUTE_HEALTH_FILE")
    [[ "$health_row" == *$'\t20.0.0.1\t200\t300\ttrue\tdns\tready' ]] \
        || fail "route health did not record source and reason: $health_row"
    stats_row=$(awk -F '\t' '$1 == "20.0.0.1" {print $0}' "$ROUTE_STATS_FILE")
    awk -F '\t' '$1 == "20.0.0.1" && $12 ~ /^[0-9]+$/ && $13 ~ /^[0-9]+$/ && $14 == "ready" { found = 1 } END { exit !found }' "$ROUTE_STATS_FILE" \
        || fail "route stats did not persist ewma/recent failures/reason metadata: $stats_row"
    pass "route health records source, failure reason, and recent average metadata"
}

test_route_failure_reason_classifier() {
    reset_runtime_paths
    [[ "$(route_failure_reason_for_status 200 "")" == "ready" ]] || fail "HTTP 200 should classify ready"
    [[ "$(route_failure_reason_for_status 400 "")" == "ready" ]] || fail "HTTP 400 should classify ready"
    [[ "$(route_failure_reason_for_status 404 "")" == "route_settling_404" ]] || fail "HTTP 404 should classify route settling"
    [[ "$(route_failure_reason_for_status 0 "operation timed out")" == "timeout_or_unreachable" ]] || fail "HTTP 0 timeout should classify unreachable"
    [[ "$(route_failure_reason_for_status 503 "")" == "edge_or_origin_error" ]] || fail "HTTP 503 should classify edge/origin error"
    pass "route failure reason classifier is actionable"
}

test_xhttp_probe_metrics_reports_curl_failure_reason() {
    reset_runtime_paths
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    curl() { return 28; }

    local code ms reason
    read -r code ms reason < <(xhttp_probe_metrics external 20.0.0.1)
    unset -f curl
    [[ "$code" == "0" ]] || fail "curl timeout probe did not report HTTP 0: $code"
    [[ "$reason" == "timeout_or_unreachable" ]] || fail "curl timeout probe did not report actionable reason: $reason"
    pass "xhttp probe metrics reports curl failure reason"
}

test_cached_route_order_prefers_pinned_route_then_latency_without_stats() {
    reset_runtime_paths
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	500	true
2026-05-30T00:00:00Z	20.0.0.2	200	40	true
2026-05-30T00:00:00Z	20.0.0.3	200	60	true
EOF
    cat > "$LAST_GOOD_ROUTE_FILE" <<'EOF'
ip=20.0.0.2
http_status=200
latency_ms=40
source=test
checked_at=2026-05-30T00:00:00Z
EOF
    pin_route_candidate 20.0.0.1
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.1" ]] || fail "pinned route was not preferred first"
    [[ "${routes[1]:-}" == "20.0.0.2" ]] || fail "unpinned routes were not ordered by latency when stats were absent"
    pass "cached route health orders exports by pinned route, then latency when stats are absent"
}

test_route_monitor_default_and_hard_cap_are_wide_but_bounded() {
    reset_runtime_paths
    ROUTE_MONITOR_MAX_CANDIDATES=""
    [[ "$(route_monitor_max_candidates)" == "24" ]] || fail "empty route monitor max did not default to 24"

    ROUTE_MONITOR_MAX_CANDIDATES=0
    [[ "$(route_monitor_max_candidates)" == "24" ]] || fail "zero route monitor max did not default to 24"

    ROUTE_MONITOR_MAX_CANDIDATES=12
    [[ "$(route_monitor_max_candidates)" == "12" ]] || fail "valid route monitor max was not honored"

    ROUTE_MONITOR_MAX_CANDIDATES=99
    [[ "$(route_monitor_max_candidates)" == "32" ]] || fail "route monitor max was not hard-capped at 32"

    pass "route monitor scans enough candidates for 20 exports while staying bounded"
}

test_blacklisted_route_is_excluded_from_cached_exports() {
    reset_runtime_paths
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	40	true
2026-05-30T00:00:00Z	20.0.0.2	200	50	true
EOF
    blacklist_route_candidate 20.0.0.1
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[*]}" == "20.0.0.2" ]] || fail "blacklisted route was not excluded from cached exports"
    pass "blacklisted cached routes are excluded from exports"
}

test_manual_route_candidates_are_validated_and_resettable() {
    reset_runtime_paths
    add_manual_route_candidate 20.0.0.9 || fail "valid manual route was rejected"
    if add_manual_route_candidate 20.0.0.9; then
        fail "duplicate manual route was accepted as a new candidate"
    fi
    if add_manual_route_candidate "20.0.0.999"; then
        fail "invalid manual route was accepted"
    fi
    grep -Fxq "20.0.0.9" "$MANUAL_ROUTE_CANDIDATES_FILE" || fail "manual route was not persisted"
    pin_route_candidate 20.0.0.9
    blacklist_route_candidate 20.0.0.2
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.9	200	40	true
EOF
    cat > "$ROUTE_STATS_FILE" <<'EOF'
20.0.0.9	1	1	0	40	40	40	40	200	true	2026-05-30T00:00:00Z
EOF
    cat > "$LAST_GOOD_ROUTE_FILE" <<'EOF'
ip=20.0.0.9
http_status=200
latency_ms=40
source=test
checked_at=2026-05-30T00:00:00Z
EOF
    printf '1780000000\tbehavior.example\tdns_google\t20.0.0.9\n' > "$DNS_CANDIDATE_CACHE_FILE"
    reset_route_candidate_cache
    grep -Fxq "20.0.0.9" "$MANUAL_ROUTE_CANDIDATES_FILE" || fail "cache reset removed manual route preferences"
    [[ "$(cat "$PINNED_ROUTE_FILE" 2>/dev/null)" == "20.0.0.9" ]] || fail "cache reset removed pinned route preference"
    grep -Fxq "20.0.0.2" "$BLACKLISTED_ROUTE_CANDIDATES_FILE" || fail "cache reset removed blacklist preferences"
    [[ ! -e "$ROUTE_HEALTH_FILE" ]] || fail "route health cache was not reset"
    [[ ! -e "$ROUTE_STATS_FILE" ]] || fail "route stats cache was not reset"
    [[ ! -e "$LAST_GOOD_ROUTE_FILE" ]] || fail "last-good route cache was not reset"
    [[ ! -e "$ROUTE_COOLDOWN_FILE" ]] || fail "route cooldown cache was not reset"
    [[ ! -e "$DNS_CANDIDATE_CACHE_FILE" ]] || fail "DNS candidate cache was not reset"
    reset_route_candidate_state
    [[ ! -e "$MANUAL_ROUTE_CANDIDATES_FILE" ]] || fail "manual route file was not reset"
    [[ ! -e "$PINNED_ROUTE_FILE" ]] || fail "pinned route file was not reset"
    [[ ! -e "$BLACKLISTED_ROUTE_CANDIDATES_FILE" ]] || fail "blacklist route file was not reset"
    pass "manual route candidates are validated and route manager cache/state resets are safe"
}

test_route_preferences_clear_matching_cooldowns() {
    reset_runtime_paths
    local future
    future=$(( $(date +%s) + 3600 ))

    printf '%s\t20.0.0.9\ttimeout_or_unreachable\n' "$future" > "$ROUTE_COOLDOWN_FILE"
    add_manual_route_candidate 20.0.0.9 || fail "manual route add failed"
    [[ ! -e "$ROUTE_COOLDOWN_FILE" ]] || fail "manual route add did not clear matching cooldown"

    printf '%s\t20.0.0.10\ttimeout_or_unreachable\n' "$future" > "$ROUTE_COOLDOWN_FILE"
    pin_route_candidate 20.0.0.10 || fail "pin route failed"
    [[ ! -e "$ROUTE_COOLDOWN_FILE" ]] || fail "pinning a route did not clear matching cooldown"

    printf '%s\t20.0.0.11\ttimeout_or_unreachable\n' "$future" > "$ROUTE_COOLDOWN_FILE"
    printf '20.0.0.11\n' > "$BLACKLISTED_ROUTE_CANDIDATES_FILE"
    unblacklist_route_candidate 20.0.0.11 || fail "unblacklist route failed"
    [[ ! -e "$ROUTE_COOLDOWN_FILE" ]] || fail "unblacklisting a route did not clear matching cooldown"
    pass "manual, pinned, and unblacklisted routes clear matching cooldowns"
}

test_route_health_refresh_preserves_cache_when_all_candidates_are_cooled_down() {
    reset_runtime_paths
    touch "$CONFIG_FILE"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    ROUTE_PROBE_CONCURRENCY=2
    local future original_resolver original_probe
    future=$(( $(date +%s) + 3600 ))
    original_resolver="$(declare -f resolve_domain_ips_with_sources)"
    original_probe="$(declare -f xhttp_probe_metrics)"
    printf '2026-05-30T00:00:00Z\t20.0.0.1\t200\t50\ttrue\tdns\tready\n' > "$ROUTE_HEALTH_FILE"
    printf '%s\t20.0.0.2\ttimeout_or_unreachable\n%s\t20.0.0.3\ttimeout_or_unreachable\n' "$future" "$future" > "$ROUTE_COOLDOWN_FILE"
    resolve_domain_ips_with_sources() {
        printf 'dns\t20.0.0.2\n'
        printf 'dns\t20.0.0.3\n'
    }
    xhttp_probe_metrics() { fail "cooled-down route was probed unexpectedly"; }

    refresh_route_candidate_health || fail "route health refresh failed when all candidates were cooled down"
    eval "$original_resolver"
    eval "$original_probe"
    grep -Fq $'20.0.0.1\t200\t50\ttrue' "$ROUTE_HEALTH_FILE" \
        || fail "route health refresh replaced the last known-good cache when every candidate was skipped"
    grep -Fq 'skipped_all_candidates' "$LOG_FILE" || fail "skipped-all-candidates event was not logged"
    pass "route health refresh preserves previous cache when all candidates are cooled down"
}

test_route_health_refresh_preserves_cache_when_all_probes_are_unusable() {
    reset_runtime_paths
    printf '{}\n' > "$CONFIG_FILE"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    ROUTE_MONITOR_MAX_CANDIDATES=2
    ROUTE_PROBE_CONCURRENCY=2
    ROUTE_FAILURE_COOLDOWN_SEC=0
    local original_resolver original_probe
    original_resolver="$(declare -f resolve_domain_ips_with_sources)"
    original_probe="$(declare -f xhttp_probe_metrics)"
    printf '2026-05-30T00:00:00Z\t20.0.0.1\t200\t50\ttrue\tdns\tready\n' > "$ROUTE_HEALTH_FILE"
    resolve_domain_ips_with_sources() {
        printf 'dns\t20.0.0.2\n'
        printf 'dns\t20.0.0.3\n'
    }
    xhttp_probe_metrics() { printf '404 25 route_settling_404\n'; }

    refresh_route_candidate_health || fail "route health refresh failed during all-404 settling"
    eval "$original_resolver"
    eval "$original_probe"
    grep -Fq $'20.0.0.1\t200\t50\ttrue' "$ROUTE_HEALTH_FILE" \
        || fail "route health refresh replaced the last known-good cache when every probe was unusable"
    ! grep -Fq $'20.0.0.2\t404' "$ROUTE_HEALTH_FILE" \
        || fail "all-unusable refresh should not replace health cache with temporary 404 probes"
    pass "route health refresh preserves previous cache when every probe is temporarily unusable"
}

test_route_health_refresh_mixes_provider_candidates_before_stale_cache_cap() {
    reset_runtime_paths
    printf '{}\n' > "$CONFIG_FILE"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    ROUTE_MONITOR_MAX_CANDIDATES=3
    ROUTE_PROBE_CONCURRENCY=1
    local original_provider original_probe probed_file
    original_provider="$(declare -f resolve_dns_provider_ips_with_sources)"
    original_probe="$(declare -f xhttp_probe_metrics)"
    probed_file="$TMP_ROOT/probed-provider-mix.txt"
    printf '2026-05-30T00:00:00Z\t20.0.0.1\t200\t500\ttrue\tcache\tready\n' > "$ROUTE_HEALTH_FILE"
    printf '2026-05-30T00:00:00Z\t20.0.0.2\t200\t501\ttrue\tcache\tready\n' >> "$ROUTE_HEALTH_FILE"
    printf '2026-05-30T00:00:00Z\t20.0.0.3\t200\t502\ttrue\tcache\tready\n' >> "$ROUTE_HEALTH_FILE"
    resolve_dns_provider_ips_with_sources() {
        printf 'dns\t20.0.0.9\n'
    }
    xhttp_probe_metrics() {
        printf '%s\n' "$2" >> "$probed_file"
        printf '200 10 ready\n'
    }

    refresh_route_candidate_health || fail "route health refresh failed with provider/cache mix"
    eval "$original_provider"
    eval "$original_probe"
    grep -Fxq '20.0.0.9' "$probed_file" \
        || fail "fresh provider candidate was starved by stale cached routes under the probe cap"
    pass "route health refresh mixes provider candidates before stale cache can fill the cap"
}

test_route_preference_write_failures_return_failure() {
    (
        reset_runtime_paths
        write_unique_route_file() { return 1; }
        if add_manual_route_candidate 20.0.0.9; then
            fail "manual route add reported success after write failure"
        fi
        if blacklist_route_candidate 20.0.0.9; then
            fail "blacklist route reported success after write failure"
        fi
    )
    (
        reset_runtime_paths
        _atomic_write() { return 1; }
        if pin_route_candidate 20.0.0.9; then
            fail "pin route reported success after write failure"
        fi
    )
    pass "route preference write failures do not report success"
}

test_pinned_route_is_a_durable_candidate_source() {
    reset_runtime_paths
    DEFAULT_FALLBACK_IPS=""
    G2RAY_EXTRA_FALLBACK_IPS=""
    json_dns_ips() { return 0; }
    curl_remote_ip() { return 0; }
    pin_route_candidate 20.0.0.7 || fail "pin route failed"
    mapfile -t routes < <(resolve_domain_ips "")
    [[ "${routes[0]:-}" == "20.0.0.7" ]] || fail "pinned route was not included in resolver candidates"
    pass "pinned route stays in resolver candidates after cache refresh"
}

test_cached_route_health_is_a_durable_candidate_source() {
    reset_runtime_paths
    DEFAULT_FALLBACK_IPS=""
    G2RAY_EXTRA_FALLBACK_IPS=""
    json_dns_ips() { return 0; }
    curl_remote_ip() { return 0; }
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.8	200	70	true
EOF
    mapfile -t routes < <(resolve_domain_ips "")
    [[ "${routes[0]:-}" == "20.0.0.8" ]] || fail "cached route health was not reused as a resolver candidate"
    pass "cached route health keeps discovered candidates durable"
}

test_dns_candidate_cache_reuses_fresh_provider_results() {
    (
        reset_runtime_paths
        DEFAULT_FALLBACK_IPS=""
        G2RAY_EXTRA_FALLBACK_IPS=""
        DNS_CACHE_TTL_SEC=300
        dig() { return 1; }
        getent() { return 1; }
        curl_remote_ip() { return 0; }
        local calls_file="$TMP_ROOT/dns-json-calls.txt"
        : > "$calls_file"
        json_dns_ips() {
            printf 'call\n' >> "$calls_file"
            printf '20.0.0.9\n'
        }

        mapfile -t rows < <(resolve_domain_ips_with_sources "behavior.example")
        printf '%s\n' "${rows[@]}" | awk -F '\t' '$2 == "20.0.0.9" {found = 1} END {exit !found}' \
            || fail "resolver did not use provider result: ${rows[*]:-none}"
        [[ -s "$DNS_CANDIDATE_CACHE_FILE" ]] || fail "resolver did not write DNS candidate cache"

        json_dns_ips() { fail "fresh DNS candidate cache did not suppress provider lookup"; }
        mapfile -t rows < <(resolve_domain_ips_with_sources "behavior.example")
        printf '%s\n' "${rows[@]}" | awk -F '\t' '$2 == "20.0.0.9" {found = 1} END {exit !found}' \
            || fail "resolver did not reuse fresh DNS candidate cache: ${rows[*]:-none}"
    )
    pass "DNS candidate cache reuses fresh provider results"
}

test_last_known_state_scans_full_current_log() {
    reset_runtime_paths
    for _i in $(seq 1 700); do
        printf '2026-05-30T00:00:00Z [INFO] filler event\n' >> "$LOG_FILE"
    done
    printf '2026-05-30T00:01:00Z [WARN] port_public failed port=443 detail=test\n' >> "$LOG_FILE"
    for _i in $(seq 1 700); do
        printf '2026-05-30T00:02:00Z [INFO] health engine=running listener=open\n' >> "$LOG_FILE"
    done
    local summary
    summary="$(last_known_state_summary)"
    grep -Fq 'port_public failed port=443 detail=test' <<< "$summary" \
        || fail "last known state did not scan beyond the recent log tail"
    pass "last known state scans the full current log"
}

test_usable_fallback_ips_uses_fresh_cache() {
    reset_runtime_paths
    ROUTE_HEALTH_TTL_SEC=300
    MAX_FALLBACK_LINKS=2
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.5	200	70	true
2026-05-30T00:00:00Z	20.0.0.6	200	80	true
EOF
    xhttp_probe_metrics() { fail "usable_fallback_ips should not live-probe while route health cache is fresh"; }
    resolve_domain_ips() { fail "usable_fallback_ips should not resolve DNS while route health cache is fresh"; }
    mapfile -t routes < <(usable_fallback_ips)
    [[ "${routes[*]}" == "20.0.0.5 20.0.0.6" ]] || fail "usable_fallback_ips did not return cached usable routes"
    pass "usable fallback exports use fresh cached route health"
}

test_usable_fallback_ips_fills_partial_fresh_cache() {
    reset_runtime_paths
    ROUTE_HEALTH_TTL_SEC=300
    MAX_FALLBACK_LINKS=4
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.5	200	70	true
2026-05-30T00:00:00Z	20.0.0.6	200	80	true
EOF
    resolve_domain_ips() {
        printf '%s\n' 20.0.0.5 20.0.0.6 20.0.0.7 20.0.0.8 20.0.0.9
    }
    local probes_file="$TMP_ROOT/partial-cache-probes.txt"
    : > "$probes_file"
    xhttp_probe_metrics() {
        printf '%s\n' "$2" >> "$probes_file"
        printf '200 60 ready\n'
    }

    mapfile -t routes < <(usable_fallback_ips)
    [[ "${routes[*]}" == "20.0.0.5 20.0.0.6 20.0.0.7 20.0.0.8" ]] \
        || fail "usable_fallback_ips did not fill partial cached routes with live probes"
    ! grep -Fq '20.0.0.5' "$probes_file" \
        || fail "usable_fallback_ips live-probed a route already emitted from cache"
    pass "usable fallback exports fill partial fresh cache with live-probed routes"
}

test_usable_fallback_ips_caps_live_probe_fallback() {
    reset_runtime_paths
    MAX_FALLBACK_LINKS=1
    ROUTE_MONITOR_MAX_CANDIDATES=3
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    refresh_route_candidate_health() { return 0; }
    resolve_domain_ips() {
        for i in $(seq 1 12); do
            printf '20.0.0.%s\n' "$i"
        done
    }
    local probes_file="$TMP_ROOT/live-fallback-probes.txt"
    : > "$probes_file"
    xhttp_probe_metrics() {
        printf 'probe\n' >> "$probes_file"
        printf '404 50\n'
    }

    usable_fallback_ips >/dev/null || true
    local probes
    probes=$(wc -l < "$probes_file" | tr -d ' ')
    [[ "$probes" -eq 3 ]] || fail "live fallback probe path was not capped at route monitor max; got $probes"
    pass "usable fallback live probes are bounded by route monitor cap"
}

test_xhttp_config_path_is_cached_by_config_content() {
    reset_runtime_paths
    cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"vless-in","streamSettings":{"xhttpSettings":{"path":"/cached"}}}]}
JSON
    local jq_calls="$TMP_ROOT/jq-calls.txt"
    : > "$jq_calls"
    jq() {
        printf 'call\n' >> "$jq_calls"
        sed -nE 's/.*"path":"([^"]+)".*/\1/p' "$CONFIG_FILE"
    }
    local first second third calls old_mtime
    first="$(xhttp_config_path)"
    second="$(xhttp_config_path)"
    old_mtime=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || printf '')
    cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"vless-in","streamSettings":{"xhttpSettings":{"path":"/fresh"}}}]}
JSON
    if [[ -n "$old_mtime" ]]; then
        touch -d "@$old_mtime" "$CONFIG_FILE" 2>/dev/null || true
    fi
    third="$(xhttp_config_path)"
    unset -f jq
    calls=$(wc -l < "$jq_calls" | tr -d ' ')
    [[ "$first" == "/cached" && "$second" == "/cached" && "$third" == "/fresh" ]] \
        || fail "xhttp_config_path did not cache by content safely: first=$first second=$second third=$third"
    [[ "$calls" -eq 2 ]] || fail "xhttp_config_path parsed config $calls times instead of once per content version"
    pass "xHTTP config path is cached by config file content"
}

test_boot_status_helpers_record_silent_start_result() {
    reset_runtime_paths
    write_boot_status "route_settling" "silent_start" "Route still settling" "404" "33"
    python -m json.tool "$BOOT_STATUS_FILE" >/dev/null || fail "boot status is not valid JSON"
    grep -Fq '"status": "route_settling"' "$BOOT_STATUS_FILE" || fail "boot status missing status"
    boot_status_summary | grep -Fq 'route_settling' || fail "boot status summary missing status"
    pass "boot status helpers persist readable startup state"
}

test_config_exports_write_local_only_metadata() {
    reset_runtime_paths
    BASE_DIR="$TMP_ROOT"
    MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
    SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
    CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    GITHUB_USER="tester"
    write_config_exports_from_links "vless://example-one" "vless://example-two" >/dev/null

    python -m json.tool "$CONFIG_META_FILE" >/dev/null || fail "config metadata is not valid JSON"
    grep -Fq '"config_count": 2' "$CONFIG_META_FILE" || fail "config metadata missing count"
    grep -Fq '"subscription_scope": "local_codespace_only"' "$CONFIG_META_FILE" \
        || fail "config metadata does not mark subscription as local-only"
    ! grep -Fq '"subscription_url"' "$CONFIG_META_FILE" \
        || fail "config metadata still exposes a subscription URL"
    pass "config exports write machine-readable local-only metadata"
}

test_config_exports_are_stable_client_artifacts() {
    reset_runtime_paths
    BASE_DIR="$TMP_ROOT"
    MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
    SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
    CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
    local link1='vless://uuid@example.com:443?encryption=none#one'
    local link2='vless://uuid@20.0.0.1:443?encryption=none#two'

    write_config_exports_from_links "$link1" "$link2" >/dev/null
    mapfile -t mobile_lines < "$MOBILE_CONFIG_FILE"
    [[ "${mobile_lines[0]:-}" == "$link1" && "${mobile_lines[1]:-}" == "$link2" ]] \
        || fail "mobile export did not preserve generated link ordering"
    python - "$SUBSCRIPTION_FILE" "$link1" "$link2" <<'PY' || fail "subscription export does not decode to expected VLESS links"
import base64, pathlib, sys
decoded = base64.b64decode(pathlib.Path(sys.argv[1]).read_text()).decode().splitlines()
if decoded != [sys.argv[2], sys.argv[3]]:
    raise SystemExit(decoded)
PY
    pass "config exports produce stable mobile and base64 subscription artifacts"
}

test_generated_links_follow_configured_xhttp_path() {
    reset_runtime_paths
    BASE_DIR="$TMP_ROOT"
    MOBILE_CONFIG_FILE="$BASE_DIR/configs-to-copy-for-mobile.txt"
    SUBSCRIPTION_FILE="$BASE_DIR/configs-subscription-base64.txt"
    CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    GITHUB_USER="tester"
    jq() { printf '/custom\n'; }
    printf '11111111-2222-3333-4444-555555555555\n' > "$UUID_FILE"
    cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {
      "tag": "vless-in",
      "streamSettings": {
        "xhttpSettings": {
          "path": "/custom"
        }
      }
    }
  ]
}
JSON

    local link
    link="$(generate_link_for_address "20.0.0.1" "-ip1")"
    unset -f jq
    [[ "$link" == *"path=%2Fcustom"* ]] \
        || fail "generated VLESS link did not use configured XHTTP path: $link"
    write_config_exports_from_links "$link" >/dev/null
    grep -Fq 'path=%2Fcustom' "$MOBILE_CONFIG_FILE" \
        || fail "mobile export did not preserve configured XHTTP path"
    pass "generated links follow configured XHTTP path"
}

test_config_metadata_sanitizes_invalid_max_fallback_links() {
    reset_runtime_paths
    BASE_DIR="$TMP_ROOT"
    CONFIG_META_FILE="$BASE_DIR/configs-meta.json"
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    MAX_FALLBACK_LINKS="not-a-number"
    GITHUB_USER="tester"

    write_config_metadata 1 "abc123"
    python -m json.tool "$CONFIG_META_FILE" >/dev/null || fail "metadata JSON broke when max fallback links was invalid"
    grep -Fq '"max_fallback_links": 20' "$CONFIG_META_FILE" \
        || fail "invalid max fallback link setting was not sanitized to default 20"
    pass "config metadata sanitizes invalid max fallback link settings"
}

test_bench_json_reports_deterministic_budgets() {
    reset_runtime_paths
    local output bench_file bench_root command_output
    if ! output="$(
        G2RAY_BENCH_MOCK=1 \
        G2RAY_BENCH_BUDGET_EXPORT_MS=10000 \
        G2RAY_BENCH_BUDGET_DOCTOR_MS=6000 \
        G2RAY_BENCH_BUDGET_RECOVER_JSON_MS=6000 \
        bench_json --mock
    )"; then
        printf '%s\n' "$output"
        fail "bench_json returned nonzero under mock budgets"
    fi
    bench_file="$TMP_ROOT/bench.json"
    printf '%s\n' "$output" > "$bench_file"
    python - "$bench_file" <<'PY' || fail "bench_json did not return valid budget JSON"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["mocked"] is True
assert data["budgets_ok"] is True
names = {case["name"] for case in data["cases"]}
required = {"config_path_cache", "route_ordering", "export_generation", "doctor_json", "recover_json_contract"}
missing = required - names
if missing:
    raise AssertionError(f"missing benchmark cases: {sorted(missing)}")
for case in data["cases"]:
    assert isinstance(case["elapsed_ms"], int)
    assert case["elapsed_ms"] <= case["budget_ms"], case
PY
    bench_root="$TMP_ROOT/bench-command-root"
    command_output="$TMP_ROOT/bench-command.json"
    mkdir -p "$bench_root"
    cp "$SCRIPT" "$bench_root/g2ray.sh"
    if ! (
        cd "$bench_root" && \
        env -u G2RAY_SOURCE_ONLY \
            G2RAY_BENCH_BUDGET_EXPORT_MS=10000 \
            G2RAY_BENCH_BUDGET_DOCTOR_MS=6000 \
            G2RAY_BENCH_BUDGET_RECOVER_JSON_MS=6000 \
            bash ./g2ray.sh bench --json --mock > "$command_output"
    ); then
        cat "$command_output" 2>/dev/null || true
        fail "bench --json --mock command returned nonzero under mock budgets"
    fi
    [[ ! -e "$bench_root/data" && ! -e "$bench_root/logs" ]] \
        || fail "bench --json --mock created runtime dirs in the command working tree"
    python - "$command_output" <<'PY' || fail "bench --json --mock command did not return valid passing JSON"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
assert data["ok"] is True
assert data["budgets_ok"] is True
PY
    if ! output="$(
        G2RAY_BENCH_BUDGET_CONFIG_PATH_MS=not-a-number \
        G2RAY_BENCH_BUDGET_EXPORT_MS=10000 \
        G2RAY_BENCH_BUDGET_DOCTOR_MS=6000 \
        G2RAY_BENCH_BUDGET_RECOVER_JSON_MS=6000 \
        G2RAY_BENCH_MOCK=1 \
        bench_json --mock
    )"; then
        printf '%s\n' "$output"
        fail "bench_json failed while sanitizing invalid budget environment values"
    fi
    printf '%s\n' "$output" > "$bench_file"
    python - "$bench_file" <<'PY' || fail "bench_json did not sanitize invalid budget environment values"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
case = next(item for item in data["cases"] if item["name"] == "config_path_cache")
assert case["budget_ms"] == 800, case
assert data["ok"] is True
PY
    pass "bench --json reports deterministic performance budgets"
}

test_low_overhead_mode_suppresses_info_logs() {
    reset_runtime_paths
    enable_low_overhead_mode
    log_event INFO "low_overhead_info_should_skip"
    log_event WARN "low_overhead_warn_should_stay"
    ! grep -Fq "low_overhead_info_should_skip" "$LOG_FILE" || fail "low overhead mode did not suppress INFO logs"
    grep -Fq "low_overhead_warn_should_stay" "$LOG_FILE" || fail "low overhead mode suppressed WARN logs"
    disable_low_overhead_mode
    pass "low-overhead mode suppresses nonessential INFO logs only"
}

test_low_overhead_env_can_be_overridden_by_toggle() {
    reset_runtime_paths
    G2RAY_LOW_OVERHEAD=1
    low_overhead_enabled || fail "low overhead env flag did not enable mode"
    disable_low_overhead_mode
    if low_overhead_enabled; then
        fail "low overhead disable toggle did not override the env flag"
    fi
    enable_low_overhead_mode
    low_overhead_enabled || fail "low overhead enable toggle did not re-enable mode"
    unset G2RAY_LOW_OVERHEAD
    disable_low_overhead_mode
    pass "low-overhead mode can be explicitly toggled even when env default is enabled"
}

test_low_overhead_keeps_important_state_logs() {
    reset_runtime_paths
    enable_low_overhead_mode
    log_event INFO "health chatty_probe_should_skip"
    log_event INFO "runtime_ready reason=test engine=started xhttp_probe=200"
    ! grep -Fq "chatty_probe_should_skip" "$LOG_FILE" || fail "low overhead did not suppress chatty health INFO"
    grep -Fq "runtime_ready reason=test" "$LOG_FILE" || fail "low overhead suppressed important runtime_ready INFO"
    disable_low_overhead_mode
    pass "low-overhead mode preserves important state-transition INFO logs"
}

test_latency_focus_mode_suppresses_noncritical_logs() {
    reset_runtime_paths
    enable_latency_focus_mode
    log_event INFO "latency_focus_info_should_skip"
    log_event WARN "latency_focus_warn_should_skip"
    log_event ERROR "latency_focus_error_should_stay"
    ! grep -Fq "latency_focus_info_should_skip" "$LOG_FILE" || fail "latency focus mode did not suppress INFO logs"
    ! grep -Fq "latency_focus_warn_should_skip" "$LOG_FILE" || fail "latency focus mode did not suppress WARN logs"
    grep -Fq "latency_focus_error_should_stay" "$LOG_FILE" || fail "latency focus mode suppressed ERROR logs"
    disable_latency_focus_mode
    pass "latency-focus mode suppresses noncritical logs while preserving errors"
}

test_latency_focus_env_can_be_overridden_by_toggle() {
    reset_runtime_paths
    G2RAY_LATENCY_FOCUS=1
    latency_focus_enabled || fail "latency focus env flag did not enable mode"
    disable_latency_focus_mode
    if latency_focus_enabled; then
        fail "latency focus disable toggle did not override the env flag"
    fi
    enable_latency_focus_mode
    latency_focus_enabled || fail "latency focus enable toggle did not re-enable mode"
    unset G2RAY_LATENCY_FOCUS
    disable_latency_focus_mode
    pass "latency-focus mode can be explicitly toggled even when env default is enabled"
}

test_performance_profile_settings_are_available() {
    reset_runtime_paths
    local balanced low_latency low_overhead
    balanced="$(performance_profile_settings balanced)"
    low_latency="$(performance_profile_settings low_latency)"
    low_overhead="$(performance_profile_settings low_overhead)"
    grep -Fq 'maxConcurrentUploads=16' <<< "$balanced" || fail "balanced profile missing expected concurrency"
    grep -Fq 'maxConcurrentUploads=24' <<< "$low_latency" || fail "low_latency profile missing higher concurrency"
    grep -Fq 'sniffQuic=false' <<< "$low_overhead" || fail "low_overhead profile should disable QUIC sniffing"
    pass "performance profile settings are explicit and inspectable"
}

test_route_settling_history_records_summary() {
    reset_runtime_paths
    record_route_settling_metric "recover_now" "timeout" "404" "25" "60" "20"
    record_route_settling_metric "recover_now_repair" "ready" "200" "30" "9" "4"
    summary="$(route_settling_history_summary)"
    grep -Fq "samples=2" <<< "$summary" || fail "route settling summary missing sample count"
    grep -Fq "ready=1" <<< "$summary" || fail "route settling summary missing ready count"
    grep -Fq "timeout=1" <<< "$summary" || fail "route settling summary missing timeout count"
    pass "route settling history records timing and outcomes"
}

test_doctor_json_reports_probe_state() {
    reset_runtime_paths
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    touch "$CONFIG_FILE"
    xray_running() { return 0; }
    is_port_open() { return 0; }
    xhttp_probe_metrics() {
        if [[ "${1:-}" == "local" ]]; then
            printf '200 1 ready\n'
        else
            printf '404 31 route_settling_404\n'
        fi
    }
    background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }
    output="$(print_doctor_json)"
    python -m json.tool <<< "$output" >/dev/null || fail "doctor json became invalid when probe reason is present"
    grep -Fq '"codespace": "behavior-space"' <<< "$output" || fail "doctor json missing codespace"
    grep -Fq '"edge_probe": {"http_status": 404' <<< "$output" || fail "doctor json missing edge probe"
    grep -Fq '"next_action_code": "wait_route_or_recover"' <<< "$output" || fail "doctor json missing actionable next_action_code"
    grep -Fq '"structured_log_file":' <<< "$output" || fail "doctor json missing structured log path"
    grep -Fq '"diagnostic_log_file":' <<< "$output" || fail "doctor json missing diagnostic log path"
    grep -Fq '"latency_focus": false' <<< "$output" || fail "doctor json missing latency focus state"
    pass "doctor json reports machine-readable route state"
}

test_doctor_json_sanitizes_invalid_port() {
    reset_runtime_paths
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT="443abc"
    xray_running() { return 1; }
    is_port_open() { return 1; }
    xhttp_probe_metrics() { printf '0 0\n'; }
    background_supervisor_status() { printf 'pid=none running=false version=missing token=missing heartbeat_age=unknown\n'; }
    output="$(print_doctor_json)"
    python -m json.tool <<< "$output" >/dev/null || fail "doctor json is invalid with nonnumeric XRAY_PORT"
    grep -Fq '"port": 443' <<< "$output" || fail "doctor json did not sanitize invalid XRAY_PORT to 443"
    pass "doctor json remains valid with invalid port input"
}

test_route_wait_requires_stable_usable_probes() {
    reset_runtime_paths
    ROUTE_READY_STABLE_SLEEP_SEC=0
    local probes=0
    xhttp_probe_metrics() {
        probes=$((probes + 1))
        printf '200 7\n'
    }
    wait_for_xhttp_route_ready "behavior_stable" 5 >/dev/null || fail "route wait did not accept stable usable probes"
    awk -F '\t' '$2 == "behavior_stable" && $3 == "ready" && $4 == "200" && $5 == "7" && $7 == "2" { found = 1 } END { exit !found }' "$ROUTE_SETTLING_HISTORY_FILE" \
        || fail "route wait did not require and record two stable usable probes"
    pass "route wait requires stable usable probes"
}

test_route_wait_rejects_transient_single_success() {
    reset_runtime_paths
    local probes_file="$TMP_ROOT/route-wait-flap-count.txt"
    printf '0\n' > "$probes_file"
    xhttp_probe_metrics() {
        local probes
        probes=$(cat "$probes_file")
        probes=$((probes + 1))
        printf '%s\n' "$probes" > "$probes_file"
        case "$probes" in
            1) printf '200 11\n' ;;
            2) printf '404 12\n' ;;
            3) printf '200 13\n' ;;
            *) printf '200 14\n' ;;
        esac
    }
    wait_for_xhttp_route_ready "behavior_flap" 10 >/dev/null || fail "route wait did not recover after transient success then stable success"
    awk -F '\t' '$2 == "behavior_flap" && $3 == "ready" && $4 == "200" && $7 == "4" { found = 1 } END { exit !found }' "$ROUTE_SETTLING_HISTORY_FILE" \
        || fail "route wait accepted a transient single 200 instead of waiting for stability"
    pass "route wait rejects transient single success"
}

test_recover_now_success_clears_nonfatal_port_public_failure() {
    (
        reset_runtime_paths
        CODESPACE_NAME="behavior-space"
        PORT_DOMAIN="behavior-space-443.app.github.dev"
        XRAY_PORT=443
        xray_listener_ready() { return 0; }
        ensure_codespace_port_public() { return 1; }
        wait_for_xhttp_route_ready() { return 0; }
        xhttp_probe_metrics() { printf '200 5\n'; }
        refresh_route_candidate_health() { return 0; }
        refresh_config_exports() { return 0; }
        log_diagnostic_snapshot() { return 0; }
        reset_route_bad_count() { return 0; }
        reset_edge_bad_count() { return 0; }
        output="$(recover_now --no-prompt 2>&1)"
        rc=$?
        [[ "$rc" -eq 0 ]] || fail "recover_now returned $rc despite route-ready recovery; output: $output"
        grep -Fq "Soft recover complete" <<< "$output" || fail "recover_now success output missing"
    )
    pass "recover now returns success when route recovers despite nonfatal port-public failure"
}

test_recover_now_json_reports_ready_contract() {
    (
        reset_runtime_paths
        CODESPACE_NAME="behavior-space"
        PORT_DOMAIN="behavior-space-443.app.github.dev"
        XRAY_PORT=443
        xray_listener_ready() { return 0; }
        ensure_codespace_port_public() { return 0; }
        wait_for_xhttp_route_ready() { return 0; }
        xhttp_probe_metrics() { printf '200 7 ready\n'; }
        refresh_route_candidate_health() { return 0; }
        refresh_config_exports() { return 0; }
        log_diagnostic_snapshot() { return 0; }
        output="$(recover_now_json)"
        rc=$?
        [[ "$rc" -eq 0 ]] || fail "ready recover_now_json returned $rc"
        python -m json.tool <<< "$output" >/dev/null || fail "recover_now_json returned invalid JSON"
        grep -Fq '"ok": true' <<< "$output" || fail "recover_now_json did not report ok=true"
        grep -Fq '"status": "ready"' <<< "$output" || fail "recover_now_json did not report ready status"
        grep -Fq '"route_ready": true' <<< "$output" || fail "recover_now_json did not report route_ready=true"
        grep -Fq '"edge_probe": {"http_status": 200' <<< "$output" || fail "recover_now_json missing edge probe status"
        grep -Fq '"next_action_code": "retry_vless_config"' <<< "$output" || fail "recover_now_json missing ready next_action_code"
    )
    pass "recover now json reports ready contract"
}

test_recover_now_json_reports_settling_contract() {
    (
        reset_runtime_paths
        CODESPACE_NAME="behavior-space"
        PORT_DOMAIN="behavior-space-443.app.github.dev"
        XRAY_PORT=443
        xray_listener_ready() { return 0; }
        ensure_codespace_port_public() { return 0; }
        wait_for_xhttp_route_ready() { return 1; }
        repair_codespace_port_route() { return 0; }
        xhttp_probe_metrics() { printf '404 33 route_settling_404\n'; }
        refresh_route_candidate_health() { return 0; }
        refresh_config_exports() { return 0; }
        log_diagnostic_snapshot() { return 0; }
        if output="$(recover_now_json)"; then
            fail "settling recover_now_json returned success"
        else
            rc=$?
        fi
        [[ "$rc" -ne 0 ]] || fail "settling recover_now_json returned zero"
        python -m json.tool <<< "$output" >/dev/null || fail "settling recover_now_json returned invalid JSON"
        grep -Fq '"ok": false' <<< "$output" || fail "recover_now_json did not report ok=false while settling"
        grep -Fq '"status": "settling"' <<< "$output" || fail "recover_now_json did not report settling status"
        grep -Fq '"route_ready": false' <<< "$output" || fail "recover_now_json did not report route_ready=false"
        grep -Fq '"next_action_code": "wait_route_or_recover"' <<< "$output" || fail "recover_now_json missing settling next_action_code"
        grep -Fq '"next_action": "Wait for the Codespaces route to settle, or run Recover Now if it stays stuck."' <<< "$output" \
            || fail "recover_now_json missing settling next action"
    )
    pass "recover now json reports settling contract"
}

test_recover_now_json_treats_followup_ready_probe_as_success() {
    (
        reset_runtime_paths
        CODESPACE_NAME="behavior-space"
        PORT_DOMAIN="behavior-space-443.app.github.dev"
        XRAY_PORT=443
        recover_now() { return 1; }
        xhttp_probe_metrics() { printf '200 9 ready\n'; }
        xray_running() { return 0; }
        is_port_open() { return 0; }
        output="$(recover_now_json)"
        rc=$?
        [[ "$rc" -eq 0 ]] || fail "ready follow-up probe should make recover_now_json exit zero, got $rc"
        python -m json.tool <<< "$output" >/dev/null || fail "follow-up ready recover_now_json returned invalid JSON"
        grep -Fq '"ok": true' <<< "$output" || fail "follow-up ready recover_now_json did not report ok=true"
        grep -Fq '"status": "ready"' <<< "$output" || fail "follow-up ready recover_now_json did not report ready"
        grep -Fq '"exit_code": 0' <<< "$output" || fail "follow-up ready recover_now_json did not expose final exit_code=0"
        grep -Fq '"recover_exit_code": 1' <<< "$output" || fail "follow-up ready recover_now_json did not preserve recover_exit_code"
        grep -Fq '"next_action_code": "retry_vless_config"' <<< "$output" || fail "follow-up ready recover_now_json missing next_action_code"
    )
    pass "recover now json treats follow-up ready probe as success"
}

test_diagnostic_snapshot_writes_readable_history() {
    reset_runtime_paths
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    xray_running() { return 0; }
    is_port_open() { return 0; }
    xhttp_probe_metrics() {
        if [[ "${1:-}" == "local" ]]; then
            printf '200 1\n'
        else
            printf '404 31\n'
        fi
    }
    background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }
    log_diagnostic_snapshot "behavior_test"
    grep -Fq 'Diagnostic Snapshot' "$DIAGNOSTIC_LOG_FILE" || fail "diagnostic log missing snapshot header"
    grep -Fq 'reason: behavior_test' "$DIAGNOSTIC_LOG_FILE" || fail "diagnostic log missing snapshot reason"
    grep -Fq 'edge_xhttp_options: HTTP 404' "$DIAGNOSTIC_LOG_FILE" || fail "diagnostic log missing edge probe"
    grep -Fq 'recent_events:' "$DIAGNOSTIC_LOG_FILE" || fail "diagnostic log missing recent events section"
    pass "diagnostic snapshots persist readable history"
}

test_diagnostic_log_rotation_keeps_readable_history() {
    reset_runtime_paths
    LOG_MAX_BYTES=64
    LOG_ROTATE_KEEP=2
    printf 'old diagnostic line that is intentionally longer than the tiny rotation threshold\n' > "$DIAGNOSTIC_LOG_FILE"
    rotate_log_file "$DIAGNOSTIC_LOG_FILE"
    printf 'new diagnostic line\n' > "$DIAGNOSTIC_LOG_FILE"
    [[ -s "$DIAGNOSTIC_LOG_FILE.1" ]] || fail "diagnostic rotation did not keep rotated history"
    grep -Fq 'old diagnostic line' "$DIAGNOSTIC_LOG_FILE.1" \
        || fail "diagnostic rotation did not preserve readable prior content"
    pass "diagnostic log rotation keeps readable bounded history"
}

test_structured_log_jsonl_is_parseable_with_special_chars() {
    reset_runtime_paths
    log_event INFO $'route_unusable detail="bad route" path=C:\\tmp\\x\nnext-line'
    log_event WARN "fallback_route_unusable ip=20.0.0.1 xhttp_probe=404"
    python - "$STRUCTURED_LOG_FILE" <<'PY' || fail "structured event log contains invalid JSONL"
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    rows = [json.loads(line) for line in fh if line.strip()]
assert len(rows) == 2
for row in rows:
    assert {"ts", "level", "event", "message"} <= set(row)
    assert "\n" not in row["message"]
assert rows[0]["event"] == "route_unusable"
assert rows[1]["event"] == "fallback_route_unusable"
PY
    pass "structured log JSONL stays parseable with special characters"
}

test_support_bundle_redacts_sensitive_material() {
    reset_runtime_paths
    CODESPACE_NAME="behavior-space"
    PORT_DOMAIN="behavior-space-443.app.github.dev"
    XRAY_PORT=443
    local uuid="11111111-2222-3333-4444-555555555555"
    local bearer="TEST_BEARER_SECRET_REDACT_ME"
    local github_token="TEST_GITHUB_TOKEN_REDACT_ME"
    local structured_token="TEST_STRUCTURED_TOKEN_REDACT_ME"
    local metadata_token="TEST_METADATA_GITHUB_TOKEN_REDACT_ME"
    local vless="vless://${uuid}@behavior-space-443.app.github.dev:443?encryption=none#label"
    printf '%s\nAuthorization: Bearer %s\nauthorization: Bearer %s\nGITHUB_TOKEN=%s\n"WAKE_SECRET":"%s"\n' \
        "$vless" "$bearer" "$bearer" "$github_token" "$bearer" > "$LOG_FILE"
    printf '{"ts":"2026-05-30T00:00:00Z","level":"INFO","event":"test","message":"%s","authorization":"Bearer %s","WAKE_SECRET":"%s","token":"%s"}\n' \
        "$vless" "$bearer" "$bearer" "$structured_token" > "$STRUCTURED_LOG_FILE"
    printf 'wake_secret=%s\n%s\n"authorization":"Bearer %s"\n' "$bearer" "$uuid" "$bearer" > "$DIAGNOSTIC_LOG_FILE"
    printf 'worker_url=https://worker.example/wake\nwake_secret=%s\nGITHUB_TOKEN=%s\n' "$bearer" "$metadata_token" > "$WAKER_METADATA_FILE"
    printf '2026-05-30T00:00:00Z\t20.0.0.1\t200\t10\ttrue\n' > "$ROUTE_HEALTH_FILE"
    printf 'ip=20.0.0.1\nchecked_at=2026-05-30T00:00:00Z\n' > "$LAST_GOOD_ROUTE_FILE"
    XRAY_BIN="$TMP_ROOT/missing-xray"
    xray_running() { return 0; }
    is_port_open() { return 0; }
    xhttp_probe_metrics() { printf '200 1\n'; }
    background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }

    local bundle extract
    bundle="$(create_support_bundle)" || fail "support bundle creation failed"
    [[ -s "$bundle" ]] || fail "support bundle archive is missing"
    extract="$TMP_ROOT/support-extract"
    mkdir -p "$extract"
    tar -xzf "$bundle" -C "$extract"
    [[ -s "$extract/doctor.json" ]] || fail "support bundle missing doctor JSON"
    [[ -s "$extract/logs/g2ray.log" ]] || fail "support bundle missing redacted app log"
    if grep -R -Fq "$uuid" "$extract" || grep -R -Fq "$bearer" "$extract" || grep -R -Fq "$github_token" "$extract" || grep -R -Fq "$structured_token" "$extract" || grep -R -Fq "$metadata_token" "$extract" || grep -R -Fq "$vless" "$extract"; then
        fail "support bundle leaked sensitive material"
    fi
    grep -R -Fq '<vless-redacted>' "$extract" || fail "support bundle did not mark redacted VLESS links"
    python - "$extract/logs/g2ray-events.jsonl" <<'PY' || fail "support bundle redaction corrupted structured JSONL"
import json
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    rows = [json.loads(line) for line in fh if line.strip()]
assert rows
PY
    grep -Fq 'xray=unknown' "$extract/metadata.txt" || fail "support bundle did not survive missing Xray binary"
    pass "support bundle redacts sensitive material"
}

test_support_bundle_handles_relative_log_dir() {
    reset_runtime_paths
    local cwd="$TMP_ROOT/relative-support-cwd"
    mkdir -p "$cwd"
    (
        cd "$cwd"
        LOG_DIR="relative-logs"
        LOG_FILE="$LOG_DIR/g2ray.log"
        STRUCTURED_LOG_FILE="$LOG_DIR/g2ray-events.jsonl"
        DIAGNOSTIC_LOG_FILE="$LOG_DIR/g2ray-diagnostics.log"
        mkdir -p "$LOG_DIR"
        printf 'relative app log\n' > "$LOG_FILE"
        printf '{"ts":"2026-05-30T00:00:00Z","level":"INFO","event":"test","message":"relative"}\n' > "$STRUCTURED_LOG_FILE"
        printf 'relative diagnostic\n' > "$DIAGNOSTIC_LOG_FILE"
        XRAY_BIN="$TMP_ROOT/missing-xray"
        xray_running() { return 0; }
        is_port_open() { return 0; }
        xhttp_probe_metrics() { printf '200 1\n'; }
        background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }

        local bundle
        bundle="$(create_support_bundle)" || fail "support bundle failed with relative LOG_DIR"
        [[ -s "$bundle" ]] || fail "relative support bundle archive is missing"
        tar -tzf "$bundle" > "$TMP_ROOT/relative-support-list.txt"
        grep -Fxq './logs/g2ray.log' "$TMP_ROOT/relative-support-list.txt" || grep -Fxq 'logs/g2ray.log' "$TMP_ROOT/relative-support-list.txt" \
            || fail "relative support bundle is missing app log"
    )
    pass "support bundle handles relative log dir"
}

test_support_bundle_includes_rotated_logs() {
    reset_runtime_paths
    printf 'live app log\n' > "$LOG_FILE"
    printf 'rotated app log\n' > "$LOG_FILE.1"
    printf '{"ts":"2026-05-30T00:00:00Z","level":"INFO","event":"live","message":"live"}\n' > "$STRUCTURED_LOG_FILE"
    printf '{"ts":"2026-05-29T00:00:00Z","level":"WARN","event":"old","message":"rotated"}\n' > "$STRUCTURED_LOG_FILE.1"
    printf 'live diagnostic\n' > "$DIAGNOSTIC_LOG_FILE"
    printf 'rotated diagnostic\n' > "$DIAGNOSTIC_LOG_FILE.1"
    printf 'xray live\n' > "$LOG_DIR/xray.log"
    printf 'xray rotated\n' > "$LOG_DIR/xray.log.1"
    printf 'xray error live\n' > "$LOG_DIR/xray-error.log"
    printf 'xray error rotated\n' > "$LOG_DIR/xray-error.log.1"
    XRAY_BIN="$TMP_ROOT/missing-xray"
    xray_running() { return 0; }
    is_port_open() { return 0; }
    xhttp_probe_metrics() { printf '200 1\n'; }
    background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }

    local bundle extract
    bundle="$(create_support_bundle)" || fail "support bundle creation failed with rotated logs"
    extract="$TMP_ROOT/support-rotated-extract"
    mkdir -p "$extract"
    tar -xzf "$bundle" -C "$extract"
    [[ -s "$extract/logs/g2ray.log.1" ]] || fail "support bundle missing rotated app log"
    [[ -s "$extract/logs/g2ray-events.jsonl.1" ]] || fail "support bundle missing rotated event log"
    [[ -s "$extract/logs/g2ray-diagnostics.log.1" ]] || fail "support bundle missing rotated diagnostics log"
    [[ -s "$extract/logs/xray.log.1" ]] || fail "support bundle missing rotated Xray log"
    [[ -s "$extract/logs/xray-error.log.1" ]] || fail "support bundle missing rotated Xray error log"
    pass "support bundle includes rotated logs"
}

test_support_bundle_marks_unreadable_optional_logs() {
    reset_runtime_paths
    local was_unreadable=0
    printf 'live app log\n' > "$LOG_FILE"
    printf '{"ts":"2026-05-30T00:00:00Z","level":"INFO","event":"live","message":"live"}\n' > "$STRUCTURED_LOG_FILE"
    printf 'live diagnostic\n' > "$DIAGNOSTIC_LOG_FILE"
    printf 'root-owned style xray log\n' > "$LOG_DIR/xray.log"
    chmod 000 "$LOG_DIR/xray.log" 2>/dev/null || true
    [[ ! -r "$LOG_DIR/xray.log" ]] && was_unreadable=1
    XRAY_BIN="$TMP_ROOT/missing-xray"
    xray_running() { return 0; }
    is_port_open() { return 0; }
    xhttp_probe_metrics() { printf '200 1\n'; }
    background_supervisor_status() { printf 'pid=1 running=heartbeat version=ok token=present heartbeat_age=1s\n'; }

    local bundle extract
    bundle="$(create_support_bundle)" || {
        chmod 600 "$LOG_DIR/xray.log" 2>/dev/null || true
        fail "support bundle failed with unreadable optional log"
    }
    chmod 600 "$LOG_DIR/xray.log" 2>/dev/null || true
    extract="$TMP_ROOT/support-unreadable-extract"
    mkdir -p "$extract"
    tar -xzf "$bundle" -C "$extract"
    [[ -s "$extract/logs/xray.log" ]] || fail "support bundle missing marker for unreadable optional log"
    if [[ "$was_unreadable" == "1" ]]; then
        grep -Fq 'unreadable:' "$extract/logs/xray.log" || fail "support bundle did not mark unreadable optional log"
    else
        grep -Fq 'root-owned style xray log' "$extract/logs/xray.log" || fail "support bundle did not copy readable xray log"
    fi
    pass "support bundle marks unreadable optional logs"
}

test_port_visibility_is_throttled
test_codespace_detection_uses_shared_environment_in_headless_ssh
test_codespace_detection_uses_local_metadata_when_gh_is_unauthenticated
test_run_gh_uses_shared_codespaces_token_when_shell_is_unauthenticated
test_runtime_lock_serializes_operations_and_allows_reentry
test_port_visibility_cache_is_scoped_by_codespace_and_port
test_cached_route_order_uses_reliability_then_average_latency
test_cached_route_order_uses_recent_weighted_score
test_last_good_route_decays_before_breaking_ties
test_route_candidate_stats_track_average_and_success_rate
test_route_health_records_source_reason_and_recent_average
test_route_failure_reason_classifier
test_xhttp_probe_metrics_reports_curl_failure_reason
test_cached_route_order_prefers_pinned_route_then_latency_without_stats
test_route_monitor_default_and_hard_cap_are_wide_but_bounded
test_blacklisted_route_is_excluded_from_cached_exports
test_manual_route_candidates_are_validated_and_resettable
test_route_preferences_clear_matching_cooldowns
test_route_health_refresh_preserves_cache_when_all_candidates_are_cooled_down
test_route_health_refresh_preserves_cache_when_all_probes_are_unusable
test_route_health_refresh_mixes_provider_candidates_before_stale_cache_cap
test_route_preference_write_failures_return_failure
test_pinned_route_is_a_durable_candidate_source
test_cached_route_health_is_a_durable_candidate_source
test_dns_candidate_cache_reuses_fresh_provider_results
test_last_known_state_scans_full_current_log
test_usable_fallback_ips_uses_fresh_cache
test_usable_fallback_ips_fills_partial_fresh_cache
test_usable_fallback_ips_caps_live_probe_fallback
test_xhttp_config_path_is_cached_by_config_content
test_boot_status_helpers_record_silent_start_result
test_config_exports_write_local_only_metadata
test_config_exports_are_stable_client_artifacts
test_generated_links_follow_configured_xhttp_path
test_config_metadata_sanitizes_invalid_max_fallback_links
test_bench_json_reports_deterministic_budgets
test_low_overhead_mode_suppresses_info_logs
test_low_overhead_env_can_be_overridden_by_toggle
test_low_overhead_keeps_important_state_logs
test_latency_focus_mode_suppresses_noncritical_logs
test_latency_focus_env_can_be_overridden_by_toggle
test_performance_profile_settings_are_available
test_route_settling_history_records_summary
test_doctor_json_reports_probe_state
test_doctor_json_sanitizes_invalid_port
test_route_wait_requires_stable_usable_probes
test_route_wait_rejects_transient_single_success
test_recover_now_success_clears_nonfatal_port_public_failure
test_recover_now_json_reports_ready_contract
test_recover_now_json_reports_settling_contract
test_recover_now_json_treats_followup_ready_probe_as_success
test_diagnostic_snapshot_writes_readable_history
test_diagnostic_log_rotation_keeps_readable_history
test_structured_log_jsonl_is_parseable_with_special_chars
test_support_bundle_redacts_sensitive_material
test_support_bundle_handles_relative_log_dir
test_support_bundle_includes_rotated_logs
test_support_bundle_marks_unreadable_optional_logs
