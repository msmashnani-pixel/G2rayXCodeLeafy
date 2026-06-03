<div align="center">

# G2rayXCodeLeafy

A sleek VLESS proxy manager for GitHub Codespaces.

[![Version](https://img.shields.io/badge/version-1.4.3-2DC94E?style=flat-square)](https://github.com/shayanay80atomic/G2rayXCodeLeafy)
[![License](https://img.shields.io/badge/license-MIT-2DC94E?style=flat-square)](https://github.com/shayanay80atomic/G2rayXCodeLeafy)
[![Status](https://img.shields.io/badge/status-stable-2DC94E?style=flat-square)]()

</div>

---

> **Educational use only:** This project is provided for educational and research purposes. Use it only in ways that comply with applicable laws, GitHub Codespaces policies, network rules, and any services you connect to. You are responsible for your own usage.

---

<div align="center">

<!-- 🎬 Quick Start Tutorial Video -->
https://github.com/user-attachments/assets/79174a4a-ef86-4c1d-9f1a-909d0b29a248

<br>

<!-- 📸 Panel Preview Image -->
<img src="assets/preview.png" alt="G2ray Panel Preview" width="720" style="border-radius: 12px; border: 1px solid rgba(0,0,0,0.05);">

</div>

<br>

## Overview

G2ray is a powerful, interactive Bash panel designed to instantly deploy and manage Xray VLESS XHTTP configurations. Built specifically for the GitHub Codespaces environment, it automates port management, traffic monitoring, and connection keep-alives natively.

> **Note:** The panel includes a best-effort anti-sleep engine using Tmux while the Codespace is running. It cannot bypass GitHub quota limits, manual stops, or automatic deletion of stopped Codespaces.

---

<details><summary><kbd>🔗</kbd> Community Donated Configs (SUB)</summary>

Want to use public nodes donated by other G2ray users? Import this raw newline-separated list into clients that support plain VLESS subscriptions:

```text
https://raw.githubusercontent.com/shayanay80atomic/G2rayXCodeLeafy/main/configs.txt
```

</details>

---

### Core Features

#### ⚡ One-Click Deploy & Manage
Generate and start Xray engines in seconds. The beautiful menu-driven CLI interface makes managing nodes and viewing live config links effortless. 

#### 🔄 Smart Auto-Keepalive
Built-in background loops and Tmux keepalives reduce idle shutdowns while the Codespace is active. If GitHub stops, blocks, or deletes the Codespace, reopen it from GitHub Codespaces; the panel will auto-start and self-heal after the container starts again.

#### 📡 Live Analytics & Quota
Tracks real-time RX/TX traffic and resource usage (CPU/RAM). The quota panel is a local 2-core wall-clock estimate that resets by month; GitHub billing remains authoritative. GitHub's 15 GB-month allowance is storage quota, not traffic quota.

#### 📦 Community Config Network
Donate your generated config directly from the CLI to share access with the community. Donation shares the live VLESS link, including its UUID, Codespaces endpoint, and link label, so only donate configs you intentionally want public.

<div align="center">

| 🛠️ Configuration Optimizer |
| :--- |
| To finalize your setup, take the config received from the panel and visit **[NetLeafy](https://code-leafy.github.io/NetLeafy)**. Set the server mode to **G2ray** and paste your link to generate a fully optimized connection. |

</div>

---


## Getting Started

1. **Fork the Repository**  
   → Click **Fork** at the top-right of this page

2. **Choose Your Codespace Region Before Creating It**
   → GitHub profile picture → **Settings** → **Codespaces** → **Region** → choose **Set manually** and pick the region you want. This decides the likely exit IP/country for new configs. You cannot move an existing Codespace to another region; create a new Codespace after changing this setting.

   Common GitHub CLI region names include `WestEurope`, `EastUs`, `WestUs2`, and `SouthEastAsia`. For example:

   ```bash
   gh codespace create -R OWNER/REPO -l WestEurope --idle-timeout 240m
   ```

   After setup, use option `12) Server Location` in the panel to confirm the observed exit IP/country.

3. **Create a Codespace**
   → Open your fork → Click **Code** → **Codespaces** tab → **Create codespace on main**

4. **Wait for Environment**
   → Allow 2-3 minutes for the container to build

5. **Launch Panel**
   → The G2ray CLI panel auto-starts in the terminal. On a fresh Codespace, choose `1) Generate Config & Start`; after config generation, the panel can guide Worker setup, show a recovery card, and open diagnostics.

If browser Codespaces stays on a loading screen for a long time, open the same Codespace in **VS Code Desktop** from the GitHub Codespaces page. The panel runs the same way there and is often faster on slow browser sessions.

<details>
<summary><kbd>⚙️</kbd> Environment Configuration</summary>

While G2ray is designed to be zero-config, advanced users can modify specific variables within the engine script:

- `XRAY_PORT` **(Optional)** — Binds Xray to a custom port. Default: `443`
- `CODESPACE_NAME` **(Optional)** — Overrides auto-detection of the app domain.
- `G2RAY_QR_MODE` **(Optional)** — Controls QR display in the config view: `recommended` (default), `all`, or `none`.
- `G2RAY_EXTRA_FALLBACK_IPS` **(Optional)** — Adds comma-, semicolon-, or space-separated IP fallback candidates before auto-detected ones.
- `G2RAY_DEFAULT_FALLBACK_IPS` **(Optional)** — Replaces the built-in fallback IP candidate list.
- `G2RAY_MAX_FALLBACK_LINKS` **(Optional)** — Caps exported usable IP fallback links. Default: `20`.
- `G2RAY_ROUTE_MONITOR_MAX_CANDIDATES` **(Optional)** — Caps cached candidate route probes shown in diagnostics. Default: `24`, hard-capped at `32`.
- `G2RAY_DIAGNOSTIC_MAX_FALLBACK_PROBES` **(Optional)** — Caps live fallback route probes in option `14) Diagnostics`. Default: `12`.
- `G2RAY_ROUTE_HEALTH_TTL_SEC` **(Optional)** — Seconds cached route health can be reused to order exported configs before refreshing. Default: `300`.
- `G2RAY_ROUTE_PROBE_CONCURRENCY` **(Optional)** — Maximum parallel route candidate probes during a route-health refresh. Default: `4`, hard-capped at `8`.
- `G2RAY_ROUTE_FAILURE_COOLDOWN_SEC` **(Optional)** — Seconds to temporarily skip candidates that timed out or returned edge/origin errors. Default: `180`.
- `G2RAY_PERFORMANCE_PROFILE` **(Optional)** — Config profile used when generating a new Xray config: `balanced` (default), `low_latency`, `streaming`, `unstable_mobile`, or `low_overhead`.
- `G2RAY_LOW_OVERHEAD=1` **(Optional)** — Starts the panel in low-overhead mode, reducing INFO logs and less-essential background route/export refreshes. You can also toggle this from option `18`.
- `G2RAY_PORT_PUBLIC_TTL_SEC` **(Optional)** — Seconds to trust the last successful `gh codespace ports visibility 443:public` call before calling GitHub again. Default: `300`.
- `G2RAY_WAKER_TEST_TIMEOUT_SEC` **(Optional)** — Seconds the panel waits when testing the Cloudflare Worker from option `15) Recovery / Waker Setup`. Default: `180`.
- `G2RAY_EDGE_RECONNECT_THRESHOLD` **(Optional)** — Number of consecutive unreachable edge checks before self-heal may run a full reconnect. Default: `3`.
- `G2RAY_RECONNECT_COOLDOWN_SEC` **(Optional)** — Minimum seconds between automatic full reconnects. Default: `300`.
- `G2RAY_ROUTE_WAIT_SEC` **(Optional)** — Maximum seconds startup waits for the `app.github.dev` XHTTP route after a Codespace resume. Default: `120`.
- `G2RAY_FORCE_RECONNECT_ROUTE_WAIT_SEC` **(Optional)** — Maximum seconds the repair step waits for the `app.github.dev` route after toggling port visibility. Default: `60`.
- `G2RAY_GH_TIMEOUT_SEC` **(Optional)** — Maximum seconds for GitHub CLI control-plane calls. Default: `10`.
- `G2RAY_LOG_MAX_BYTES` **(Optional)** — Maximum bytes per runtime log before rotation. Default: `1048576`.
- `G2RAY_LOG_ROTATE_KEEP` **(Optional)** — Number of rotated log files to keep. Default: `3`.
- `G2RAY_QUOTA_SECONDS` **(Optional)** — Local monthly quota estimate in seconds. Default: `216000` (60 wall-clock hours on a 2-core Codespace).

Generated links use `insecure=0&allowInsecure=0` by default so clients keep TLS certificate verification enabled. If a specific client cannot handle IP fallback links with SNI/Host routing, `allowInsecure=1` can be tried manually as a compatibility workaround, but that relaxes certificate verification and is not the default.

By default the panel can export up to 20 usable IP fallback configs plus the domain config, ordered by rolling route health: success ratio, average successful XHTTP latency, recent weighted latency, latest XHTTP latency, and temporary cooldowns for candidates that timed out. These numbers are `OPTIONS` probes against the Codespaces XHTTP route, not ICMP ping or full throughput tests. If GitHub/DNS exposes fewer healthy unique edge routes, the panel exports fewer rather than duplicating weak or unusable routes.

The panel saves high-resolution QR PNG files under `data/qr/` for the displayed configs. If a phone QR scanner struggles with the terminal QR preview, open the PNG in VS Code/browser, import the copy-ready link from the panel output, or use `configs-to-copy-for-mobile.txt`. Terminal zoom, font rendering, and dark themes can make dense QR codes harder to scan.

</details>

---

## Usage

When launched, the panel provides a 1-to-17 numerical selection menu. Simply type the number corresponding to the action you want to take.

```bash
# If panel did not get shown:
bash ./g2ray.sh
```

### Safer Reproducible Settings

- Set `G2RAY_AUTO_UPDATE=1` only when you want the panel to replace `g2ray.sh` from upstream on startup. It is disabled by default.
- Override the devcontainer build argument `XRAY_VERSION` to change the pinned Xray-core version. Default: `v26.5.9`.

### Codespace Recovery

GitHub can still stop a Codespace for idle timeout, quota, billing, manual stop, rebuild, or retention policy. No process inside the Codespace can restart it after that because all Codespace processes are stopped. To reduce surprise stops, set your GitHub Codespaces **Default idle timeout** to **240 minutes** in GitHub account settings.

Before you get close to monthly quota exhaustion, also mark the Codespace as **Keep codespace** from the GitHub Codespaces page. GitHub quota exhaustion does not immediately mean deletion, but stopped Codespaces can still be removed by retention policy. The same VLESS configs survive into the next monthly reset only if the same Codespace name/domain survives.

To change the idle timeout:

1. Open GitHub in your browser.
2. Click your profile picture in the top-right corner.
3. Open **Settings**.
4. In the left sidebar, open **Codespaces**.
5. Find **Default idle timeout**.
6. Set it to **240 minutes**.
7. Save the setting.

For quick manual recovery from Windows, this repo includes `scripts/reopen-codespace.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\reopen-codespace.ps1 -Repo OWNER/REPO
```

If GitHub CLI says the `codespace` scope is missing, run:

```powershell
gh auth refresh -h github.com -s codespace
```

The helper uses GitHub's Codespaces start API, waits until the Codespace is available, and opens it in VS Code. If GitHub returns `HTTP 402`, the Codespace is quota or billing blocked and must wait for quota reset or a billing setting change.

Linux recovery after Worker wake:

```bash
CS="YOUR_CODESPACE_NAME"
REPO="OWNER/REPO"
APP="https://${CS}-443.app.github.dev/"

gh auth refresh -h github.com -s codespace
gh codespace view -c "$CS" --json name,state,lastUsedAt,idleTimeoutMinutes --jq '{name,state,lastUsedAt,idleTimeoutMinutes}'
gh codespace ports -c "$CS"
gh codespace ports visibility 443:public -c "$CS"
curl -sS -o /dev/null -w "route=%{http_code} time=%{time_total}s\n" -X OPTIONS "$APP"
```

If the route prints `000` or DNS errors after GitHub says the Codespace is active, open the Codespace once and run panel option `14) Diagnostics`. If XHTTP is `404` or unusable, use option `6) Recover Now`. Recover Now first tries a soft, idempotent repair: verify/start Xray, reassert port visibility, wait for the route, repair visibility once, refresh route candidates, and refresh exported configs. It offers a hard restart only if the route still looks stuck.

Headless recovery/status commands:

```bash
bash ./g2ray.sh --recover-now
bash ./g2ray.sh --recover-now --json
bash ./g2ray.sh --doctor-json
bash ./g2ray.sh --support-bundle
bash ./g2ray.sh --print-subscription-url
```

`--recover-now` is non-interactive and soft-only: it verifies/starts Xray, reasserts public port visibility, waits for route readiness, refreshes route candidates, and refreshes exported configs. If the route is still settling, it can exit nonzero; open the interactive panel and use option `6) Recover Now` if you want the hard restart prompt.

`--recover-now --json` runs the same soft recovery path but prints a machine-readable result with `status`, `route_ready`, `edge_probe`, and `next_action` fields. It is for automation already running inside the Codespace after the Codespace has been started or attached. External VPS automation cannot run this command inside a stopped Codespace; use the Cloudflare Worker wake endpoint or GitHub Codespaces API first, then use this command from inside the Codespace if local route recovery is still needed.

`--support-bundle` creates a redacted `.tar.gz` support bundle under `logs/`. It includes doctor JSON, diagnostics, structured event logs, route health, rolling route stats, route-settling history, and Xray logs while redacting VLESS links, UUIDs, bearer tokens, GitHub tokens, and wake secrets.

`--print-subscription-url` prints the raw-GitHub URL where `configs-subscription-base64.txt` would be available if you publish that export yourself. Generated config exports are ignored by default because they contain live VLESS credentials; the base64 subscription is encoding, not encryption. Most VLESS clients cannot authenticate to a private GitHub raw URL, so a subscription URL is directly usable only when the file is publicly reachable or served through a client-compatible private endpoint. Prefer local/private distribution; if you intentionally publish a public subscription, rotate the UUID afterward when you want to revoke access, and do not publish `configs-to-copy-for-mobile.txt` or `configs-meta.json`.

After `git pull`, reattach the panel or run:

```bash
bash ./g2ray.sh --silent-start
bash ./scripts/post-start.sh
```

`--silent-start` starts or replaces the background supervisor with the pulled script version, verifies runtime readiness, records `data/boot_status.json`, and refreshes exports without stopping a healthy Xray process. `scripts/post-start.sh` is what the devcontainer runs automatically; it wraps `--silent-start` and writes `logs/post-start.log` so a start from the Worker is easier to diagnose later.

Persistent logs are written to `logs/g2ray.log`, `logs/g2ray-events.jsonl`, and `logs/g2ray-diagnostics.log`. Diagnostics records a readable snapshot there, so you can send those logs later and still preserve route waits, repairs, probe results, supervisor state, last-good route, route-settling history, and export refreshes from previous hours.

Option `16) Live Monitor` is a foreground status screen for intentional terminal monitoring. It refreshes engine state, local/edge XHTTP probes, supervisor heartbeat, self-heal counters, route-settling history, best route candidates, and recent events without restarting Xray.

Option `17) Route Candidates` opens the Route Candidates manager. It shows measured route IPs with last latency, average latency, recent weighted latency, success ratio, source, and failure reason; lets you add a manual IPv4 candidate, pin a preferred route, blacklist a bad route, unblacklist/remove entries, reset measured route health without wiping preferences, explicitly reset all route preferences, and refresh exports. Use this only for specific edge IPs you have measured; it does not scan broad Azure/GitHub ranges.

Option `18) Toggle Low-Overhead Mode` reduces INFO-level app logging and slows less-essential background route/export refreshes while keeping heartbeat and self-heal checks alive. Use it when configs already work and you want less background noise during speed testing; turn it off when collecting diagnostics.

The config screen writes three local export helpers: `configs-to-copy-for-mobile.txt`, `configs-subscription-base64.txt`, and `configs-meta.json`. They are ignored by git by default because they include live connection credentials or metadata. Use them locally, or distribute them through a private channel you control. A raw-GitHub subscription URL is shown only as a convenience for publicly reachable subscriptions or advanced users who provide a client-compatible private endpoint; a public repo makes the subscription public.

On first setup, the panel shows a small recovery card so you can copy these recovery commands safely: `bash ./g2ray.sh --doctor-json`, `bash ./g2ray.sh --recover-now`, `bash ./g2ray.sh --recover-now --json`, `bash ./g2ray.sh --support-bundle`, and, when a Worker is configured, a curl template using `Authorization: Bearer <WAKE_SECRET>`. The raw wake secret is never printed from saved metadata.

### Cloudflare Worker Waker

If you want a phone/browser/curl-accessible manual wake button, this repo includes a Cloudflare Worker template in `worker/codespace-waker/`. The `GET /wake` page is public so it can load in your browser, but `POST /wake` and the `/api/*` actions are protected by your wake secret. The Worker stores the GitHub token and wake secret as Cloudflare secrets, not in git.

The Worker also provides a **Health dashboard** page for mobile use. The page itself can load in a browser, but wake, health, history, and copyable status actions require your wake secret. It shows GitHub state, XHTTP route readiness, route latency, idle timeout, last-used time, last failure, quota survival state, retention/deletion risk, copyable status text, route history summary, latency trend, and optional KV-backed history. This is external health only; it does not expose your UUID, VLESS links, or the panel's full option `14) Diagnostics` output.

The panel can guide this from **Option 15: Recovery / Waker Setup**. It detects the current Codespace name, generates a wake secret, reminds you to set Default idle timeout to 240 minutes, and saves only non-sensitive metadata such as the Worker URL and wake-secret fingerprint.

After the Worker starts the Codespace, it briefly probes the `app.github.dev` XHTTP route. If the response says `route_ready: true`, your existing VLESS configs should work again. If it says `route_ready: false` with HTTP `404`, GitHub has started the Codespace but the port route is still settling; wait 1-2 minutes and retry, or open the panel and use option `6) Recover Now`.

Do not paste the GitHub token into G2ray. Create the token in GitHub, save it privately, and enter it directly in Cloudflare as the `GITHUB_TOKEN` secret. The wake secret is shown once by the panel; save it privately and enter it directly in Cloudflare as the `WAKE_SECRET` secret.

Classic token path:

1. Open <https://github.com/settings/tokens/new?scopes=codespace>.
2. Give it a clear name, such as `G2ray Codespace Waker`.
3. Choose an expiration you can remember.
4. Keep only the `codespace` scope selected.
5. Generate the token and copy it once.

Cloudflare dashboard binding types:

- `CODESPACE_NAME`: **Plaintext** variable.
- `CODESPACE_PORT`: **Plaintext** variable only if you changed `XRAY_PORT`; omit it for the default `443`.
- `GITHUB_TOKEN`: **Secret** variable.
- `WAKE_SECRET`: **Secret** variable.

Optional Cloudflare dashboard bindings:

- `WAKER_KV`: KV namespace binding for dashboard history.
- `QUOTA_SURVIVAL_CRON_ENABLED`: **Plaintext** variable set to `true` only if you also configure a Cloudflare Cron Trigger and want conservative quota-reset checks.
- `DISCORD_WEBHOOK_URL`: **Secret** variable for Discord alerts.
- `TELEGRAM_BOT_TOKEN`: **Secret** variable for Telegram alerts.
- `TELEGRAM_CHAT_ID`: **Secret** variable for Telegram alerts.
- `WAKE_COOLDOWN_SECONDS`: **Plaintext** optional seconds to prevent repeated successful wake requests from spamming GitHub when KV is configured. Leave unset for no successful-wake cooldown. Any nonzero value below `60` is treated as `60` because Cloudflare KV expiration TTLs require at least 60 seconds.
- `ROUTE_POLL_AFTER_SECONDS`: **Plaintext** optional browser/API retry hint while the route is settling. Default: `5`.

With `WAKER_KV`, the Worker records quota-block incidents: first `HTTP 402`, latest `HTTP 402`, last successful wake/health check, and whether the same Codespace still appears accessible. It can also enforce optional `WAKE_COOLDOWN_SECONDS` after a successful wake. With `QUOTA_SURVIVAL_CRON_ENABLED=true`, a Cloudflare Cron Trigger can check this state conservatively; it does not bypass quota and does not try repeated starts until the estimated monthly reset window.

The Worker URL can be entered with or without `https://`, and with or without `/wake`; the panel normalizes it to `https://YOUR_WORKER.workers.dev/wake`.

Quick setup:

```bash
cd worker/codespace-waker
cp wrangler.toml.example wrangler.toml
# edit wrangler.toml and set CODESPACE_NAME
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put WAKE_SECRET
npx wrangler deploy
```

After deploy, copy the Worker URL that Wrangler prints, return to panel option `15) Recovery / Waker Setup`, answer that the Worker is deployed, paste the Worker URL, and run the panel's Worker test. This saves only non-sensitive Worker metadata locally so diagnostics and the recovery card can show the configured Worker.

Wake call:

```bash
read -rsp "Wake secret: " WAKE_SECRET; echo
curl -X POST -H "Authorization: Bearer ${WAKE_SECRET}" https://YOUR_WORKER.workers.dev/wake
unset WAKE_SECRET
```

PowerShell wake call:

```powershell
$wake = Read-Host -AsSecureString "Wake secret"
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($wake)
try {
  $plainWake = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  Invoke-RestMethod -Method Post -Headers @{Authorization="Bearer $plainWake"} -Uri "https://YOUR_WORKER.workers.dev/wake"
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
  Remove-Variable wake, ptr, plainWake -ErrorAction SilentlyContinue
}
```

The browser form is preferred because it keeps the wake secret out of shell history. See `worker/codespace-waker/README.md` for the full setup and token guidance.

If you create a new Codespace, change region, rename/recreate the Codespace, or change `XRAY_PORT`, update the Worker's `CODESPACE_NAME` and optional `CODESPACE_PORT` bindings, redeploy the Worker, then return to option `15` and save/test the Worker URL again.

---

## Architecture

```mermaid
graph LR
    A[GitHub Codespace] -->|Executes| B[G2ray Bash Panel]
    B -->|Configures| C[Xray-core]
    C -->|Binds Port 443| D[Codespace App Domain]
    D -->|VLESS over xHTTP| E[End User Client]
```

<details>
<summary><kbd>📁</kbd> Project Structure</summary>

```text
G2rayXCodeLeafy/
├── data/                    # Dynamic storage for usage stats, UUIDs, & config
├── logs/                    # Xray engine error logs
├── assets/                  # Media resources (previews & videos)
├── configs.txt              # Community donated subscription configs
└── g2ray.sh                 # The main interactive panel script
```

</details>

---

<details>
<summary><kbd>❓</kbd> FAQ & Troubleshooting</summary>

**My Codespace keeps shutting down?**
Ensure you have activated Option `7` in the G2ray panel (Toggle Anti-Sleep Mode) to spawn a background Tmux session that simulates activity while the Codespace is running. This is best-effort: GitHub may still stop the Codespace when quota, budget, idle-timeout policy, or retention/deletion rules apply.

**Will it restart after my monthly quota resets?**
Not by itself while GitHub is blocking or stopping the Codespace, because no code runs inside a stopped Codespace. The Worker can show `HTTP 402`, estimate the next monthly reset, and, if you enabled optional KV/Cron, check conservatively near reset. The same configs work next month only if the same Codespace survives, so mark it as **Keep codespace** before quota runs out. After the monthly included usage resets, reopen it from GitHub or the Worker; `postStartCommand` runs `scripts/post-start.sh`, which calls `g2ray.sh --silent-start`, starts Xray, starts the supervisor, records boot status, and refreshes exported configs.

**Is the 15 GB limit my VPN data limit?**
No. GitHub's 15 GB-month included allowance is Codespaces storage. The panel's RX/TX traffic counter measures tunnel traffic for your visibility, but it is not the same as the GitHub storage quota.

**Why are my speeds slow?**
Codespace region affects the likely exit IP/country and latency. Set the desired region before creating the Codespace, then confirm the real observed exit IP with option `12) Server Location`. GitHub/Azure region labels are not a perfect country guarantee, and changing the setting later does not move an existing Codespace.

</details>

<br>

<div align="center">

> **Educational Purpose Only:** This project is provided for educational and research purposes. Users are solely responsible for compliance with applicable laws, platform policies, and network rules. The maintainers assume no liability for misuse.

[MIT License](https://github.com/shayanay80atomic/G2rayXCodeLeafy/blob/main/LICENSE) · Based on the Code-Leafy project
</div>
