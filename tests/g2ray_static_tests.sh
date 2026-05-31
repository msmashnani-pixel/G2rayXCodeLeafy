#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/g2ray.sh"
GITIGNORE="$ROOT_DIR/.gitignore"
GITATTRIBUTES="$ROOT_DIR/.gitattributes"
README="$ROOT_DIR/README.md"
CONFIGS="$ROOT_DIR/configs.txt"
DOCKERFILE="$ROOT_DIR/.devcontainer/Dockerfile"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/static-tests.yml"
REOPEN_SCRIPT="$ROOT_DIR/scripts/reopen-codespace.ps1"
WORKER_DIR="$ROOT_DIR/worker/codespace-waker"
WORKER_SCRIPT="$WORKER_DIR/src/index.js"
WORKER_README="$WORKER_DIR/README.md"
WORKER_WRANGLER_EXAMPLE="$WORKER_DIR/wrangler.toml.example"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

grep_fixed() {
    local pattern="$1" file="$2"
    grep -Fq -- "$pattern" "$file"
}

grep_regex() {
    local pattern="$1" file="$2"
    grep -Eq -- "$pattern" "$file"
}

test_wait_for_port_increment_is_set_e_safe() {
    if grep_fixed '(( i++ ))' "$SCRIPT"; then
        fail 'wait_for_port still uses post-increment, which exits under set -e when i is 0'
    fi
    grep_regex 'i=\$\(\(i \+ 1\)\)|\(\( \+\+i \)\)' "$SCRIPT" \
        || fail 'wait_for_port does not contain a set -e safe increment'
    pass 'wait_for_port increment is set -e safe'
}

test_process_management_uses_pid_file() {
    grep_fixed 'XRAY_PID_FILE=' "$SCRIPT" \
        || fail 'script does not define an Xray PID file'
    grep_fixed 'xray_pid_matches()' "$SCRIPT" \
        || fail 'script does not validate that a PID belongs to this Xray config'
    grep_fixed 'xray_pid_matches "$p"' "$SCRIPT" \
        || fail 'stop/status paths do not validate PID ownership before trusting the PID file'
    grep_fixed 'owned_xray_pids()' "$SCRIPT" \
        || fail 'script does not enumerate all owned Xray processes'
    grep_fixed 'xpid=$(owned_xray_pids | head -1 || true)' "$SCRIPT" \
        || fail 'resource stats do not prefer project-owned Xray PIDs'
    grep_fixed 'mapfile -t owned_pids' "$SCRIPT" \
        || fail 'stop_xray does not collect every owned Xray PID before stopping'
    grep_fixed 'for p in "${owned_pids[@]}"' "$SCRIPT" \
        || fail 'stop_xray does not stop every owned Xray PID'
    grep_fixed 'if ! stop_xray; then' "$SCRIPT" \
        || fail 'start_xray does not abort when the old owned listener cannot be stopped'
    grep_fixed '> "$XRAY_PID_FILE"' "$SCRIPT" \
        || fail 'start_xray does not store the launched Xray PID'
    if grep_fixed 'pkill -x "xray"' "$SCRIPT" || grep_fixed 'pkill -9 -x "xray"' "$SCRIPT"; then
        fail 'script still kills every process named xray'
    fi
    if grep_fixed 'pgrep -x "xray"' "$SCRIPT"; then
        fail 'script still trusts a broad xray process lookup'
    fi
    pass 'process management is scoped through a PID file'
}

test_background_tasks_uses_owned_pid_file() {
    grep_fixed 'bg_tasks_running()' "$SCRIPT" \
        || fail 'script does not validate that the background PID belongs to a live g2ray process'
    grep_fixed 'bg_tasks_running "$p"' "$SCRIPT" \
        || fail 'start_background_tasks does not validate background PID ownership'
    grep_fixed 'BG_TASKS_LOCK_DIR=' "$SCRIPT" \
        || fail 'background supervisor startup is not protected by an atomic lock'
    grep_fixed 'BG_TASKS_TOKEN_FILE=' "$SCRIPT" \
        || fail 'background supervisor does not persist an ownership token'
    grep_fixed 'G2RAY_BG_TASK_TOKEN=' "$SCRIPT" \
        || fail 'background supervisor process is not tagged with an ownership token'
    grep_fixed 'export G2RAY_BG_TASK_TOKEN="$token"' "$SCRIPT" \
        || fail 'background supervisor ownership token is not exported into the child environment'
    grep_fixed '/proc/$p/environ' "$SCRIPT" \
        || fail 'background supervisor ownership is not verified against the live process environment'
    grep_fixed 'background_supervisor_recent_heartbeat()' "$SCRIPT" \
        || fail 'background supervisor diagnostics cannot recognize a fresh heartbeat'
    grep_fixed 'running="heartbeat"' "$SCRIPT" \
        || fail 'background supervisor diagnostics cannot distinguish a live heartbeat from a dead supervisor'
    if grep_fixed 'grep -Fq "g2ray.sh"' "$SCRIPT"; then
        fail 'background supervisor ownership still matches any process whose args contain g2ray.sh'
    fi
    pass 'background supervisor validates PID ownership'
}

test_background_tasks_require_config() {
    grep_fixed '[[ -f "$CONFIG_FILE" ]] || continue' "$SCRIPT" \
        || fail 'background loop can still start Xray before config exists'
    if grep_fixed 'start_xray; wait_for_port' "$SCRIPT"; then
        fail 'menu paths still run start_xray without handling a failed start'
    fi
    grep_fixed 'start_xray >/dev/null 2>&1 && wait_for_port >/dev/null 2>&1' "$SCRIPT" \
        || fail 'force reconnect does not handle start_xray failure explicitly'
    pass 'background tasks skip Xray start until config exists'
}

test_port_visibility_failures_are_handled() {
    if grep -Eq '^[[:space:]]*ensure_codespace_port_public[[:space:]]*>/dev/null 2>&1[[:space:]]*$' "$SCRIPT"; then
        fail 'bare ensure_codespace_port_public call can exit under set -e without a user-facing message'
    fi
    grep_fixed 'Could not set Codespaces port' "$SCRIPT" \
        || fail 'port-public failure does not produce an actionable user-facing warning'
    pass 'port visibility failures are handled explicitly'
}

test_self_update_is_opt_in() {
    grep_fixed 'G2RAY_AUTO_UPDATE' "$SCRIPT" \
        || fail 'self-update is not controlled by an opt-in environment variable'
    grep_fixed 'bash -n "$tmp"' "$SCRIPT" \
        || fail 'self-update does not syntax-check the downloaded script before replacing itself'
    if grep_fixed 'cat "$tmp" > "$0"' "$SCRIPT"; then
        fail 'self-update still writes directly over the running script'
    fi
    pass 'self-update is opt-in'
}

test_exit_trap_preserves_failures() {
    grep_fixed 'cleanup()' "$SCRIPT" \
        || fail 'script does not define an explicit cleanup trap'
    grep_fixed 'local code=$?' "$SCRIPT" \
        || fail 'cleanup trap does not preserve the triggering exit status'
    if grep_fixed "exit 0' EXIT INT TERM" "$SCRIPT"; then
        fail 'global trap still masks failures as successful exits'
    fi
    pass 'exit trap preserves failure status'
}

test_generated_files_are_ignored() {
    [[ -f "$GITIGNORE" ]] || fail '.gitignore is missing'
    for pattern in '/data/' '/logs/' '/configs-to-copy-for-mobile.txt' '/configs-subscription-base64.txt'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing $pattern"
    done
    for pattern in '/configs-to-copy-for-mobile.txt.*' '/configs-subscription-base64.txt.*'; do
        grep_fixed "$pattern" "$GITIGNORE" || fail ".gitignore missing atomic temp pattern $pattern"
    done
    pass 'generated runtime files are ignored'
}

test_shell_files_are_lf_normalized() {
    [[ -f "$GITATTRIBUTES" ]] || fail '.gitattributes is missing'
    grep_fixed '*.sh text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force shell scripts to LF'
    grep_fixed '*.ps1 text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force PowerShell helper scripts to LF'
    grep_fixed 'tests/*.sh text eol=lf' "$GITATTRIBUTES" \
        || fail '.gitattributes does not force test shell scripts to LF'
    pass 'shell files are LF-normalized for Linux Bash'
}

test_panel_script_is_executable() {
    git -C "$ROOT_DIR" ls-files --stage -- g2ray.sh | grep -q '^100755 ' \
        || fail 'g2ray.sh is not tracked as executable, so ./g2ray.sh fails after git pull in Linux Codespaces'
    pass 'panel script is tracked executable'
}

test_xray_version_can_be_pinned() {
    grep_fixed 'ARG XRAY_VERSION=' "$DOCKERFILE" \
        || fail 'Dockerfile does not expose XRAY_VERSION for reproducible builds'
    if grep_fixed 'releases/latest/download' "$DOCKERFILE"; then
        fail 'Dockerfile still downloads Xray from latest'
    fi
    grep_fixed 'Xray-linux-64.zip.dgst' "$DOCKERFILE" \
        || fail 'Dockerfile does not download Xray digest metadata'
    grep_fixed 'sha256sum -c -' "$DOCKERFILE" \
        || fail 'Dockerfile does not verify Xray zip checksum before installing'
    pass 'Dockerfile supports pinned Xray version'
}

test_generated_config_uses_resilient_dns_fallback() {
    grep_fixed '"enableParallelQuery": true' "$SCRIPT" \
        || fail 'generated Xray DNS config does not race equivalent fallback resolvers'
    grep_fixed '"disableFallback": false' "$SCRIPT" \
        || fail 'generated Xray DNS config does not explicitly keep fallback enabled'
    grep_fixed '"disableFallbackIfMatch": false' "$SCRIPT" \
        || fail 'generated Xray DNS config could stop fallback after a matched resolver times out'
    grep_fixed '"https+local://1.1.1.1/dns-query"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not use local-mode Cloudflare DoH'
    grep_fixed '"https+local://dns.google/dns-query"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Google DoH fallback'
    grep_fixed '"address": "1.0.0.1"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Cloudflare UDP fallback'
    grep_fixed '"address": "8.8.4.4"' "$SCRIPT" \
        || fail 'generated Xray DNS config does not include Google UDP fallback'
    grep_fixed '"timeoutMs": 2500' "$SCRIPT" \
        || fail 'generated Xray DNS config does not bound DoH resolver wait time'
    grep_fixed 'upgrade_config_dns()' "$SCRIPT" \
        || fail 'script does not provide an in-place DNS migration for existing configs'
    grep_fixed '.dns = {' "$SCRIPT" \
        || fail 'existing config DNS migration does not replace the dns object'
    grep_fixed 'upgrade_config_dns >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail 'start path does not apply DNS migration before launching Xray'
    grep_fixed 'config_dns refreshed' "$SCRIPT" \
        || fail 'DNS migration does not log when it refreshes an existing config'
    if grep_fixed '"domains": ["geosite:geolocation-!cn"]' "$SCRIPT"; then
        fail 'generated Xray DNS config still pins most lookups to a single domain-matched resolver before fallback'
    fi
    pass 'generated Xray config uses resilient DNS fallback'
}

