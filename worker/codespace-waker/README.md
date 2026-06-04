# G2ray Codespace Waker

Personal test and educational use only: this helper is provided for private recovery experiments and learning. Do not use it to publish generated configs or operate a public access service. Use it only in ways that comply with applicable laws, GitHub Codespaces policies, Cloudflare policies, and network rules.

This Cloudflare Worker gives you a manual wake page for one GitHub Codespace through GitHub's official Codespaces API. The `GET /wake` page is public so it can load in your browser, but `POST /wake` and the `/api/*` actions require your wake secret.

It does not expose VLESS configs, keep the Codespace alive forever, or bypass quota, billing, deletion, or account restrictions.

The browser page is a small mobile-friendly health dashboard. It has a large **Start Codespace** button, a **Check Health** action, route latency/status cards, copyable status text, a stop-polling button, a route history summary, a latency trend, and auto-refresh while the route is still settling.

After GitHub accepts the start request, the Worker waits for the Codespace state to become available, then probes the public `app.github.dev` XHTTP route. If the response says `route_ready: true`, the external route answered a usable XHTTP probe and the VLESS configs should usually be usable. If it says `route_ready: false`, follow the returned `next_action`; HTTP `404` usually means GitHub's port route is still settling, while HTTP `0` usually means DNS or the app route did not answer.

When the start request is accepted but the route is still settling, the API returns HTTP `202` with `ok: true`, `route_ready: false`, `retry_after_seconds`, `poll_after_seconds`, and a `Retry-After` header. The browser page keeps polling health until the route becomes ready or you stop checking.

## 1. Create a GitHub Token

Recommended path:

1. Open <https://github.com/settings/tokens/new?scopes=codespace>.
2. Give it a clear name, such as `G2ray Codespace Waker`.
3. Choose an expiration you can remember.
4. Keep only the `codespace` scope selected.
5. Generate the token and copy it once.

Token types:

- Classic personal access token with the `codespace` scope.
- Fine-grained token that can access the repo and has Codespaces lifecycle/admin write permission, if that option is available in your account.

Keep this token private. Do not commit it to git.

If you are using the G2ray panel, open **Option 15: Recovery / Waker Setup**. It will detect the Codespace name, generate a wake secret, and show these same steps inside the terminal.

Do not paste the GitHub token into G2ray. Put the token directly into Cloudflare as the `GITHUB_TOKEN` secret. The wake secret is shown once by the panel; save it privately and put it directly into Cloudflare as the `WAKE_SECRET` secret.

## 2. Configure Wrangler

Install the pinned local Wrangler package:

```bash
npm ci
npx --no-install wrangler --version
```

The Codespace devcontainer installs Node.js 22 for current Wrangler. If you deploy from another machine, use Node.js 22 or newer, run `npm ci`, and use the local `npx --no-install wrangler ...` commands below.

Copy the example config:

```bash
cd worker/codespace-waker
cp wrangler.toml.example wrangler.toml
```

Edit `wrangler.toml` and set:

```toml
CODESPACE_NAME = "your-codespace-name"
```

Example placeholder:

```toml
CODESPACE_NAME = "your-codespace-slug"
```

If you use the Cloudflare dashboard instead of Wrangler, add `CODESPACE_NAME` as a **Plaintext** variable.

Optional: add `CODESPACE_PORT` as a **Plaintext** variable only if you changed the panel's `XRAY_PORT`. Leave it unset for the default port `443`.

Optional history: create a Cloudflare KV namespace and bind it as `WAKER_KV`. Without this binding, the dashboard still works but shows history as disabled. With `WAKER_KV`, it stores recent wake/health events, route HTTP status, latency, route wait time, and last failures under a per-Codespace key so the dashboard can show repeated HTTP `404` settling and latency trends. Identical health polls are sampled with `HEALTH_HISTORY_SAMPLE_MS` (default 5 minutes) so the history stays readable. `WAKER_KV` is also recommended for public deployments because it enables failed wake-secret lockout and optional successful-wake cooldown. Cloudflare KV is eventually consistent, so this is a practical anti-spam guard rather than a strict atomic security boundary.

Quota survival history also uses `WAKER_KV`. When GitHub returns HTTP `402`, the Worker records the first quota block, latest quota block, estimated monthly reset, retention/deletion fields from GitHub, and the next later successful wake or health check. This helps confirm that the same Codespace survived into the next monthly reset.

Optional quota survival Cron: add a Cloudflare Cron Trigger only if you want automatic low-frequency checks while quota is blocked, then set `QUOTA_SURVIVAL_CRON_ENABLED=true` as a **Plaintext** variable. The Worker is disabled by default for scheduled events, checks at most about daily before reset, and only attempts a wake near the estimated monthly reset window.

Optional alerts:

- Add `DISCORD_WEBHOOK_URL` as a **Secret** variable to notify a Discord channel.
- Add `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` as **Secret** variables to notify Telegram.

Alerts are sent for wake attempts when a wake succeeds, when the route is ready, when the route remains stuck at HTTP `404`, and when GitHub rejects the token with `401` or `403`. Manual **Check Health** calls record history when KV is enabled; if history contains a previous stuck route, a later health check can send one route-ready transition alert when the route becomes usable. Repeated identical health checks are deduped or sampled instead of filling history with noise.

## 3. Add Secrets

Create a long random wake secret. Examples:

```bash
openssl rand -hex 32
```

PowerShell:

```powershell
[guid]::NewGuid().Guid + [guid]::NewGuid().Guid
```

Store secrets in Cloudflare:

```bash
npx --no-install wrangler secret put GITHUB_TOKEN
npx --no-install wrangler secret put WAKE_SECRET
```

