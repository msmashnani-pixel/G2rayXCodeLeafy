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
    rm -rf "$DATA_DIR" "$LOG_DIR"
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

test_route_wait_requires_stable_usable_probes() {
    reset_runtime_paths
    ROUTE_READY_STABLE_SLEEP_SEC=0
    local probes=0
    xhttp_probe_metrics() {
        probes=$((probes + 1))
        printf '200 7\n'
    }
    wait_for_xhttp_route_ready "behavior_stable" 1 >/dev/null || fail "route wait did not accept stable usable probes"
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
        xhttp_probe_metrics() { printf '200 7\n'; }
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
        xhttp_probe_metrics() { printf '404 33\n'; }
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
        grep -Fq '"next_action": "Wait and retry health, or open the panel and run Recover Now if it stays stuck."' <<< "$output" \
            || fail "recover_now_json missing settling next action"
    )
    pass "recover now json reports settling contract"
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
    local bearer="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    local github_token="github_pat_1234567890_SECRET_TOKEN"
    local classic_token="gho_SECRET_TOKEN"
    local fine_grained_token="github_pat_1234567890_SECRET_TOKEN"
    local vless="vless://${uuid}@behavior-space-443.app.github.dev:443?encryption=none#label"
    printf '%s\nAuthorization: Bearer %s\nauthorization: Bearer %s\nGITHUB_TOKEN=%s\n"WAKE_SECRET":"%s"\nclassic=%s\nfine=%s\n' \
        "$vless" "$bearer" "$bearer" "$github_token" "$bearer" "$classic_token" "$fine_grained_token" > "$LOG_FILE"
    printf '{"ts":"2026-05-30T00:00:00Z","level":"INFO","event":"test","message":"%s","authorization":"Bearer %s","WAKE_SECRET":"%s","token":"%s"}\n' \
        "$vless" "$bearer" "$bearer" "ghs_SECRET_TOKEN" > "$STRUCTURED_LOG_FILE"
    printf 'wake_secret=%s\n%s\n"authorization":"Bearer %s"\n' "$bearer" "$uuid" "$bearer" > "$DIAGNOSTIC_LOG_FILE"
    printf 'worker_url=https://worker.example/wake\nwake_secret=%s\nGITHUB_TOKEN=%s\n' "$bearer" "ghr_SECRET_TOKEN" > "$WAKER_METADATA_FILE"
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
    if grep -R -Fq "$uuid" "$extract" || grep -R -Fq "$bearer" "$extract" || grep -R -Fq "$github_token" "$extract" || grep -R -Fq "$classic_token" "$extract" || grep -R -Fq "$fine_grained_token" "$extract" || grep -R -Fq "$vless" "$extract"; then
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

test_port_visibility_is_throttled
test_port_visibility_cache_is_scoped_by_codespace_and_port
test_cached_route_order_prefers_last_good_then_latency
test_cached_route_order_prefers_pinned_route_before_last_good
test_blacklisted_route_is_excluded_from_cached_exports
test_manual_route_candidates_are_validated_and_resettable
test_route_preference_write_failures_return_failure
test_pinned_route_is_a_durable_candidate_source
test_cached_route_health_is_a_durable_candidate_source
test_last_known_state_scans_full_current_log
test_usable_fallback_ips_uses_fresh_cache
test_route_settling_history_records_summary
test_doctor_json_reports_probe_state
test_doctor_json_sanitizes_invalid_port
test_route_wait_requires_stable_usable_probes
test_route_wait_rejects_transient_single_success
test_recover_now_success_clears_nonfatal_port_public_failure
test_recover_now_json_reports_ready_contract
test_recover_now_json_reports_settling_contract
test_diagnostic_snapshot_writes_readable_history
test_structured_log_jsonl_is_parseable_with_special_chars
test_support_bundle_redacts_sensitive_material