test_generated_links_include_domain_and_ip_variants() {
    grep_fixed 'resolve_domain_ip()' "$SCRIPT" \
        || fail 'script does not provide a resolver for the Codespaces app domain'
    grep_fixed 'resolve_domain_ips()' "$SCRIPT" \
        || fail 'script does not provide a multi-IP resolver for the Codespaces app domain'
    grep_fixed 'G2RAY_EXTRA_FALLBACK_IPS' "$SCRIPT" \
        || fail 'script does not allow manually supplied fallback IPs'
    grep_fixed 'DEFAULT_FALLBACK_IPS=' "$SCRIPT" \
        || fail 'script does not provide built-in fallback IPs for DNS-blocked networks'
    grep_fixed '20.85.77.48 20.207.70.99 20.120.56.11' "$SCRIPT" \
        || fail 'built-in fallback IPs do not prefer the current East US tunnel edges before the historical fallback'
    grep_fixed '20.120.56.11' "$SCRIPT" \
        || fail 'script does not include the historically working East US tunnel IP'
    grep_fixed 'dns.google/resolve' "$SCRIPT" \
        || fail 'script does not query Google DNS-over-HTTPS for fallback IPs'
    grep_fixed 'cloudflare-dns.com/dns-query' "$SCRIPT" \
        || fail 'script does not query Cloudflare DNS-over-HTTPS for fallback IPs'
    grep_fixed 'seen[$0]++' "$SCRIPT" \
        || fail 'script does not deduplicate fallback IP candidates'
    if grep_fixed '(\.[0-9]+){3}' "$SCRIPT"; then
        fail 'script still uses interval IPv4 regexes that can drop fallback IPs on non-GNU tools'
    fi
    grep_fixed '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' "$SCRIPT" \
        || fail 'script does not use a portable IPv4 filter for fallback IP candidates'
    grep_fixed 'generate_domain_link()' "$SCRIPT" \
        || fail 'script does not generate a domain-address link'
    grep_fixed 'generate_ip_link()' "$SCRIPT" \
        || fail 'script does not generate a resolved-IP fallback link'
    grep_fixed 'generate_ip_links()' "$SCRIPT" \
        || fail 'script does not generate multiple resolved-IP fallback links'
    grep_fixed '"$uuid" "$address" "$CODESPACES_EDGE_PORT" "$PORT_DOMAIN" "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'IP fallback link must preserve PORT_DOMAIN as SNI and host'
    grep_fixed 'generate_link_for_address "$PORT_DOMAIN"' "$SCRIPT" \
        || fail 'domain link must use PORT_DOMAIN as address, SNI, and host'
    grep_fixed '_VLESS_IPS=$(generate_ip_links)' "$SCRIPT" \
        || fail 'display/copy paths do not use multi-IP fallback generation'
    grep_fixed 'render_config_entry()' "$SCRIPT" \
        || fail 'display does not render each config as a separate copy-safe entry'
    grep_fixed 'render_config_qr()' "$SCRIPT" \
        || fail 'display does not render a QR code for each config entry'
    grep_fixed 'G2RAY_QR_MODE' "$SCRIPT" \
        || fail 'QR display mode is not configurable'
    grep_fixed 'local show_qr="${4:-false}"' "$SCRIPT" \
        || fail 'config entry renderer cannot hide non-primary QR codes'
    grep_fixed '[[ "$show_qr" == true ]]' "$SCRIPT" \
        || fail 'config entry renderer does not conditionally show QR codes'
    grep_fixed '_QR_MODE="${G2RAY_QR_MODE:-recommended}"' "$SCRIPT" \
        || fail 'config display does not default to recommended-only QR mode'
    grep_fixed '[[ "$_QR_MODE" == "all" || ( "$_QR_MODE" != "none" && $_INDEX -eq 1 ) ]]' "$SCRIPT" \
        || fail 'config display does not limit default QR rendering to the first recommended config'
    grep_fixed 'QR_DIR="$DATA_DIR/qr"' "$SCRIPT" \
        || fail 'script does not define a private QR export directory'
    grep_fixed 'write_config_qr_png()' "$SCRIPT" \
        || fail 'script does not export high-resolution QR PNG files'
    grep_fixed 'qrencode -m 4 -s 8 -t PNG -o "$png_file" "$link"' "$SCRIPT" \
        || fail 'QR PNG export does not use a scan-friendly quiet zone and scale'
    grep_fixed 'qrencode -m 2 -t UTF8 "$link"' "$SCRIPT" \
        || fail 'terminal QR renderer does not use a less cramped quiet-zone margin'
    grep_fixed 'High-res QR PNG' "$SCRIPT" \
        || fail 'config view does not show where the scan-friendly QR PNG was saved'
    grep_fixed 'QR PNG files are saved under' "$SCRIPT" \
        || fail 'config view does not summarize the QR PNG export location'
    grep_fixed 'Terminal zoom/theme can make QR scanning unreliable' "$SCRIPT" \
        || fail 'config view does not explain the copy-link fallback when QR scanning fails'
    grep_fixed 'printf '\''%s\n'\'' "$link"' "$SCRIPT" \
        || fail 'config links are not printed as raw copy-ready lines'
    grep_fixed 'write_config_exports_from_links()' "$SCRIPT" \
        || fail 'script does not provide an export writer for an existing displayed link list'
    grep_fixed 'write_config_exports_from_links "${_CONFIG_LINKS[@]}"' "$SCRIPT" \
        || fail 'display path does not export the exact links it shows'
    if grep_fixed 'printf '\''%s\n'\'' "${_CONFIG_LINKS[@]}" > "$MOBILE_CONFIG_FILE"' "$SCRIPT"; then
        fail 'display path still writes mobile config directly before recomputing exports'
    fi
    grep_fixed 'Recommended IP link' "$SCRIPT" \
        || fail 'display does not label the primary IP config clearly'
    grep_fixed 'Domain link' "$SCRIPT" \
        || fail 'display does not label the domain config clearly'
    if grep_fixed 'qrencode -m 2 -t ANSIUTF8 "$_VLESS_PRIMARY"' "$SCRIPT"; then
        fail 'display still renders only one large QR code'
    fi
    if grep_fixed 'sed "s/^/  ${WHITE}/;s/$/${NC}/"' "$SCRIPT"; then
        fail 'display still pipes colored links through sed, which corrupts copied configs'
    fi
    if grep_fixed '"$_VLESS_IP"' "$SCRIPT"; then
        fail 'display/copy paths still reference the old singular fallback variable'
    fi
    if grep_fixed 'address=$(resolve_domain_ip "$PORT_DOMAIN")' "$SCRIPT"; then
        fail 'IP fallback still falls back to the domain when no IP resolves'
    fi
    pass 'generated links include domain and multiple IP variants'
}

test_terminal_branding_is_customized_red() {
    grep_fixed 'echo -e "${RED}${B}"' "$SCRIPT" \
        || fail 'logo banner is not rendered in red'
    grep_fixed 'Educational use only' "$SCRIPT" \
        || fail 'logo banner does not show educational-use notice'
    grep_fixed 'Customized' "$SCRIPT" \
        || fail 'logo banner does not show customized branding'
    pass 'terminal branding is red and educational-use labeled'
}

test_runtime_diagnostics_logging() {
    grep_fixed 'LOG_FILE=' "$SCRIPT" \
        || fail 'script does not define an application log file'
    grep_fixed 'log_event()' "$SCRIPT" \
        || fail 'script does not define structured runtime logging'
    grep_fixed 'fingerprint_secret()' "$SCRIPT" \
        || fail 'script does not define a helper for secret-safe fingerprints'
    grep_fixed 'fingerprint_secret "$uuid"' "$SCRIPT" \
        || fail 'config generation does not log a secret-safe UUID fingerprint'
    grep_fixed 'log_event INFO "xray launched' "$SCRIPT" \
        || fail 'start_xray does not log successful launches'
    grep_fixed 'log_event INFO "force_reconnect begin' "$SCRIPT" \
        || fail 'force reconnect does not log start of reconnect flow'
    grep_fixed '[[ "$code" != "000" && "$code" != "0" ]]' "$SCRIPT" \
        || fail 'external reconnect verification does not distinguish reachable HTTP edge responses from connection failure'
    grep_fixed 'verify_external edge_reachable=' "$SCRIPT" \
        || fail 'external reconnect verification does not log whether the Codespaces edge is reachable'
    grep_fixed 'local no_prompt="${1:-}" failed=0' "$SCRIPT" \
        || fail 'force reconnect does not track failure state'
    grep_fixed 'if stop_xray >/dev/null 2>&1; then' "$SCRIPT" \
        || fail 'force reconnect does not handle stop_xray failure explicitly'
    grep_fixed 'return "$failed"' "$SCRIPT" \
        || fail 'force reconnect does not return failure to the watchdog'
    if grep_fixed 'verify_external reachable=' "$SCRIPT"; then
        fail 'external reconnect verification still uses ambiguous reachable logging'
    fi
    grep_fixed 'fallback_candidates=' "$SCRIPT" \
        || fail 'resolver does not log mixed fallback IP candidates clearly'
    grep_fixed 'Fallback IP Candidates' "$SCRIPT" \
        || fail 'diagnostics still labels mixed fallback candidates as purely resolved IPs'
    grep_fixed 'includes resolved, manual, and built-in fallbacks' "$SCRIPT" \
        || fail 'diagnostics does not disclose that fallback IPs may include built-in candidates'
    grep_fixed 'curl_remote_ip()' "$SCRIPT" \
        || fail 'script does not use curl remote_ip as a resolver fallback'
    grep_fixed 'curl_remote_ip "$domain"' "$SCRIPT" \
        || fail 'multi-IP resolver does not include curl remote_ip fallback'
    grep_fixed 'curl_remote_ip "$domain" || true' "$SCRIPT" \
        || fail 'curl remote_ip fallback can abort resolver when no remote IP is found'
    grep_fixed 'health_probe()' "$SCRIPT" \
        || fail 'script does not define a periodic health probe'
    grep_fixed 'log_event INFO "health engine=' "$SCRIPT" \
        || fail 'health probe does not log engine/listener/public endpoint state'
    grep_fixed 'health_probe >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not run periodic health probes'
    grep_fixed 'refresh_config_exports()' "$SCRIPT" \
        || fail 'script does not define a config export refresher'
    grep_fixed 'SUBSCRIPTION_FILE=' "$SCRIPT" \
        || fail 'script does not define a base64 subscription export file'
    grep_fixed 'generate_ordered_links()' "$SCRIPT" \
        || fail 'script does not generate a stable ordered failover config list'
    grep_fixed 'base64 | tr -d' "$SCRIPT" \
        || fail 'script does not generate a single-line base64 subscription export'
    grep_fixed 'refresh_config_exports >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not refresh exported fallback configs'
    grep_fixed 'self_heal_once()' "$SCRIPT" \
        || fail 'script does not define a self-healing watchdog pass'
    grep_fixed 'self_heal_once >/dev/null 2>&1' "$SCRIPT" \
        || fail 'background supervisor does not run the self-healing watchdog'
    grep_fixed 'reason=listener_closed' "$SCRIPT" \
        || fail 'watchdog does not restart when the listener is closed'
    grep_fixed 'reason=xray_stopped' "$SCRIPT" \
        || fail 'watchdog does not restart when Xray is stopped'
    grep_fixed 'edge_unreachable' "$SCRIPT" \
        || fail 'watchdog does not detect an unreachable Codespaces edge'
    grep_fixed 'force_reconnect --no-prompt' "$SCRIPT" \
        || fail 'watchdog does not force reconnect when the Codespaces edge is unreachable'
    grep_fixed 'show_diagnostics()' "$SCRIPT" \
        || fail 'script does not provide a diagnostics view'
    grep_fixed '14)${NC} Diagnostics' "$SCRIPT" \
        || fail 'menu does not expose the diagnostics view'
    grep_fixed '14) show_diagnostics' "$SCRIPT" \
        || fail 'case statement does not route to diagnostics view'
    pass 'runtime diagnostics logging is present'
}

