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
    LAST_GOOD_ROUTE_FILE="$DATA_DIR/last_good_route.txt"
    PINNED_ROUTE_FILE="$DATA_DIR/pinned_route.txt"
    MANUAL_ROUTE_CANDIDATES_FILE="$DATA_DIR/manual_route_candidates.txt"
    BLACKLISTED_ROUTE_CANDIDATES_FILE="$DATA_DIR/blacklisted_route_candidates.txt"
    ROUTE_SETTLING_HISTORY_FILE="$DATA_DIR/route_settling_history.tsv"
    PORT_PUBLIC_STAMP_FILE="$DATA_DIR/port_public_last"
    LOG_FILE="$LOG_DIR/g2ray.log"
    STRUCTURED_LOG_FILE="$LOG_DIR/g2ray-events.jsonl"
    DIAGNOSTIC_LOG_FILE="$LOG_DIR/g2ray-diagnostics.log"
    WAKER_METADATA_FILE="$DATA_DIR/waker_metadata.txt"
    XRAY_PID_FILE="$DATA_DIR/xray.pid"
    mkdir -p "$DATA_DIR" "$LOG_DIR" "$QR_DIR"
    : > "$LOG_FILE"
    : > "$STRUCTURED_LOG_FILE"
    : > "$DIAGNOSTIC_LOG_FILE"
}

export CODESPACE_NAME="behavior-space"
export XRAY_PORT="443"
export G2RAY_SOURCE_ONLY=1
export G2RAY_DATA_DIR="$TMP_ROOT/bootstrap-data"
export G2RAY_LOG_DIR="$TMP_ROOT/bootstrap-logs"
source "$SCRIPT"
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

test_cached_route_order_prefers_last_good_then_latency() {
    reset_runtime_paths
    cat > "$ROUTE_HEALTH_FILE" <<'EOF'
2026-05-30T00:00:00Z	20.0.0.1	200	40	true
2026-05-30T00:00:00Z	20.0.0.2	200	900	true
2026-05-30T00:00:00Z	20.0.0.3	404	10	false
EOF
    cat > "$LAST_GOOD_ROUTE_FILE" <<'EOF'
ip=20.0.0.2
http_status=200
latency_ms=900
source=test
checked_at=2026-05-30T00:00:00Z
EOF
    mapfile -t routes < <(cached_usable_fallback_ips)
    [[ "${routes[0]:-}" == "20.0.0.2" ]] || fail "last good route was not preferred first"
    [[ "${routes[1]:-}" == "20.0.0.1" ]] || fail "remaining routes were not ordered by latency"
    pass "cached route health orders exports by last-good and latency"
}

test_cached_route_order_prefers_pinned_route_before_last_good() {
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
    [[ "${routes[1]:-}" == "20.0.0.2" ]] || fail "last good route was not preferred after pinned route"
    pass "cached route health orders exports by pinned route, last-good route, then latency"
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
    cat > "$LAST_GOOD_ROUTE_FILE" <<'EOF'
ip=20.0.0.9
http_status=200
latency_ms=40
source=test
checked_at=2026-05-30T00:00:00Z
EOF
    reset_route_candidate_cache
    grep -Fxq "20.0.0.9" "$MANUAL_ROUTE_CANDIDATES_FILE" || fail "cache reset removed manual route preferences"
    [[ "$(cat "$PINNED_ROUTE_FILE" 2>/dev/null)" == "20.0.0.9" ]] || fail "cache reset removed pinned route preference"
    grep -Fxq "20.0.0.2" "$BLACKLISTED_ROUTE_CANDIDATES_FILE" || fail "cache reset removed blacklist preferences"
    [[ ! -e "$ROUTE_HEALTH_FILE" ]] || fail "route health cache was not reset"
    [[ ! -e "$LAST_GOOD_ROUTE_FILE" ]] || fail "last-good route cache was not reset"
    reset_route_candidate_state
    [[ ! -e "$MANUAL_ROUTE_CANDIDATES_FILE" ]] || fail "manual route file was not reset"
    [[ ! -e "$PINNED_ROUTE_FILE" ]] || fail "pinned route file was not reset"
    [[ ! -e "$BLACKLISTED_ROUTE_CANDIDATES_FILE" ]] || fail "blacklist route file was not reset"
    pass "manual route candidates are validated and route manager cache/state resets are safe"
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
    output="$(print_doctor_json)"
    grep -Fq '"codespace": "behavior-space"' <<< "$output" || fail "doctor json missing codespace"
    grep -Fq '"edge_probe": {"http_status": 404' <<< "$output" || fail "doctor json missing edge probe"
    grep -Fq '"structured_log_file":' <<< "$output" || fail "doctor json missing structured log path"
    grep -Fq '"diagnostic_log_file":' <<< "$output" || fail "doctor json missing diagnostic log path"
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

test_route_wait_attempts_count_first_probe() {
    reset_runtime_paths
    local probes=0
    xhttp_probe_metrics() {
        probes=$((probes + 1))
        printf '200 7\n'
    }
    wait_for_xhttp_route_ready "behavior_attempts" 1 >/dev/null || fail "route wait did not accept usable first probe"
    awk -F '\t' '$2 == "behavior_attempts" && $3 == "ready" && $4 == "200" && $5 == "7" && $7 == "1" { found = 1 } END { exit !found }' "$ROUTE_SETTLING_HISTORY_FILE" \
        || fail "route wait did not record first probe as attempt 1"
    pass "route wait attempts count the first probe"
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

test_port_visibility_is_throttled
test_port_visibility_cache_is_scoped_by_codespace_and_port
test_cached_route_order_prefers_last_good_then_latency
test_cached_route_order_prefers_pinned_route_before_last_good
test_blacklisted_route_is_excluded_from_cached_exports
test_manual_route_candidates_are_validated_and_resettable
test_route_preference_write_failures_return_failure
test_pinned_route_is_a_durable_candidate_source
test_usable_fallback_ips_uses_fresh_cache
test_route_settling_history_records_summary
test_doctor_json_reports_probe_state
test_doctor_json_sanitizes_invalid_port
test_route_wait_attempts_count_first_probe
test_recover_now_success_clears_nonfatal_port_public_failure
test_diagnostic_snapshot_writes_readable_history