Paste the GitHub token for `GITHUB_TOKEN`.
Paste your random wake secret for `WAKE_SECRET`.

In the Cloudflare dashboard, add both `GITHUB_TOKEN` and `WAKE_SECRET` as **Secret** variables, not plaintext variables.

## 4. Deploy

```bash
npm run deploy
```

Wrangler prints the Worker URL, for example:

```text
https://g2ray-codespace-waker.YOUR_SUBDOMAIN.workers.dev
```

The panel accepts the Worker URL with or without `https://`, and with or without `/wake`. It stores the normalized `/wake` URL.

If you are using the G2ray panel, return to **Option 15: Recovery / Waker Setup** after deploy, paste this Worker URL, and run the panel's Worker test. This saves only non-sensitive Worker metadata locally so diagnostics and the recovery card know which Worker is configured.

## 5. Start The Codespace Manually

Recommended CLI call:

```bash
read -rsp "Wake secret: " WAKE_SECRET; echo
curl -X POST \
  -H "Authorization: Bearer ${WAKE_SECRET}" \
  https://g2ray-codespace-waker.YOUR_SUBDOMAIN.workers.dev/wake
unset WAKE_SECRET
```

Opening the Worker URL in a browser and entering the wake secret in the form is preferred because it keeps the secret out of shell history.

If you create a new Codespace, change region, rename/recreate the Codespace, or change the panel's `XRAY_PORT`, update `CODESPACE_NAME` and optional `CODESPACE_PORT`, redeploy the Worker, then return to panel option `15` and save/test the Worker URL again.

For automation that only needs GitHub state and wants to avoid an external route probe, call `POST /api/health?route=false`. Normal browser health checks should use `/api/health` so the dashboard can report route readiness.

## Expected Responses

- `200` with `ok: true`: GitHub accepted or handled the start request.
- `route_ready: true`: the XHTTP route returned HTTP `200` or `400` during the Worker wait window, matching the panel's route-readiness classifier.
- `route_ready: false` with HTTP `404`: the Codespace started, but the GitHub route has not settled yet.
- `route_ready: false` with HTTP `0`: DNS, TLS, or the app route did not answer before the Worker timeout.
- `route_failure_reason`: machine-readable route reason such as `route_settling_404`, `timeout_or_unreachable`, `dns_tls_or_network_unreachable`, `edge_or_origin_error`, or `ready`.
- `retry_after_seconds` / `poll_after_seconds`: how long the browser or automation should wait before checking again.
- `next_action`: the fastest manual recovery step to try next.
- `next_action_code`: stable machine-readable action code such as `retry_vless_config`, `wait_route_or_recover`, `rotate_github_token`, `wait_github_rate_limit`, or `wait_for_quota_reset`.
- `quota_blocked: true`: GitHub returned HTTP `402`, so quota or billing is blocking the start.
- `quota_reset_estimate_utc`: a calendar-month reset estimate using the next first-of-month UTC. Verify the exact reset in GitHub Billing; GitHub billing data is authoritative.
- `retention_period_minutes` / `retention_expires_at`: GitHub Codespaces retention fields when the API returns them.
- `retention_risk`: `safe`, `warning`, `urgent`, or `unknown` based on `retention_expires_at`.
- `survival_next_action`: what to do to preserve the same Codespace/configs through quota reset.
- `notification_status: "none"`: no Discord/Telegram alert was needed, or no alert channel is configured.
- `notification_status: "deferred"` / `notifications_deferred: true`: Discord or Telegram delivery is running after the response through Cloudflare `waitUntil`; check Worker logs if an alert does not arrive.
- `notification_status: "failed"`: notification delivery was attempted synchronously and `notification_errors` contains the delivery error.
- `history_deferred: true`: KV history writes were queued through Cloudflare `waitUntil`, so the dashboard response did not wait for the history append. Quota incident state is recorded before the response when KV is available so quota-survival decisions are immediately visible.
- `401`: Wrong wake secret, or GitHub rejected the stored token. Check the JSON `error`, `reason`, or `token_warning` field to tell which side rejected the request.
- `402`: GitHub quota or billing blocked the start. If the option is available, mark the Codespace as **Keep codespace**, wait for quota reset or adjust GitHub billing settings, then start the same Codespace again. Org-owned or policy-managed Codespaces may have retention rules that override or hide this option.
- `403`: GitHub token was accepted but cannot access Codespaces, commonly because the `codespace` scope is missing. The response reason may be `github_token_scope_missing`.
- `404`: Codespace name is wrong or the token cannot access it.
- `429`: Too many wrong wake-secret attempts, optional successful-wake cooldown, or GitHub rate limiting. Check `reason`, `retry_after_seconds`, and any `github_rate_limit_*` fields.

Optional anti-spam setting: with `WAKER_KV` configured, set `WAKE_COOLDOWN_SECONDS` as a **Plaintext** variable if you want a successful wake to block repeated wake calls for a short period. Leave it unset to allow immediate manual retries. Any nonzero value below `60` is treated as `60` because Cloudflare KV expiration TTLs require at least 60 seconds. For strict abuse protection on a public endpoint, use Cloudflare's native rate limiting or a Durable Object gate in addition to KV.

## Security Notes

- Do not put `GITHUB_TOKEN` or `WAKE_SECRET` in `wrangler.toml`.
- Do not commit `.dev.vars*`, `.env`, or `.env.*`.
- Prefer the `Authorization: Bearer ...` header over putting secrets in URLs.
- Rotate the GitHub token if the Worker or Cloudflare account is compromised.