test_runtime_control_paths_are_hardened() {
    grep_fixed 'XRAY_PORT="${XRAY_PORT:-443}"' "$SCRIPT" \
        || fail 'XRAY_PORT documentation says it is configurable, but script still hard-codes 443'
    grep_fixed 'valid_codespace_name()' "$SCRIPT" \
        || fail 'codespace detection does not validate candidate names'
    grep_fixed '[[ "$name" != "null" ]]' "$SCRIPT" \
        || fail 'codespace detection can accept literal null as a real name'
    grep_fixed 'xray_listener_ready()' "$SCRIPT" \
        || fail 'engine readiness does not verify the Xray/XHTTP listener, only an open port'
    grep_fixed 'while ! xray_listener_ready && (( i < 15 )); do' "$SCRIPT" \
        || fail 'wait_for_port still succeeds on any listener bound to the port'
    grep_fixed 'ensure_runtime_ready "silent_start" >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail '--silent-start does not use the non-fatal health-gated startup path'
    grep_fixed 'if stop_xray; then' "$SCRIPT" \
        || fail 'interactive Stop Engine path does not handle stop_xray failure'
    pass 'runtime control paths are hardened'
}

test_startup_does_not_reconnect_healthy_runtime() {
    grep_fixed 'ensure_runtime_ready()' "$SCRIPT" \
        || fail 'script does not provide a health-gated startup path'
    grep_fixed 'runtime_ready reason=${reason} engine=running' "$SCRIPT" \
        || fail 'startup readiness path does not log when it reuses a healthy engine'
    grep_fixed 'action=skip_reconnect' "$SCRIPT" \
        || fail 'startup readiness path does not explicitly skip reconnects when healthy'
    if awk '
        /if \[\[ "\$\{1:-\}" == "--silent-start" \]\]; then/ { in_block=1 }
        in_block && /^[[:space:]]*fi[[:space:]]*$/ { exit }
        in_block && /stop_xray/ { bad=1; exit }
        END { exit bad ? 0 : 1 }
    ' "$SCRIPT"; then
        fail '--silent-start still stops Xray unconditionally'
    fi
    grep_fixed 'ensure_runtime_ready "interactive_attach" >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail 'interactive attach does not use health-gated startup'
    if grep_fixed 'force_reconnect --no-prompt || true' "$SCRIPT"; then
        fail 'interactive attach still force-reconnects existing configs'
    fi
    grep_fixed 'wait_for_xhttp_route_ready()' "$SCRIPT" \
        || fail 'startup path does not wait for app.github.dev route readiness after resume'
    grep_fixed 'G2RAY_ROUTE_WAIT_SEC' "$SCRIPT" \
        || fail 'startup route wait is not configurable'
    grep_fixed 'runtime_ready reason=${reason} route_wait_timeout' "$SCRIPT" \
        || fail 'startup route wait timeout is not logged for troubleshooting'
    pass 'startup paths do not reconnect a healthy runtime'
}

test_self_heal_uses_reconnect_backoff() {
    grep_fixed 'EDGE_BAD_COUNT_FILE=' "$SCRIPT" \
        || fail 'self-heal does not persist edge failure streaks'
    grep_fixed 'EDGE_RECONNECT_STAMP_FILE=' "$SCRIPT" \
        || fail 'self-heal does not persist reconnect cooldown timestamps'
    grep_fixed 'SELF_HEAL_RECONNECT_COOLDOWN_SEC=' "$SCRIPT" \
        || fail 'self-heal reconnect cooldown is not configurable'
    grep_fixed 'edge_unreachable code=${code:-0} bad_count=${bad_count} action=observe' "$SCRIPT" \
        || fail 'self-heal does not observe transient edge failures before reconnecting'
    grep_fixed 'edge_unreachable code=${code:-0} bad_count=${bad_count} action=force_reconnect' "$SCRIPT" \
        || fail 'self-heal does not log thresholded force reconnects'
    if grep_fixed 'edge_unreachable code=${code:-0} action=force_reconnect' "$SCRIPT"; then
        fail 'self-heal still force-reconnects on a single edge failure'
    fi
    pass 'self-heal reconnects are thresholded and cooled down'
}

test_probe_and_gh_commands_are_bounded() {
    grep_fixed 'curl_http_code()' "$SCRIPT" \
        || fail 'script has no helper to normalize curl transport failures'
    grep_fixed 'printf '\''0'\''' "$SCRIPT" \
        || fail 'curl_http_code does not normalize failed transports to a single 0'
    if grep_fixed 'w "%{http_code}" "https://${PORT_DOMAIN}" 2>/dev/null || echo "0"' "$SCRIPT"; then
        fail 'raw curl http_code probes can still emit 0000 on transport failure'
    fi
    grep_fixed 'run_gh()' "$SCRIPT" \
        || fail 'script has no bounded gh helper'
    grep_fixed 'timeout "${G2RAY_GH_TIMEOUT_SEC:-10}" gh' "$SCRIPT" \
        || fail 'gh helper does not bound GitHub CLI calls with timeout'
    grep_fixed 'run_gh codespace list --limit 1 --json name --jq' "$SCRIPT" \
        || fail 'codespace name detection still bypasses the bounded gh helper'
    grep_fixed 'run_gh codespace ports visibility "${XRAY_PORT}:public" -c "$CODESPACE_NAME"' "$SCRIPT" \
        || fail 'port visibility still bypasses the bounded gh helper'
    grep_fixed 'run_gh codespace ports -c "$CODESPACE_NAME"' "$SCRIPT" \
        || fail 'diagnostics port query still bypasses the bounded gh helper'
    pass 'curl probes and gh calls are bounded'
}

test_diagnostics_show_latency_and_supervisor_state() {
    grep_fixed 'xhttp_probe_metrics()' "$SCRIPT" \
        || fail 'diagnostics cannot measure XHTTP probe latency'
    grep_fixed 'CODESPACES_EDGE_PORT="${G2RAY_CODESPACES_EDGE_PORT:-443}"' "$SCRIPT" \
        || fail 'script does not define the external Codespaces HTTPS edge port separately from the internal Xray port'
    grep_fixed 'url="https://${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}${path}"' "$SCRIPT" \
        || fail 'external XHTTP probes do not include the Codespaces edge port in the URL, so fallback IP probes can test the wrong route'
    grep_fixed '--resolve "${PORT_DOMAIN}:${CODESPACES_EDGE_PORT}:${address}"' "$SCRIPT" \
        || fail 'fallback XHTTP probes do not bind --resolve to the same edge port used by the URL'
    grep_fixed 'xhttp_probe_ms=' "$SCRIPT" \
        || fail 'health/reconnect logs do not include XHTTP probe latency'
    grep_fixed 'BG_TASKS_HEARTBEAT_FILE=' "$SCRIPT" \
        || fail 'background supervisor heartbeat file is missing'
    grep_fixed 'background_supervisor_status()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize background supervisor state'
    grep_fixed 'Background Supervisor' "$SCRIPT" \
        || fail 'diagnostics do not show background supervisor state'
    grep_fixed 'Fallback Route Probes' "$SCRIPT" \
        || fail 'diagnostics do not probe fallback route latency'
    grep_fixed 'ms' "$SCRIPT" \
        || fail 'diagnostics do not display latency in milliseconds'
    pass 'diagnostics show probe latency and supervisor state'
}

test_diagnostics_show_self_heal_state() {
    grep_fixed 'self_heal_state_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize self-heal counters'
    grep_fixed 'Self-Heal State' "$SCRIPT" \
        || fail 'diagnostics do not show self-heal state'
    grep_fixed 'route_bad=' "$SCRIPT" \
        || fail 'self-heal summary omits route failure streak'
    grep_fixed 'edge_bad=' "$SCRIPT" \
        || fail 'self-heal summary omits edge failure streak'
    grep_fixed 'cooldown_remaining=' "$SCRIPT" \
        || fail 'self-heal summary omits reconnect cooldown'
    pass 'diagnostics show self-heal state'
}

test_diagnostics_show_last_known_state() {
    grep_fixed 'last_known_state_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize the last known failure/repair/export state'
    grep_fixed 'Last Known State' "$SCRIPT" \
        || fail 'diagnostics do not show the last known state section'
    grep_fixed 'Last failure :' "$SCRIPT" \
        || fail 'last known state omits the last failure line'
    grep_fixed 'Last repair  :' "$SCRIPT" \
        || fail 'last known state omits the last repair line'
    grep_fixed 'Last export  :' "$SCRIPT" \
        || fail 'last known state omits the last export line'
    grep_fixed 'route_unusable|edge_unreachable|engine_not_ready|started_route_unusable|started_route_still_unusable|port_public_failed|launch_failed|timeout|failed' "$SCRIPT" \
        || fail 'last known failure summary does not include known failure markers'
    pass 'diagnostics show last known state'
}

test_diagnostics_show_resume_gap_state() {
    grep_fixed 'RESUME_GAP_FILE=' "$SCRIPT" \
        || fail 'script does not persist detected Codespaces resume gaps'
    grep_fixed 'record_resume_gap()' "$SCRIPT" \
        || fail 'script cannot record a supervisor heartbeat gap on startup'
    grep_fixed 'resume_gap_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize the last resume gap'
    grep_fixed 'Resume Gap' "$SCRIPT" \
        || fail 'diagnostics do not show resume gap state'
    grep_fixed 'resume_gap reason=${reason}' "$SCRIPT" \
        || fail 'resume gap detection does not log the startup reason'
    grep_fixed 'record_resume_gap "$reason"' "$SCRIPT" \
        || fail 'runtime readiness does not record resume gaps before healing'
    grep_fixed 'record_resume_gap "interactive_attach"' "$SCRIPT" \
        || fail 'interactive attach can refresh the heartbeat before recording resume gaps'
    pass 'diagnostics show resume gap state'
}

test_local_reopen_helper_is_documented() {
    [[ -f "$REOPEN_SCRIPT" ]] || fail 'local Codespace reopen helper is missing'
    grep_fixed '--method POST "/user/codespaces/$Name/start"' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not use the official Codespaces start API'
    grep_fixed 'HTTP 402' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not explain quota/payment blocked starts'
    grep_fixed 'gh codespace code -c $Name' "$REOPEN_SCRIPT" \
        || fail 'reopen helper does not open the restarted Codespace in VS Code'
    grep_fixed 'scripts/reopen-codespace.ps1' "$README" \
        || fail 'README does not document the local reopen helper'
    grep_fixed 'Default idle timeout' "$README" \
        || fail 'README does not document setting the Codespaces idle timeout'
    grep_fixed '240 minutes' "$README" \
        || fail 'README does not recommend the maximum supported idle timeout'
    pass 'local reopen helper is documented'
}

test_cloudflare_worker_waker_is_safe_to_publish() {
    [[ -f "$WORKER_SCRIPT" ]] || fail 'Cloudflare Worker waker source is missing'
    [[ -f "$WORKER_README" ]] || fail 'Cloudflare Worker waker README is missing'
    [[ -f "$WORKER_WRANGLER_EXAMPLE" ]] || fail 'Cloudflare Worker wrangler example is missing'
    grep_fixed 'worker/codespace-waker/.dev.vars*' "$GITIGNORE" \
        || fail 'Worker local dev secrets are not ignored'
    grep_fixed 'worker/codespace-waker/.env' "$GITIGNORE" \
        || fail 'Worker local .env secrets are not ignored'
    grep_fixed 'worker/codespace-waker/.env.*' "$GITIGNORE" \
        || fail 'Worker local environment-specific .env secrets are not ignored'
    grep_fixed 'worker/codespace-waker/wrangler.toml' "$GITIGNORE" \
        || fail 'Worker local wrangler config is not ignored'
    grep_fixed 'env.GITHUB_TOKEN' "$WORKER_SCRIPT" \
        || fail 'Worker does not read GitHub token from Cloudflare secret env'
    grep_fixed 'env.WAKE_SECRET' "$WORKER_SCRIPT" \
        || fail 'Worker does not require a separate wake secret'
    grep_fixed 'authorization: `Bearer ${token}`' "$WORKER_SCRIPT" \
        || fail 'Worker does not call GitHub with a bearer token'
    grep_fixed '/user/codespaces/${encodeURIComponent(name)}/start' "$WORKER_SCRIPT" \
        || fail 'Worker does not call the Codespaces start endpoint'
    grep_fixed 'reason: "quota_or_billing_blocked"' "$WORKER_SCRIPT" \
        || fail 'Worker does not classify HTTP 402 quota/billing failures'
    grep_fixed 'githubErrorDetail(body)' "$WORKER_SCRIPT" \
        || fail 'Worker does not redact GitHub error response details'
    grep_fixed 'idle_timeout_minutes:' "$WORKER_SCRIPT" \
        || fail 'Worker success response does not retain useful redacted status fields'
    grep_fixed 'waitForXhttpRoute(name, codespacePort(env))' "$WORKER_SCRIPT" \
        || fail 'Worker does not wait for the Codespaces XHTTP route after start'
    grep_fixed 'method: "OPTIONS"' "$WORKER_SCRIPT" \
        || fail 'Worker route readiness probe does not use the XHTTP OPTIONS probe'
    grep_fixed 'route_ready:' "$WORKER_SCRIPT" \
        || fail 'Worker response does not report route readiness'
    grep_fixed 'ROUTE_WAIT_MS' "$WORKER_SCRIPT" \
        || fail 'Worker route readiness wait is not bounded'
    grep_fixed 'wake_secret' "$WORKER_SCRIPT" \
        || fail 'Worker browser form cannot submit the wake secret'
    grep_fixed 'wrangler secret put GITHUB_TOKEN' "$WORKER_README" \
        || fail 'Worker README does not instruct storing GitHub token as a secret'
    grep_fixed 'wrangler secret put WAKE_SECRET' "$WORKER_README" \
        || fail 'Worker README does not instruct storing wake secret as a secret'
    grep_fixed 'Cloudflare Worker Waker' "$README" \
        || fail 'root README does not mention the Cloudflare Worker waker'
    for file in "$WORKER_SCRIPT" "$WORKER_README" "$WORKER_WRANGLER_EXAMPLE"; do
        if grep_regex 'ghp_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}' "$file" 2>/dev/null; then
            fail 'Worker files appear to contain a GitHub token'
        fi
    done
    pass 'Cloudflare Worker waker is safe to publish'
}

test_worker_dashboard_and_history_features() {
    grep_fixed 'renderDashboard()' "$WORKER_SCRIPT" \
        || fail 'Worker does not render a mobile dashboard page'
    grep_fixed 'Start Codespace' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not expose a clear start button'
    grep_fixed 'Check Health' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not expose a health check action'
    grep_fixed '/api/wake' "$WORKER_SCRIPT" \
        || fail 'Worker does not expose a dashboard wake API'
    grep_fixed '/api/health' "$WORKER_SCRIPT" \
        || fail 'Worker does not expose a dashboard health API'
    grep_fixed '/api/history' "$WORKER_SCRIPT" \
        || fail 'Worker does not expose a dashboard history API'
    grep_fixed 'getCodespaceStatus(codespaceName, env.GITHUB_TOKEN)' "$WORKER_SCRIPT" \
        || fail 'Worker health API does not query the GitHub Codespace state'
    grep_fixed 'recordHistory(env, {' "$WORKER_SCRIPT" \
        || fail 'Worker does not persist wake/health events when KV is configured'
    grep_fixed 'env.WAKER_KV' "$WORKER_SCRIPT" \
        || fail 'Worker does not support optional KV-backed history'
    grep_fixed 'HISTORY_LIMIT' "$WORKER_SCRIPT" \
        || fail 'Worker history is not bounded'
    grep_fixed 'sendNotifications(env, event)' "$WORKER_SCRIPT" \
        || fail 'Worker does not offer optional notification hooks'
    grep_fixed 'DISCORD_WEBHOOK_URL' "$WORKER_SCRIPT" \
        || fail 'Worker does not support Discord webhook notifications'
    grep_fixed 'TELEGRAM_BOT_TOKEN' "$WORKER_SCRIPT" \
        || fail 'Worker does not support Telegram bot notifications'
    grep_fixed 'TELEGRAM_CHAT_ID' "$WORKER_SCRIPT" \
        || fail 'Worker does not support Telegram chat routing'
    grep_fixed 'GitHub token rejected or expired' "$WORKER_SCRIPT" \
        || fail 'Worker UI/API does not warn clearly about rejected or expired GitHub tokens'
    grep_fixed 'GITHUB_STATE_WAIT_MS' "$WORKER_SCRIPT" \
        || fail 'Worker wake flow does not wait for GitHub Codespace state readiness'
    grep_fixed 'waitForCodespaceAvailable(name, token)' "$WORKER_SCRIPT" \
        || fail 'Worker wake flow probes route before waiting for Codespace availability'
    grep_fixed 'isRouteStatusUsable(res.status)' "$WORKER_SCRIPT" \
        || fail 'Worker route readiness does not share the panel status classifier'
    grep_fixed 'return status === 200 || status === 400;' "$WORKER_SCRIPT" \
        || fail 'Worker route readiness does not treat HTTP 400 as usable like the panel'
    grep_fixed 'next_action' "$WORKER_SCRIPT" \
        || fail 'Worker API does not return a concrete next action when route is not ready'
    grep_fixed 'copyStatus' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not provide a copy-status action'
    grep_fixed 'setTimeout(checkHealth' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not auto-refresh while the route is settling'
    grep_fixed 'fetchWithTimeout(' "$WORKER_SCRIPT" \
        || fail 'Worker GitHub/route fetches are not individually time-bounded'
    grep_fixed 'github_start_request_unreachable' "$WORKER_SCRIPT" \
        || fail 'Worker start timeout/network errors are not returned as structured JSON'
    grep_fixed 'github_status_request_unreachable' "$WORKER_SCRIPT" \
        || fail 'Worker status timeout/network errors are not returned as structured JSON'
    grep_fixed 'routeSettlingFailureText(data, route, routeReady)' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard can still report no failure while the route is settling'
    grep_fixed 'data.start_accepted && data.route_ready === false && isRouteSettlingStatus(data.route_probe)' "$WORKER_SCRIPT" \
        || fail 'Worker HTTP status does not distinguish accepted-but-route-settling responses'
    grep_fixed 'Route history summary' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not summarize route health history'
    grep_fixed 'latencyTrend' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not render a latency trend'
    grep_fixed 'renderHistorySummary' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not compute history summary metrics'
    grep_fixed 'History request failed:' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard hides unauthorized or failed history requests'
    grep_fixed 'WAKER_KV' "$WORKER_README" \
        || fail 'Worker README does not document optional KV history'
    grep_fixed 'DISCORD_WEBHOOK_URL' "$WORKER_README" \
        || fail 'Worker README does not document optional Discord alerts'
    grep_fixed 'TELEGRAM_BOT_TOKEN' "$WORKER_README" \
        || fail 'Worker README does not document optional Telegram alerts'
    grep_fixed 'Health dashboard' "$README" \
        || fail 'root README does not mention the private Worker health dashboard'
    pass 'Worker dashboard, history, and alert features are documented'
}

test_worker_wake_edge_cases_are_hardened() {
    grep_fixed 'isTransientGithubStatusFailure(last)' "$WORKER_SCRIPT" \
        || fail 'Worker wake flow does not retry transient GitHub status failures'
    grep_fixed 'if (!last.ok && isTransientGithubStatusFailure(last)) {' "$WORKER_SCRIPT" \
        || fail 'Worker status wait does not continue after transient status failures'
    grep_fixed 'function isRouteSettlingStatus(routeProbe)' "$WORKER_SCRIPT" \
        || fail 'Worker has no narrow route-settling classifier for 202 responses'
    grep_fixed 'id="stop"' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard has no stop-polling control'
    grep_fixed 'function stopPolling()' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard cannot stop background health polling'
    grep_fixed 'document.getElementById("stop").addEventListener("click", stopPolling)' "$WORKER_SCRIPT" \
        || fail 'Worker stop-polling button is not wired to stopPolling'
    grep_fixed 'function scheduleHealthPoll()' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not centralize health polling through a managed timer'
    grep_fixed 'pollTimer = setTimeout(checkHealth, 5000)' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard polling is not tracked through pollTimer'
    grep_fixed 'clearTimeout(pollTimer)' "$WORKER_SCRIPT" \
        || fail 'Worker dashboard does not clear pending poll timers'
    grep_fixed 'historyKey(codespace)' "$WORKER_SCRIPT" \
        || fail 'Worker KV history is not namespaced by Codespace'
    grep_fixed 'readHistory(env, context.codespaceName)' "$WORKER_SCRIPT" \
        || fail 'Worker history API does not read the current Codespace namespace'
    grep_fixed '`401`: Wrong wake secret, or GitHub rejected the stored token' "$WORKER_README" \
        || fail 'Worker README does not distinguish wake-secret 401 from GitHub-token 401'
    pass 'Worker wake edge cases are hardened'
}

test_worker_rate_limits_and_classifies_github_errors() {
    grep_fixed 'rateLimitFailedAuth(request, env)' "$WORKER_SCRIPT" \
        || fail 'Worker does not rate-limit failed wake-secret attempts'
    grep_fixed 'githubFailureForResponse(res, body, codespaceName)' "$WORKER_SCRIPT" \
        || fail 'Worker does not centralize GitHub error classification'
    grep_fixed 'github_rate_limited' "$WORKER_SCRIPT" \
        || fail 'Worker does not distinguish GitHub rate limit failures'
    grep_fixed 'res.status === 429' "$WORKER_SCRIPT" \
        || fail 'Worker does not classify direct GitHub HTTP 429 failures'
    grep_fixed 'github_secondary_rate_limited' "$WORKER_SCRIPT" \
        || fail 'Worker does not distinguish secondary rate limits'
    grep_fixed 'status: 429' "$WORKER_SCRIPT" \
        || fail 'Worker does not return 429 for rate-limit conditions'
    grep_fixed 'data.next_action = data.next_action || nextActionForWake(data, data.route_probe || {})' "$WORKER_SCRIPT" \
        || fail 'Worker wake failures do not include next_action guidance'
    grep_fixed 'FAILED_AUTH_KEY_PREFIX' "$WORKER_SCRIPT" \
        || fail 'Worker failed-auth rate limit is not persisted in KV'
    pass 'Worker rate-limits bad secrets and classifies GitHub failures'
}

test_route_candidate_monitor_is_bounded() {
    grep_fixed 'ROUTE_HEALTH_FILE=' "$SCRIPT" \
        || fail 'route candidate monitor has no bounded health cache file'
    grep_fixed 'ROUTE_MONITOR_MAX_CANDIDATES=' "$SCRIPT" \
        || fail 'route candidate monitor does not cap candidate probes'
    grep_fixed 'refresh_route_candidate_health()' "$SCRIPT" \
        || fail 'route candidate monitor cannot refresh candidate health'
    grep_fixed 'route_candidate_health_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize route candidate health'
    grep_fixed 'record_route_candidate_health "$ip" "$ip_probe" "$ip_ms"' "$SCRIPT" \
        || fail 'route candidate monitor does not persist per-candidate probe results'
    grep_fixed 'refresh_route_candidate_health >/dev/null 2>&1 || true' "$SCRIPT" \
        || fail 'background supervisor does not refresh route candidate health'
    grep_fixed 'route_candidate_health_summary | sed' "$SCRIPT" \
        || fail 'diagnostics do not display route candidate health'
    if grep_regex 'for[[:space:]]+.*in[[:space:]]+.*(/8|/16|/24|seq[[:space:]]+1[[:space:]]+254)' "$SCRIPT"; then
        fail 'route candidate monitor appears to scan broad address ranges'
    fi
    pass 'route candidate monitor is bounded and diagnostics-visible'
}

test_route_candidate_manager_and_live_monitor_are_present() {
    grep_fixed 'MANUAL_ROUTE_CANDIDATES_FILE=' "$SCRIPT" \
        || fail 'manual route candidate file is not defined'
    grep_fixed 'BLACKLISTED_ROUTE_CANDIDATES_FILE=' "$SCRIPT" \
        || fail 'blacklisted route candidate file is not defined'
    grep_fixed 'PINNED_ROUTE_FILE=' "$SCRIPT" \
        || fail 'pinned route file is not defined'
    grep_fixed 'valid_ipv4()' "$SCRIPT" \
        || fail 'route manager has no IPv4 validator'
    grep_fixed 'add_manual_route_candidate()' "$SCRIPT" \
        || fail 'route manager cannot add manual IPv4 candidates'
    grep_fixed 'blacklist_route_candidate()' "$SCRIPT" \
        || fail 'route manager cannot blacklist bad routes'
    grep_fixed 'pin_route_candidate()' "$SCRIPT" \
        || fail 'route manager cannot pin a preferred route'
    grep_fixed 'reset_route_candidate_cache()' "$SCRIPT" \
        || fail 'route manager cannot reset measured route health without wiping preferences'
    grep_fixed 'reset_route_candidate_state()' "$SCRIPT" \
        || fail 'route manager cannot reset all route preferences'
    grep_fixed 'Reset Route Health Cache' "$SCRIPT" \
        || fail 'route manager UI does not distinguish cache reset from preference reset'
    grep_fixed 'Reset All Route Preferences' "$SCRIPT" \
        || fail 'route manager UI does not expose an explicit full preference reset'
    grep_fixed 'show_route_candidate_manager()' "$SCRIPT" \
        || fail 'route candidate manager screen is missing'
    grep_fixed 'show_live_monitor()' "$SCRIPT" \
        || fail 'live monitor screen is missing'
    grep_fixed '16)${NC} Live Monitor' "$SCRIPT" \
        || fail 'main menu does not expose live monitor'
    grep_fixed '17)${NC} Route Candidates' "$SCRIPT" \
        || fail 'main menu does not expose route candidates manager'
    grep_fixed '16) show_live_monitor' "$SCRIPT" \
        || fail 'case statement does not route to live monitor'
    grep_fixed '17) show_route_candidate_manager' "$SCRIPT" \
        || fail 'case statement does not route to route candidate manager'
    grep_fixed 'pinned_route_value' "$SCRIPT" \
        || fail 'cached route ordering does not consider pinned routes'
    grep_fixed 'while IFS= read -r ip; do' "$SCRIPT" \
        || fail 'resolver does not include persisted pinned/manual route candidates'
    grep_fixed 'append_unique_route "$MANUAL_ROUTE_CANDIDATES_FILE" "$ip" || return 1' "$SCRIPT" \
        || fail 'manual route additions do not report persistence failures'
    grep_fixed '_atomic_write "$PINNED_ROUTE_FILE" "$ip" || return 1' "$SCRIPT" \
        || fail 'pinned routes do not report persistence failures'
    grep_fixed 'append_unique_route "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$ip" || return 1' "$SCRIPT" \
        || fail 'blacklisted route additions do not report persistence failures'
    grep_fixed 'remove_route_from_file "$BLACKLISTED_ROUTE_CANDIDATES_FILE" "$ip" || return 1' "$SCRIPT" \
        || fail 'unblacklist does not report no-op or persistence failures'
    grep_fixed 'candidate_blacklisted "$ip"' "$SCRIPT" \
        || fail 'route exports do not filter blacklisted routes'
    grep_fixed 'Route Candidates' "$README" \
        || fail 'README does not document route candidate manager'
    pass 'route candidate manager and live monitor are present'
}

test_first_run_recovery_card_is_present() {
    grep_fixed 'show_recovery_command_card()' "$SCRIPT" \
        || fail 'first-run recovery command card helper is missing'
    grep_fixed 'bash ./g2ray.sh --doctor-json' "$SCRIPT" \
        || fail 'recovery command card does not show doctor JSON command'
    grep_fixed 'bash ./g2ray.sh --recover-now' "$SCRIPT" \
        || fail 'recovery command card does not show recover command'
    grep_fixed 'replace <WAKE_SECRET>' "$SCRIPT" \
        || fail 'recovery command card does not avoid printing the raw wake secret'
    grep_fixed 'copy these recovery commands' "$README" \
        || fail 'README does not mention the recovery command card'
    pass 'first-run recovery card is present'
}

test_soft_recovery_and_route_memory_are_present() {
    grep_fixed 'recover_now()' "$SCRIPT" \
        || fail 'panel has no idempotent soft recovery path'
    grep_fixed 'recover_now --no-prompt' "$SCRIPT" \
        || fail 'headless recover command is not wired'
    grep_fixed '--doctor-json' "$SCRIPT" \
        || fail 'panel has no headless doctor JSON command'
    grep_fixed 'print_doctor_json()' "$SCRIPT" \
        || fail 'doctor JSON renderer is missing'
    grep_fixed 'doctor_port=443' "$SCRIPT" \
        || fail 'doctor JSON does not sanitize invalid port values'
    grep_fixed 'ensure_codespace_port_public force' "$SCRIPT" \
        || fail 'hard repair paths cannot bypass port-public throttling'
    grep_fixed 'PORT_PUBLIC_STAMP_FILE=' "$SCRIPT" \
        || fail 'port visibility calls are not timestamp-throttled'
    grep_fixed 'PORT_PUBLIC_STAMP_FILE}.${CODESPACE_NAME}.${XRAY_PORT}' "$SCRIPT" \
        || fail 'port visibility cache is not scoped by codespace and port'
    grep_fixed 'LAST_GOOD_ROUTE_FILE=' "$SCRIPT" \
        || fail 'last-good route is not persisted'
    grep_fixed 'save_last_good_route()' "$SCRIPT" \
        || fail 'last-good route save helper is missing'
    grep_fixed 'cached_usable_fallback_ips()' "$SCRIPT" \
        || fail 'exports cannot use cached route health'
    grep_fixed 'route_health_cache_fresh()' "$SCRIPT" \
        || fail 'route health cache has no freshness guard'
    grep_fixed 'Route Settling History' "$SCRIPT" \
        || fail 'diagnostics do not expose route-settling history'
    grep_fixed 'record_route_settling_metric "$reason" "ready"' "$SCRIPT" \
        || fail 'route wait does not record ready timing'
    grep_fixed 'attempt=$(( attempt + 1 ))' "$SCRIPT" \
        || fail 'route wait does not count the first probe attempt'
    grep_fixed 'record_route_settling_metric "$reason" "timeout"' "$SCRIPT" \
        || fail 'route wait does not record timeout timing'
    grep_fixed 'STRUCTURED_LOG_FILE=' "$SCRIPT" \
        || fail 'structured persistent log file is not defined'
    grep_fixed 'DIAGNOSTIC_LOG_FILE=' "$SCRIPT" \
        || fail 'readable persistent diagnostic log file is not defined'
    grep_fixed '>> "$DIAGNOSTIC_LOG_FILE"' "$SCRIPT" \
        || fail 'diagnostic snapshots are not written to the diagnostic log'
    grep_fixed 'log_diagnostic_snapshot "interactive"' "$SCRIPT" \
        || fail 'diagnostics do not write a persistent snapshot'
    grep_fixed '6) recover_now' "$SCRIPT" \
        || fail 'menu option 6 does not use soft recovery first'
    pass 'soft recovery, route memory, headless status, and persistent logs are present'
}

test_route_export_and_reconnect_edges_are_hardened() {
    if grep_fixed 'fallback_route_filter no-usable-probes action=export-candidates' "$SCRIPT"; then
        fail 'fallback exports still emit candidates after all route probes failed'
    fi
    grep_fixed 'fallback_route_filter no-usable-probes action=domain-only' "$SCRIPT" \
        || fail 'fallback exports do not fall back to the domain link only when IP probes fail'
    awk '
        /generate_config\(\)/ { in_fn=1 }
        in_fn && index($0, "refresh_config_exports >/dev/null 2>&1 || true") { saw=1 }
        in_fn && /^generate_link_for_address\(\)/ { exit }
        END { exit saw ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'new config generation does not refresh exported config files'
    grep_fixed 'FORCE_RECONNECT_ROUTE_WAIT_SEC' "$SCRIPT" \
        || fail 'force reconnect has no dedicated route-settling wait budget'
    grep_fixed 'XRAY_PORT=443' "$SCRIPT" \
        || fail 'invalid XRAY_PORT input is not sanitized to 443'
    grep_fixed 'wait_for_xhttp_route_ready "force_reconnect" "$FORCE_RECONNECT_ROUTE_WAIT_SEC"' "$SCRIPT" \
        || fail 'force reconnect does not reuse the route-settling wait loop'
    grep_fixed 'local no_prompt="${1:-}" failed=0 expose_failed=false hard_failed=false' "$SCRIPT" \
        || fail 'force reconnect does not track expose-tunnel failure separately'
    grep_fixed '[[ "$expose_failed" == true && "$hard_failed" != true ]] && failed=0' "$SCRIPT" \
        || fail 'force reconnect does not treat a usable route as success after a flaky port visibility command'
    grep_fixed 'DIAGNOSTIC_MAX_FALLBACK_PROBES' "$SCRIPT" \
        || fail 'diagnostics fallback probes are not capped'
    grep_fixed 'if (( probed >= max_probe )); then' "$SCRIPT" \
        || fail 'diagnostics fallback probes do not enforce the configured cap'
    grep_fixed 'additional candidates skipped' "$SCRIPT" \
        || fail 'diagnostics does not disclose when fallback probes are capped'
    pass 'route export and reconnect edges are hardened'
}

test_panel_guides_cloudflare_waker_setup() {
    grep_fixed 'WAKER_METADATA_FILE=' "$SCRIPT" \
        || fail 'panel does not persist non-sensitive waker metadata'
    grep_fixed 'generate_wake_secret()' "$SCRIPT" \
        || fail 'panel cannot generate a one-time wake secret'
    grep_fixed 'save_waker_metadata()' "$SCRIPT" \
        || fail 'panel cannot save the configured Worker URL metadata'
    grep_fixed 'waker_metadata_summary()' "$SCRIPT" \
        || fail 'diagnostics cannot summarize configured waker metadata'
    grep_fixed 'setup_cloudflare_waker()' "$SCRIPT" \
        || fail 'panel does not provide a guided Cloudflare Worker setup flow'
    grep_fixed 'test_cloudflare_waker()' "$SCRIPT" \
        || fail 'panel cannot test a configured Worker URL on demand'
    grep_fixed 'reset_waker_metadata()' "$SCRIPT" \
        || fail 'panel cannot clear saved waker metadata'
    grep_fixed 'show_recovery_waker()' "$SCRIPT" \
        || fail 'panel does not expose a recovery/waker menu screen'
    grep_fixed '15)${NC} Recovery / Waker Setup' "$SCRIPT" \
        || fail 'main menu does not expose recovery/waker setup'
    grep_fixed '15) show_recovery_waker' "$SCRIPT" \
        || fail 'case statement does not route to the recovery/waker setup screen'
    grep_fixed '1) setup_cloudflare_waker' "$SCRIPT" \
        || fail 'recovery submenu does not route to setup'
    grep_fixed '2) show_waker_recovery_guide' "$SCRIPT" \
        || fail 'recovery submenu does not route to instructions'
    grep_fixed 'test_cloudflare_waker || true' "$SCRIPT" \
        || fail 'recovery submenu does not route to Worker testing'
    grep_fixed '4) reset_waker_metadata' "$SCRIPT" \
        || fail 'recovery submenu does not route to metadata reset'
    grep_fixed 'Do not paste the GitHub token into G2ray' "$SCRIPT" \
        || fail 'wizard does not warn users not to store GitHub tokens in the panel'
    grep_fixed 'https://github.com/settings/tokens/new?scopes=codespace' "$SCRIPT" \
        || fail 'wizard does not give a direct GitHub token creation path'
    grep_fixed 'as a ${WHITE}Plaintext${NC} variable' "$SCRIPT" \
        || fail 'wizard does not clarify the CODESPACE_NAME Cloudflare binding type'
    grep_fixed 'Add these as ${WHITE}Secret${NC} variables' "$SCRIPT" \
        || fail 'wizard does not clarify GitHub token and wake secret binding types'
    grep_fixed 'Worker wake URL (https optional, /wake optional)' "$SCRIPT" \
        || fail 'wizard does not clarify acceptable Worker URL formats'
    grep_fixed 'CODESPACE_PORT' "$SCRIPT" \
        || fail 'wizard does not mention the optional custom port Worker binding'
    grep_fixed 'route_ready: false' "$SCRIPT" \
        || fail 'recovery guide does not explain route settling after wake'
    grep_fixed 'The wake secret is shown once' "$SCRIPT" \
        || fail 'wizard does not warn that the raw wake secret is not persisted'
    grep_fixed '^https://([A-Za-z0-9][A-Za-z0-9.-]*[.][A-Za-z0-9.-]+)' "$SCRIPT" \
        || fail 'waker URL normalization does not reject obvious non-URL secret input'
    grep_fixed 'printf '\''https://%s%s/wake'\''' "$SCRIPT" \
        || fail 'waker URL normalization does not canonicalize trailing /wake slashes'
    grep_fixed 'read -r answer || { touch "$WAKER_PROMPT_FILE"' "$SCRIPT" \
        || fail 'one-time waker prompt is not EOF-safe under set -e'
    grep_fixed 'rm -f "$WAKER_METADATA_FILE"' "$SCRIPT" \
        || fail 'reset path does not clear saved waker metadata'
    grep_fixed 'touch "$WAKER_PROMPT_FILE"' "$SCRIPT" \
        || fail 'reset/prompt paths do not preserve the one-time prompt marker'
    grep_fixed 'Default idle timeout' "$SCRIPT" \
        || fail 'wizard does not guide users to the GitHub idle timeout setting'
    grep_fixed '240 minutes' "$SCRIPT" \
        || fail 'wizard does not recommend the 240 minute idle timeout'
    grep_fixed 'Authorization: Bearer' "$SCRIPT" \
        || fail 'wizard/test flow does not use the safer bearer secret form'
    grep_fixed 'WAKER_TEST_TIMEOUT_SEC' "$SCRIPT" \
        || fail 'panel Worker test timeout is not configurable for long wake waits'
    grep_fixed 'curl -sS -m "$WAKER_TEST_TIMEOUT_SEC"' "$SCRIPT" \
        || fail 'panel Worker test still uses a fixed short curl timeout'
    grep_fixed 'fingerprint_secret "$wake_secret"' "$SCRIPT" \
        || fail 'wizard does not store only a fingerprint of the wake secret'
    if grep_fixed 'GITHUB_TOKEN=' "$SCRIPT"; then
        fail 'panel appears to store a GitHub token assignment'
    fi
    pass 'panel guides Cloudflare waker setup without storing tokens'
}

test_diagnostics_show_external_waker_state() {
    awk '
        /show_diagnostics\(\)/ { in_fn=1 }
        in_fn && /External Waker/ { saw_title=1 }
        in_fn && /waker_metadata_summary \| sed/ { saw_summary=1 }
        in_fn && /^}/ { exit }
        END { exit (saw_title && saw_summary) ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'diagnostics do not render the waker metadata summary'
    grep_fixed 'Status      : configured' "$SCRIPT" \
        || fail 'waker summary cannot report configured status'
    grep_fixed 'Status      : not configured' "$SCRIPT" \
        || fail 'waker summary cannot report missing setup'
    grep_fixed 'Next step   : open option 15' "$SCRIPT" \
        || fail 'waker summary does not point users to the recovery setup option'
    grep_fixed 'Worker URL  :' "$SCRIPT" \
        || fail 'waker summary omits the Worker URL'
    grep_fixed 'Secret      : fingerprint=' "$SCRIPT" \
        || fail 'waker summary omits the wake secret fingerprint'
    pass 'diagnostics show external waker state'
}

test_docs_cover_panel_waker_setup() {
    grep_fixed 'Option 15' "$README" \
        || fail 'README does not document the panel recovery setup option'
    grep_fixed 'choose `1) Generate Config & Start`' "$README" \
        || fail 'README fresh-start flow does not tell users which panel option to choose'
    grep_fixed 'Do not paste the GitHub token into G2ray' "$README" \
        || fail 'README does not warn against storing GitHub tokens in the panel'
    grep_fixed 'The wake secret is shown once' "$README" \
        || fail 'README does not explain one-time wake secret handling'
    grep_fixed 'Recovery / Waker Setup' "$README" \
        || fail 'README does not name the recovery setup screen'
    grep_fixed 'set Default idle timeout to 240 minutes' "$README" \
        || fail 'README does not connect recovery setup to the 240 minute idle timeout'
    grep_fixed 'Recovery / Waker Setup' "$WORKER_README" \
        || fail 'Worker README does not mention the panel setup flow'
    grep_fixed 'GET /wake` page is public' "$README" \
        || fail 'README does not clarify that the Worker page is public but actions are protected'
    grep_fixed 'GET /wake` page is public' "$WORKER_README" \
        || fail 'Worker README does not clarify that the page is public but actions are protected'
    grep_fixed 'return to panel option `15) Recovery / Waker Setup`' "$README" \
        || fail 'README does not tell users to return to option 15 after Worker deployment'
    grep_fixed 'return to **Option 15: Recovery / Waker Setup** after deploy' "$WORKER_README" \
        || fail 'Worker README does not tell users to return to option 15 after deploy'
    grep_fixed 'bash ./g2ray.sh --silent-start' "$README" \
        || fail 'README does not document the post-pull runtime refresh command'
    grep_fixed '`--recover-now` is non-interactive and soft-only' "$README" \
        || fail 'README does not clarify headless recover limitations'
    grep_fixed 'wake attempts' "$WORKER_README" \
        || fail 'Worker README overstates or omits alert trigger scope'
    grep_fixed 'Do not paste the GitHub token into G2ray' "$WORKER_README" \
        || fail 'Worker README does not mirror the token handling warning'
    grep_fixed 'read -rsp "Wake secret: " WAKE_SECRET' "$README" \
        || fail 'README still encourages typing the wake secret directly into curl commands'
    grep_fixed 'read -rsp "Wake secret: " WAKE_SECRET' "$WORKER_README" \
        || fail 'Worker README still encourages typing the wake secret directly into curl commands'
    grep_fixed 'keeps the wake secret out of shell history' "$README" \
        || fail 'README does not explain safer wake secret CLI handling'
    grep_fixed 'https://github.com/settings/tokens/new?scopes=codespace' "$README" \
        || fail 'README does not give a direct GitHub token creation path'
    grep_fixed 'CODESPACE_NAME`: **Plaintext** variable' "$README" \
        || fail 'README does not clarify CODESPACE_NAME as a plaintext Cloudflare variable'
    grep_fixed 'GITHUB_TOKEN`: **Secret** variable' "$README" \
        || fail 'README does not clarify GITHUB_TOKEN as a Cloudflare secret'
    grep_fixed 'CODESPACE_PORT`: **Plaintext** variable only if you changed `XRAY_PORT`' "$README" \
        || fail 'README does not document the optional CODESPACE_PORT Worker binding'
    grep_fixed 'route_ready: true' "$README" \
        || fail 'README does not explain successful Worker route readiness'
    grep_fixed 'route_ready: false' "$README" \
        || fail 'README does not explain Worker route settling failures'
    grep_fixed 'with or without `https://`, and with or without `/wake`' "$README" \
        || fail 'README does not clarify accepted Worker URL formats'
    grep_fixed 'CODESPACE_NAME` as a **Plaintext** variable' "$WORKER_README" \
        || fail 'Worker README does not clarify CODESPACE_NAME dashboard binding type'
    grep_fixed 'CODESPACE_PORT` as a **Plaintext** variable only if you changed' "$WORKER_README" \
        || fail 'Worker README does not document the optional CODESPACE_PORT binding'
    grep_fixed 'GITHUB_TOKEN` and `WAKE_SECRET` as **Secret** variables' "$WORKER_README" \
        || fail 'Worker README does not clarify Worker secret binding types'
    grep_fixed 'route_ready: false` with HTTP `404`' "$WORKER_README" \
        || fail 'Worker README does not explain the route-settling response'
    grep_fixed 'VS Code Desktop' "$README" \
        || fail 'README does not mention VS Code Desktop fallback for slow browser Codespaces'
    pass 'docs cover panel waker setup'
}

test_background_supervisor_ownership_is_strict() {
    grep_fixed 'background_supervisor_token_current()' "$SCRIPT" \
        || fail 'background supervisor loop does not verify its token remains current'
    grep_fixed 'write_background_supervisor_heartbeat()' "$SCRIPT" \
        || fail 'background supervisor heartbeat does not carry ownership data'
    grep_fixed 'background_supervisor_heartbeat_matches()' "$SCRIPT" \
        || fail 'fresh heartbeat cannot prove supervisor ownership when proc env is unavailable'
    grep_fixed 'printf '\''%s %s %s\n'\'' "${BASHPID:-$$}" "${G2RAY_BG_TASK_TOKEN:-}" "$now"' "$SCRIPT" \
        || fail 'heartbeat does not persist pid token and timestamp together'
    awk '
        /background_supervisor_status\(\)/ { in_fn=1 }
        in_fn && /background_supervisor_heartbeat_timestamp/ { saw_timestamp=1 }
        in_fn && /^}/ { exit }
        END { exit saw_timestamp ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'background supervisor status still cannot read structured heartbeat timestamps'
    grep_fixed 'supervisor_superseded' "$SCRIPT" \
        || fail 'superseded background supervisors do not self-exit'
    if grep_fixed 'legacy_bg_tasks_running "$p" || background_supervisor_heartbeat_running "$p"' "$SCRIPT"; then
        fail 'supervisor lifecycle still trusts legacy/heartbeat ownership for reuse or kill decisions'
    fi
    pass 'background supervisor ownership is strict'
}

test_exports_filter_unusable_fallback_routes() {
    grep_fixed 'usable_fallback_ips()' "$SCRIPT" \
        || fail 'fallback exports cannot filter unusable route IPs'
    grep_fixed 'xhttp_probe_metrics external "$ip"' "$SCRIPT" \
        || fail 'fallback export filtering does not probe each IP route'
    grep_fixed 'xhttp_status_usable "$ip_probe"' "$SCRIPT" \
        || fail 'fallback export filtering does not require usable XHTTP status'
    grep_fixed 'done < <(usable_fallback_ips)' "$SCRIPT" \
        || fail 'generate_ip_links still exports raw fallback candidates'
    grep_fixed 'address=$(usable_fallback_ips | head -1 || true)' "$SCRIPT" \
        || fail 'recommended IP link does not prefer a usable fallback route'
    pass 'fallback exports filter unusable route IPs'
}

test_runtime_ready_rejects_started_but_unusable_route() {
    awk '
        /ensure_runtime_ready\(\)/ { in_fn=1 }
        in_fn && /started_route_unusable/ { saw_started_unusable=1 }
        saw_started_unusable && /started_route_ready/ { saw_ready=1 }
        saw_started_unusable && /started_route_still_unusable/ { saw_still_bad=1 }
        saw_started_unusable && /return 1/ { saw_failure=1 }
        in_fn && /^}/ { exit }
        END { exit (saw_started_unusable && saw_ready && saw_still_bad && saw_failure) ? 0 : 1 }
    ' "$SCRIPT" \
        || fail 'ensure_runtime_ready can still return success after a newly-started engine has an unusable XHTTP route'
    pass 'runtime readiness rejects newly-started unusable XHTTP routes'
}

test_runtime_files_are_private_and_tempfiles_are_unique() {
    grep_fixed 'umask 077' "$SCRIPT" \
        || fail 'runtime files are not created with a private umask'
    grep_fixed 'DATA_DIR="${G2RAY_DATA_DIR:-$BASE_DIR/data}"' "$SCRIPT" \
        || fail 'data dir cannot be redirected for hermetic behavior tests'
    grep_fixed 'LOG_DIR="${G2RAY_LOG_DIR:-$BASE_DIR/logs}"' "$SCRIPT" \
        || fail 'log dir cannot be redirected for hermetic behavior tests'
    grep_fixed 'chmod 600 "$UUID_FILE" "$CONFIG_FILE"' "$SCRIPT" \
        || fail 'generated UUID/config files are not explicitly chmod 600'
    if grep_fixed 'local tmp="/tmp/g2ray_remote.sh"' "$SCRIPT"; then
        fail 'self-update still uses a predictable /tmp path'
    fi
    if grep_fixed '> /tmp/g2ray_msg_tmp.txt' "$SCRIPT"; then
        fail 'remote message fetch still uses a predictable /tmp path'
    fi
    if grep_fixed '> /tmp/gas_resp.txt' "$SCRIPT"; then
        fail 'donation response still uses a predictable /tmp path'
    fi
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_remote.XXXXXX"' "$SCRIPT" \
        || fail 'self-update does not stage downloads through mktemp'
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_msg.XXXXXX"' "$SCRIPT" \
        || fail 'remote message fetch does not stage through mktemp'
    grep_fixed 'mktemp "${TMPDIR:-/tmp}/g2ray_donate.XXXXXX"' "$SCRIPT" \
        || fail 'donation response does not stage through mktemp'
    pass 'runtime files are private and tempfiles are unique'
}

test_logs_are_bounded_and_quota_is_cycle_aware() {
    grep_fixed 'rotate_log_file()' "$SCRIPT" \
        || fail 'script has no log rotation helper'
    grep_fixed 'G2RAY_LOG_MAX_BYTES' "$SCRIPT" \
        || fail 'app log cap is not configurable'
    grep_fixed 'rotate_log_file "$LOG_FILE"' "$SCRIPT" \
        || fail 'g2ray app log is not capped'
    grep_fixed 'rotate_log_file "$LOG_DIR/xray-error.log"' "$SCRIPT" \
        || fail 'xray error log is not capped'
    grep_fixed 'QUOTA_CYCLE_FILE=' "$SCRIPT" \
        || fail 'quota estimate has no persisted billing cycle marker'
    grep_fixed 'reset_monthly_quota_if_needed()' "$SCRIPT" \
        || fail 'quota estimate is not monthly-cycle aware'
    grep_fixed 'G2RAY_QUOTA_SECONDS' "$SCRIPT" \
        || fail 'quota seconds are not configurable'
    grep_fixed 'Local 2-core quota estimate' "$SCRIPT" \
        || fail 'quota panel does not label itself as a local estimate'
    grep_fixed 'storage quota, not traffic quota' "$README" \
        || fail 'README does not distinguish GitHub storage quota from VPN traffic'
    pass 'logs are bounded and quota estimate is cycle aware'
}

test_fallback_link_count_is_capped() {
    grep_fixed 'MAX_FALLBACK_LINKS=' "$SCRIPT" \
        || fail 'fallback link cap is not configurable'
    grep_fixed '(( index > max_links )) && break' "$SCRIPT" \
        || fail 'fallback link generation does not cap weak extra routes'
    grep_fixed 'G2RAY_MAX_FALLBACK_LINKS' "$README" \
        || fail 'README does not document the fallback link cap'
    pass 'fallback link count is capped and documented'
}

test_ci_runs_static_regressions() {
    [[ -f "$CI_WORKFLOW" ]] || fail 'static test GitHub Actions workflow is missing'
    grep_fixed 'bash -n ./g2ray.sh' "$CI_WORKFLOW" \
        || fail 'CI workflow does not syntax-check g2ray.sh'
    grep_fixed 'bash ./tests/g2ray_static_tests.sh' "$CI_WORKFLOW" \
        || fail 'CI workflow does not run the static regression suite'
    grep_fixed 'bash ./tests/g2ray_behavior_tests.sh' "$CI_WORKFLOW" \
        || fail 'CI workflow does not run the behavior regression suite'
    grep_fixed 'node ./tests/worker_behavior_tests.mjs' "$CI_WORKFLOW" \
        || fail 'CI workflow does not run the Worker behavior suite'
    grep_fixed 'LC_ALL: C.UTF-8' "$CI_WORKFLOW" \
        || fail 'CI workflow does not pin a UTF-8 locale for README/static text checks'
    pass 'CI runs shell syntax, static regressions, panel behavior, and Worker behavior regressions'
}

test_xhttp_route_settling_is_observable() {
    grep_fixed 'BG_TASKS_VERSION_FILE=' "$SCRIPT" \
        || fail 'background supervisor does not record a script version marker'
    grep_fixed 'background_supervisor_version()' "$SCRIPT" \
        || fail 'script cannot fingerprint the active background supervisor version'
    grep_fixed 'stop_background_tasks()' "$SCRIPT" \
        || fail 'script cannot stop stale background supervisors after updates'
    grep_fixed 'background_supervisor_version_matches' "$SCRIPT" \
        || fail 'start_background_tasks reuses stale supervisors after script updates'
    grep_fixed 'xhttp_probe_status()' "$SCRIPT" \
        || fail 'script does not provide a dedicated XHTTP edge probe'
    grep_fixed 'xhttp_status_usable()' "$SCRIPT" \
        || fail 'script does not classify XHTTP probe status codes'
    grep_fixed '[[ "$code" == "200" || "$code" == "400" ]]' "$SCRIPT" \
        || fail 'HTTP 404 is still treated as a usable XHTTP route'
    grep_fixed 'xhttp_route_usable=' "$SCRIPT" \
        || fail 'health/reconnect logs do not expose XHTTP route usability'
    grep_fixed 'repair_codespace_port_route()' "$SCRIPT" \
        || fail 'script has no repair path for stale Codespaces port routing'
    grep_fixed 'route_unusable' "$SCRIPT" \
        || fail 'watchdog does not distinguish unusable XHTTP routing from a dead edge'
    grep_fixed 'XHTTP Probes' "$SCRIPT" \
        || fail 'diagnostics do not show local/external XHTTP probe results'
    grep_fixed 'Config    :' "$SCRIPT" \
        || fail 'diagnostics do not show XHTTP config path/mode/network summary'
    pass 'XHTTP route settling is observable and stale supervisors are replaced'
}

test_docs_and_public_configs_are_consistent() {
    grep_fixed '1-to-17' "$README" \
        || fail 'README menu count is stale'
    if grep_fixed 'did now get shown' "$README"; then
        fail 'README still contains the "did now" typo'
    fi
    grep_fixed 'G2RAY_QR_MODE' "$README" \
        || fail 'README does not document G2RAY_QR_MODE'
    grep_fixed 'high-resolution QR PNG files under `data/qr/`' "$README" \
        || fail 'README does not document the scan-friendly QR PNG export'
    grep_fixed 'G2RAY_EXTRA_FALLBACK_IPS' "$README" \
        || fail 'README does not document G2RAY_EXTRA_FALLBACK_IPS'
    grep_fixed 'G2RAY_ROUTE_WAIT_SEC' "$README" \
        || fail 'README does not document startup route wait'
    grep_fixed 'configs-to-copy-for-mobile.txt' "$README" \
        || fail 'README does not document the mobile copy-link fallback for QR scan failures'
    grep_fixed 'Choose Your Codespace Region Before Creating It' "$README" \
        || fail 'README does not tell users to choose a region before creating a Codespace'
    grep_fixed 'You cannot move an existing Codespace to another region' "$README" \
        || fail 'README does not explain that region changes require a new Codespace'
    grep_fixed 'gh codespace create -R OWNER/REPO -l WestEurope --idle-timeout 240m' "$README" \
        || fail 'README does not include a CLI example for region selection'
    grep_fixed 'Linux recovery after Worker wake' "$README" \
        || fail 'README does not include Linux recovery troubleshooting after Worker wake'
    grep_fixed 'gh codespace ports visibility 443:public -c "$CS"' "$README" \
        || fail 'README Linux recovery flow does not include public port repair'
    grep_fixed 'curl -sS -o /dev/null -w "route=%{http_code} time=%{time_total}s\n" -X OPTIONS "$APP"' "$README" \
        || fail 'README Linux recovery flow does not include an external route probe'
    grep_fixed '12) Server Location' "$README" \
        || fail 'README does not tell users to verify the observed exit location'
    grep_fixed 'Community Donated Configs (SUB)</summary>' "$README" \
        || fail 'README community subscription summary is not wrapped in a details block'
    if grep_fixed 'without impacting your own speed or exposing personal data' "$README"; then
        fail 'README still claims donated live configs expose no personal data'
    fi
    if grep_fixed 'No impact on your speed, quota, or security' "$SCRIPT" || grep_fixed 'no extra risk' "$SCRIPT"; then
        fail 'CLI donation prompt still understates the live-config sharing tradeoff'
    fi
    grep_fixed 'shares the live VLESS link' "$README" \
        || fail 'README does not disclose what donation shares'
    grep_fixed 'This shares your live VLESS link publicly.' "$SCRIPT" \
        || fail 'CLI donation prompt does not disclose that it shares the live VLESS link'
    grep_fixed 'allowInsecure=1' "$README" \
        || fail 'README does not disclose the TLS verification tradeoff in exported links'
    awk 'NF && seen[$0]++ { dup=1 } END { exit dup ? 1 : 0 }' "$CONFIGS" \
        || fail 'configs.txt contains duplicate non-empty VLESS entries'
    pass 'docs and public configs are consistent'
}

test_devcontainer_tooling_is_not_duplicated() {
    grep_fixed 'dnsutils' "$ROOT_DIR/.devcontainer/Dockerfile" \
        || fail 'Dockerfile does not install dnsutils for dig-based DNS resolution'
    if grep_fixed 'vnstat' "$ROOT_DIR/.devcontainer/Dockerfile"; then
        fail 'Dockerfile still installs unused vnstat'
    fi
    if grep_fixed 'cli.github.com/packages' "$ROOT_DIR/.devcontainer/Dockerfile"; then
        fail 'Dockerfile still installs gh manually despite the devcontainer feature'
    fi
    grep_fixed 'ghcr.io/devcontainers/features/github-cli:1' "$ROOT_DIR/.devcontainer/devcontainer.json" \
        || fail 'devcontainer no longer installs gh through the github-cli feature'
    grep_fixed '.devcontainer/Dockerfile text eol=lf' "$ROOT_DIR/.gitattributes" \
        || fail 'Dockerfile line endings are not pinned to LF'
    grep_fixed 'assets/message.txt text eol=lf' "$ROOT_DIR/.gitattributes" \
        || fail 'message.txt line endings are not pinned to LF'
    pass 'devcontainer tooling and LF policy are clean'
}

test_menu_loop_and_link_output_are_tidy() {
    if grep_fixed '( fetch_remote_message >/dev/null 2>&1 & )' "$SCRIPT"; then
        fail 'menu loop still starts a redundant remote-message fetch every render'
    fi
    if awk '
        /generate_ip_links\(\)/ { in_fn=1 }
        in_fn && /generate_ordered_links\(\)/ { exit }
        in_fn && /generate_link_for_address "\$address" "-ip\$\{index\}"/ { saw_link=1; next }
        in_fn && saw_link && /printf '\''\\n'\''/ { bad=1; exit }
        in_fn && saw_link && /printed=true/ { saw_link=0 }
        END { exit bad ? 0 : 1 }
    ' "$SCRIPT"; then
        fail 'generate_ip_links still appends an unconditional blank line after each link'
    fi
    grep_fixed 'frames=("-" "\\" "|" "/")' "$SCRIPT" \
        || fail 'wait_for_port does not provide animated progress frames'
    grep_fixed 'Initializing engine... (${i}s)' "$SCRIPT" \
        || fail 'wait_for_port does not show elapsed initialization time'
    grep_fixed 'Toggle Anti-Sleep Mode ($(echo -e "$_KA_LABEL"))' "$SCRIPT" \
        || fail 'anti-sleep toggle menu item does not show the current state inline'
    pass 'menu loop and link output are tidy'
}

test_donation_failures_are_not_suppressed() {
    grep_fixed 'return 0' "$SCRIPT" \
        || fail 'donation sender does not return success explicitly'
    grep_fixed 'return 1' "$SCRIPT" \
        || fail 'donation sender does not return failure explicitly'
    grep_fixed 'send_to_vless_forwarder "$vless" && touch' "$SCRIPT" \
        || fail 'manual donation marks config as prompted even when sending fails'
    grep_fixed 'send_to_vless_forwarder "$_VLESS_PRIMARY" && touch "$_PFLAG"' "$SCRIPT" \
        || fail 'first-view donation prompt is suppressed even when sending fails'
    if grep_fixed 'send_to_vless_forwarder "$_VLESS_PRIMARY"; sleep 1; }' "$SCRIPT"; then
        fail 'first-view donation still ignores send_to_vless_forwarder failure'
    fi
    pass 'donation failures are not suppressed'
}

test_wait_for_port_increment_is_set_e_safe
test_process_management_uses_pid_file
test_background_tasks_uses_owned_pid_file
test_background_tasks_require_config
test_port_visibility_failures_are_handled
test_self_update_is_opt_in
test_exit_trap_preserves_failures
test_generated_files_are_ignored
test_shell_files_are_lf_normalized
test_panel_script_is_executable
test_xray_version_can_be_pinned
test_generated_config_uses_resilient_dns_fallback
test_generated_links_include_domain_and_ip_variants
test_terminal_branding_is_customized_red
test_runtime_diagnostics_logging
test_xhttp_route_settling_is_observable
test_runtime_control_paths_are_hardened
test_startup_does_not_reconnect_healthy_runtime
test_self_heal_uses_reconnect_backoff
test_probe_and_gh_commands_are_bounded
test_diagnostics_show_latency_and_supervisor_state
test_diagnostics_show_self_heal_state
test_diagnostics_show_last_known_state
test_diagnostics_show_resume_gap_state
test_local_reopen_helper_is_documented
test_cloudflare_worker_waker_is_safe_to_publish
test_worker_dashboard_and_history_features
test_worker_wake_edge_cases_are_hardened
test_worker_rate_limits_and_classifies_github_errors
test_route_candidate_monitor_is_bounded
test_route_candidate_manager_and_live_monitor_are_present
test_first_run_recovery_card_is_present
test_soft_recovery_and_route_memory_are_present
test_route_export_and_reconnect_edges_are_hardened
test_panel_guides_cloudflare_waker_setup
test_diagnostics_show_external_waker_state
test_docs_cover_panel_waker_setup
test_background_supervisor_ownership_is_strict
test_exports_filter_unusable_fallback_routes
test_runtime_ready_rejects_started_but_unusable_route
test_runtime_files_are_private_and_tempfiles_are_unique
test_logs_are_bounded_and_quota_is_cycle_aware
test_fallback_link_count_is_capped
test_ci_runs_static_regressions
test_docs_and_public_configs_are_consistent
test_devcontainer_tooling_is_not_duplicated
test_menu_loop_and_link_output_are_tidy
test_donation_failures_are_not_suppressed
