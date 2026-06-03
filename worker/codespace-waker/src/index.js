const GITHUB_API_VERSION = "2022-11-28";
const DEFAULT_CODESPACE_PORT = 443;
const GITHUB_STATE_WAIT_MS = 120000;
const GITHUB_STATE_POLL_INTERVAL_MS = 5000;
const ROUTE_WAIT_MS = 35000;
const ROUTE_POLL_INTERVAL_MS = 3000;
const ROUTE_READY_STABLE_PROBES = 2;
const ROUTE_READY_STABLE_SLEEP_MS = 1000;
const FETCH_TIMEOUT_MS = 10000;
const ROUTE_FETCH_TIMEOUT_MS = 7000;
const HISTORY_KEY_PREFIX = "history:";
const QUOTA_INCIDENT_KEY_PREFIX = "quota-incident:";
const HISTORY_LIMIT = 50;
const FAILED_AUTH_KEY_PREFIX = "failed-auth:";
const SUCCESSFUL_WAKE_KEY_PREFIX = "successful-wake:";
const FAILED_AUTH_WINDOW_SECONDS = 600;
const FAILED_AUTH_MAX_ATTEMPTS = 10;
const DEFAULT_ROUTE_POLL_AFTER_SECONDS = 5;
const QUOTA_CRON_DAILY_INTERVAL_MS = 23 * 60 * 60 * 1000;
const QUOTA_CRON_NEAR_RESET_INTERVAL_MS = 60 * 60 * 1000;
const QUOTA_CRON_NEAR_RESET_WINDOW_MS = 6 * 60 * 60 * 1000;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if ((url.pathname === "/" || url.pathname === "/wake") && request.method === "GET") {
      return html(renderDashboard());
    }

    if (url.pathname === "/api/wake" && request.method === "POST") {
      return handleWake(request, env, ctx);
    }

    if (url.pathname === "/api/health" && request.method === "POST") {
      return handleHealth(request, env, ctx);
    }

    if (url.pathname === "/api/history" && request.method === "POST") {
      return handleHistory(request, env);
    }

    if (url.pathname === "/wake" && request.method === "POST") {
      return handleWake(request, env, ctx);
    }

    if (url.pathname === "/wake" || url.pathname.startsWith("/api/")) {
      return json({ ok: false, error: "method_not_allowed" }, 405);
    }

    return json({ ok: false, error: "not_found" }, 404);
  },

  async scheduled(controller, env, ctx) {
    if (!quotaSurvivalCronEnabled(env)) return;
    const task = handleQuotaSurvivalCron(controller, env);
    if (ctx && typeof ctx.waitUntil === "function") {
      ctx.waitUntil(task);
    } else {
      await task;
    }
  }
};

async function handleWake(request, env, ctx) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status, retryHeaders(context.body));

  const cooldown = await rateLimitSuccessfulWake(context.codespaceName, env);
  if (cooldown) return json(cooldown.body, cooldown.status, retryHeaders(cooldown.body));

  const data = withSurvivalFields(await startCodespaceData(context.codespaceName, context.token, env), env);
  data.next_action = data.next_action || nextActionForWake(data, data.route_probe || {});
  const responseStatus = responseStatusFor(data);
  applyResponseHints(data, responseStatus, env);
  const event = eventFromResult("wake", context.codespaceName, data);
  const historyRecorded = await recordHistory(env, {
    ...event,
    history_recorded_at: new Date().toISOString()
  });
  const quotaIncident = await recordQuotaIncident(env, event, data);
  const notifications = await queueNotifications(env, event, ctx);
  await rememberSuccessfulWake(context.codespaceName, env, data);

  return json({
    ...data,
    history_enabled: Boolean(env.WAKER_KV),
    history_recorded: historyRecorded,
    quota_incident_recorded: quotaIncident.recorded,
    quota_drought_active: quotaIncident.incident
      ? quotaIncident.incident.quota_drought_active === true
      : data.quota_blocked === true,
    notification_status: notifications.status,
    notifications_deferred: notifications.deferred,
    notification_errors: notifications.errors
  }, responseStatus, retryHeaders(data));
}

async function handleHealth(request, env, ctx) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status, retryHeaders(context.body));

  const url = new URL(request.url);
  const checkRoute = url.searchParams.get("route") !== "false";
  const codespaceName = context.codespaceName;
  const status = await getCodespaceStatus(codespaceName, env.GITHUB_TOKEN);
  const routeProbe = status.ok && checkRoute
    ? await waitForXhttpRoute(codespaceName, codespacePort(env), env)
    : {
        url: routeUrl(codespaceName, codespacePort(env)),
        usable: false,
        http_status: checkRoute ? 0 : null,
        latency_ms: null,
        attempts: 0,
        waited_ms: 0,
        stable_probes: 0,
        error: checkRoute ? "github_status_not_ok" : "route_check_skipped",
        route_failure_reason: checkRoute ? "github_status_not_ok" : "not_checked"
      };
  const data = withSurvivalFields({
    ...status,
    route_checked: checkRoute,
    route_ready: checkRoute ? isRouteReadyProbe(routeProbe) : null,
    route_probe: routeProbe,
    next_action: status.ok && !checkRoute
      ? "Route probe skipped. Use Check Health normally when you need route readiness."
      : nextActionForWake(status, routeProbe),
    message: status.ok && !checkRoute
      ? "GitHub state checked; route probe skipped by request."
      : healthMessage(status, routeProbe)
  }, env);
  const responseStatus = responseStatusFor(data);
  applyResponseHints(data, responseStatus, env);
  const event = eventFromResult("health", codespaceName, data);
  const historyRecorded = await recordHistory(env, {
    ...event,
    history_recorded_at: new Date().toISOString()
  });
  const quotaIncident = await recordQuotaIncident(env, event, data);
  const notifications = await queueNotifications(env, event, ctx);

  return json({
    ...data,
    history_enabled: Boolean(env.WAKER_KV),
    history_recorded: historyRecorded,
    quota_incident_recorded: quotaIncident.recorded,
    quota_drought_active: quotaIncident.incident
      ? quotaIncident.incident.quota_drought_active === true
      : data.quota_blocked === true,
    notification_status: notifications.status,
    notifications_deferred: notifications.deferred,
    notification_errors: notifications.errors
  }, responseStatus, retryHeaders(data));
}

async function handleHistory(request, env) {
  const context = await requireAuthorizedContext(request, env);
  if (!context.ok) return json(context.body, context.status, retryHeaders(context.body));

  const history = await readHistory(env, context.codespaceName);
  const quotaIncident = await readQuotaIncident(env, context.codespaceName);
  return json({
    ok: true,
    codespace: context.codespaceName,
    history_enabled: Boolean(env.WAKER_KV),
    quota_incident: quotaIncident,
    history
  }, 200);
}

async function requireAuthorizedContext(request, env) {
  const suppliedSecret = await readSuppliedSecret(request);

  if (!env.WAKE_SECRET || !(await secretsEqual(suppliedSecret, env.WAKE_SECRET))) {
    const limited = await rateLimitFailedAuth(request, env);
    if (limited) return limited;
    return { ok: false, status: 401, body: { ok: false, error: "unauthorized" } };
  }

  const codespaceName = String(env.CODESPACE_NAME || "").trim();
  if (!codespaceName) {
    return { ok: false, status: 500, body: { ok: false, error: "missing_codespace_name" } };
  }

  if (!env.GITHUB_TOKEN) {
    return { ok: false, status: 500, body: { ok: false, error: "missing_github_token" } };
  }

  return {
    ok: true,
    codespaceName,
    token: env.GITHUB_TOKEN
  };
}

async function rateLimitFailedAuth(request, env) {
  if (!env.WAKER_KV) return null;
  const key = failedAuthKey(request);
  try {
    const raw = await env.WAKER_KV.get(key);
    const count = Number.parseInt(raw || "0", 10) || 0;
    const next = count + 1;
    await env.WAKER_KV.put(key, String(next), { expirationTtl: FAILED_AUTH_WINDOW_SECONDS });
    if (next > FAILED_AUTH_MAX_ATTEMPTS) {
      return {
        ok: false,
        status: 429,
        body: {
          ok: false,
          error: "too_many_failed_wake_secret_attempts",
          reason: "worker_wake_secret_rate_limited",
          retry_after_seconds: FAILED_AUTH_WINDOW_SECONDS
        }
      };
    }
  } catch {
    return null;
  }
  return null;
}

async function rateLimitSuccessfulWake(codespaceName, env) {
  if (!env.WAKER_KV) return null;
  const seconds = configuredCooldownSeconds(env, "WAKE_COOLDOWN_SECONDS", 0, 3600);
  if (!seconds) return null;
  const key = SUCCESSFUL_WAKE_KEY_PREFIX + encodeURIComponent(codespaceName);
  try {
    const raw = await env.WAKER_KV.get(key);
    if (!raw) return null;
    return {
      ok: false,
      status: 429,
      body: {
        ok: false,
        status: 429,
        codespace: codespaceName,
        reason: "wake_recently_succeeded",
        retry_after_seconds: seconds,
        message: "A wake request already succeeded recently. Wait before sending another start request."
      }
    };
  } catch {
    return null;
  }
}

async function rememberSuccessfulWake(codespaceName, env, data) {
  if (!env.WAKER_KV || !data || data.ok !== true) return false;
  const seconds = configuredCooldownSeconds(env, "WAKE_COOLDOWN_SECONDS", 0, 3600);
  if (!seconds) return false;
  if (data.route_ready !== true && data.start_accepted !== true) return false;
  const key = SUCCESSFUL_WAKE_KEY_PREFIX + encodeURIComponent(codespaceName);
  try {
    await env.WAKER_KV.put(key, new Date().toISOString(), { expirationTtl: seconds });
    return true;
  } catch {
    return false;
  }
}

function failedAuthKey(request) {
  const ip = request.headers.get("cf-connecting-ip")
    || request.headers.get("x-forwarded-for")
    || "unknown";
  return FAILED_AUTH_KEY_PREFIX + encodeURIComponent(String(ip).split(",")[0].trim() || "unknown");
}

async function secretsEqual(supplied, expected) {
  if (!supplied || !expected) return false;
  const left = await sha256Hex(String(supplied));
  const right = await sha256Hex(String(expected));
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let i = 0; i < left.length; i += 1) {
    diff |= left.charCodeAt(i) ^ right.charCodeAt(i);
  }
  return diff === 0;
}

async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function startCodespaceData(name, token, env) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(name)}/start`;
  let res;
  try {
    res = await fetchWithTimeout(endpoint, {
      method: "POST",
      headers: githubHeaders(token)
    }, FETCH_TIMEOUT_MS);
  } catch (error) {
    return {
      ok: false,
      status: 0,
      codespace: name,
      reason: "github_start_request_unreachable",
      error: shortError(error),
      message: "GitHub start API did not answer before the timeout."
    };
  }

  const text = await res.text();
  const body = parseBody(text);

  const githubFailure = githubFailureForResponse(res, body, name);
  if (githubFailure) {
    if (githubFailure.reason === "quota_or_billing_blocked") {
      const status = await getCodespaceStatus(name, token);
      return {
        ...githubFailure,
        state: status.state || null,
        pending_operation: status.pending_operation ?? null,
        last_used_at: status.last_used_at || null,
        idle_timeout_minutes: status.idle_timeout_minutes || null,
        location: status.location || null,
        retention_period_minutes: status.retention_period_minutes ?? null,
        retention_expires_at: status.retention_expires_at || null,
        route_ready: false,
        route_probe: null
      };
    }
    return githubFailure;
  }

  const accepted = res.ok || res.status === 202 || res.status === 304 || res.status === 409;
  if (!accepted) {
    return {
      ok: false,
      status: res.status,
      codespace: name,
      reason: "github_start_request_failed",
      detail: githubErrorDetail(body),
      message: "GitHub did not accept the Codespace start request."
    };
  }

  const readyState = await waitForCodespaceAvailable(name, token, env);
  if (!readyState.ok) {
    return {
      ...readyState,
      start_accepted: true,
      github_wait_ms: readyState.waited_ms,
      github_wait_attempts: readyState.attempts
    };
  }

  const routeProbe = await waitForXhttpRoute(name, codespacePort(env), env);
  const routeReady = isRouteReadyProbe(routeProbe);

  return {
    ok: true,
    status: res.status,
    start_accepted: true,
    codespace: name,
    state: readyState.state || (body && typeof body === "object" ? body.state || null : null),
    pending_operation: readyState.pending_operation,
    last_used_at: readyState.last_used_at || (body && typeof body === "object" ? body.last_used_at || null : null),
    idle_timeout_minutes: readyState.idle_timeout_minutes || (body && typeof body === "object" ? body.idle_timeout_minutes || null : null),
    location: readyState.location || (body && typeof body === "object" ? body.location || null : null),
    retention_period_minutes: readyState.retention_period_minutes ?? (body && typeof body === "object" ? body.retention_period_minutes ?? null : null),
    retention_expires_at: readyState.retention_expires_at || (body && typeof body === "object" ? body.retention_expires_at || null : null),
    github_wait_ms: readyState.waited_ms,
    github_wait_attempts: readyState.attempts,
    route_ready: routeReady,
    route_probe: routeProbe,
    next_action: nextActionForWake(readyState, routeProbe),
    message: routeReady
      ? "Codespace start request accepted and the XHTTP route is usable."
      : "Codespace start request accepted, but the XHTTP route is still settling. Wait and try again; if it stays 404, open the panel and use option 6 Recover Now."
  };
}

async function waitForCodespaceAvailable(name, token, env) {
  const startedAt = Date.now();
  const stateWaitMs = configuredMs(env, "GITHUB_STATE_WAIT_MS", GITHUB_STATE_WAIT_MS, 1, 300000);
  const pollIntervalMs = configuredMs(env, "GITHUB_STATE_POLL_INTERVAL_MS", GITHUB_STATE_POLL_INTERVAL_MS, 1, 60000);
  const deadline = startedAt + stateWaitMs;
  let attempts = 0;
  let last = {
    ok: false,
    status: 0,
    codespace: name,
    state: null,
    pending_operation: null,
    attempts,
    waited_ms: 0,
    reason: "not_checked",
    message: "Codespace state has not been checked yet."
  };

  while (Date.now() < deadline) {
    attempts += 1;
    last = await getCodespaceStatus(name, token);
    last.attempts = attempts;
    last.waited_ms = Date.now() - startedAt;
    if (!last.ok && isTransientGithubStatusFailure(last)) {
      if (Date.now() + pollIntervalMs > deadline) break;
      await sleep(pollIntervalMs);
      continue;
    }
    if (!last.ok) return last;
    if (isCodespaceAvailable(last)) return last;
    if (Date.now() + pollIntervalMs > deadline) break;
    await sleep(pollIntervalMs);
  }

  return {
    ...last,
    ok: false,
    reason: "codespace_state_not_ready",
    message: "GitHub accepted the start request, but the Codespace did not become Available before the wait timeout."
  };
}

async function getCodespaceStatus(codespaceName, token) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(codespaceName)}`;
  let res;
  try {
    res = await fetchWithTimeout(endpoint, {
      method: "GET",
      headers: githubHeaders(token)
    }, FETCH_TIMEOUT_MS);
  } catch (error) {
    return {
      ok: false,
      status: 0,
      codespace: codespaceName,
      reason: "github_status_request_unreachable",
      error: shortError(error),
      message: "GitHub status API did not answer before the timeout."
    };
  }

  const body = parseBody(await res.text());

  const githubFailure = githubFailureForResponse(res, body, codespaceName);
  if (githubFailure) return githubFailure;

  if (!res.ok) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: res.status === 404
        ? "codespace_not_found_or_token_cannot_access_it"
        : "github_status_request_failed",
      detail: githubErrorDetail(body),
      message: "GitHub status request failed."
    };
  }

  return {
    ok: true,
    status: res.status,
    codespace: codespaceName,
    state: body && typeof body === "object" ? body.state || null : null,
    pending_operation: body && typeof body === "object" ? Boolean(body.pending_operation) : null,
    last_used_at: body && typeof body === "object" ? body.last_used_at || null : null,
    idle_timeout_minutes: body && typeof body === "object" ? body.idle_timeout_minutes || null : null,
    location: body && typeof body === "object" ? body.location || null : null,
    retention_period_minutes: body && typeof body === "object" ? body.retention_period_minutes ?? null : null,
    retention_expires_at: body && typeof body === "object" ? body.retention_expires_at || null : null,
    message: "Codespace status loaded."
  };
}

function githubFailureForResponse(res, body, codespaceName) {
  const rateFields = githubRateFields(res);
  if (res.status === 429) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "github_rate_limited",
      detail: githubErrorDetail(body),
      ...rateFields,
      message: "GitHub API rate limit reached. Wait for the reset window, then try again."
    };
  }

  if (res.status === 402) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "quota_or_billing_blocked",
      detail: githubErrorDetail(body),
      message: "GitHub quota or billing blocked the Codespace start request."
    };
  }

  if (res.status === 401) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body),
      token_warning: "GitHub token rejected or expired",
      message: "GitHub token rejected or expired. Rotate the token or add the codespace scope."
    };
  }

  if (res.status === 403) {
    const message = String(body && typeof body === "object" ? body.message || "" : body || "").toLowerCase();
    if (rateFields.github_rate_limit_remaining === 0) {
      return {
        ok: false,
        status: 429,
        codespace: codespaceName,
        reason: "github_rate_limited",
        detail: githubErrorDetail(body),
        ...rateFields,
        message: "GitHub API rate limit reached. Wait for the reset window, then try again."
      };
    }
    if (rateFields.retry_after_seconds || message.includes("secondary rate limit") || message.includes("abuse detection")) {
      return {
        ok: false,
        status: 429,
        codespace: codespaceName,
        reason: "github_secondary_rate_limited",
        detail: githubErrorDetail(body),
        ...rateFields,
        message: "GitHub temporarily throttled this token. Wait, then try again."
      };
    }
    if (
      message.includes("resource not accessible") ||
      message.includes("must have the codespace scope") ||
      message.includes("missing scope") ||
      message.includes("requires codespace")
    ) {
      return {
        ok: false,
        status: res.status,
        codespace: codespaceName,
        reason: "github_token_scope_missing",
        detail: githubErrorDetail(body),
        token_warning: "GitHub token is missing the codespace scope",
        message: "GitHub token was accepted, but it cannot access Codespaces. Create a classic token with the codespace scope."
      };
    }
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body),
      token_warning: "GitHub token rejected or expired",
      message: "GitHub token rejected or expired. Rotate the token or add the codespace scope."
    };
  }

  if (res.status === 404) {
    return {
      ok: false,
      status: res.status,
      codespace: codespaceName,
      reason: "codespace_not_found_or_token_cannot_access_it",
      detail: githubErrorDetail(body),
      message: "Codespace not found, or the token cannot access it."
    };
  }

  return null;
}

function githubRateFields(res) {
  const retryAfter = parseNullableInt(res.headers.get("retry-after"));
  const reset = parseNullableInt(res.headers.get("x-ratelimit-reset"));
  const remaining = parseNullableInt(res.headers.get("x-ratelimit-remaining"));
  const limit = parseNullableInt(res.headers.get("x-ratelimit-limit"));
  const resource = res.headers.get("x-ratelimit-resource") || null;
  return {
    retry_after_seconds: retryAfter,
    retry_after_epoch: reset,
    github_rate_limit_remaining: remaining,
    github_rate_limit_limit: limit,
    github_rate_limit_resource: resource
  };
}

function parseNullableInt(value) {
  if (value == null || value === "") return null;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function githubHeaders(token) {
  return {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${token}`,
    "x-github-api-version": GITHUB_API_VERSION,
    "user-agent": "g2ray-codespace-waker"
  };
}

function responseStatusFor(data) {
  if (data.start_accepted && data.reason === "codespace_state_not_ready") return 202;
  if (
    data.ok &&
    data.start_accepted &&
    data.route_ready === false &&
    (isRouteSettlingStatus(data.route_probe) || data.route_probe?.error === "route_stability_not_confirmed")
  ) return 202;
  if (data.ok) return 200;
  if ([401, 402, 403, 404, 429].includes(data.status)) return data.status;
  return 502;
}

function applyResponseHints(data, status, env) {
  if (!data || typeof data !== "object") return data;
  if (status === 202 && !data.retry_after_seconds) {
    data.retry_after_seconds = configuredNumber(env, "ROUTE_POLL_AFTER_SECONDS", DEFAULT_ROUTE_POLL_AFTER_SECONDS, 1, 120);
  }
  if ((status === 202 || shouldPollRouteResponse(data)) && !data.poll_after_seconds) {
    data.poll_after_seconds = data.retry_after_seconds || configuredNumber(env, "ROUTE_POLL_AFTER_SECONDS", DEFAULT_ROUTE_POLL_AFTER_SECONDS, 1, 120);
  }
  return data;
}

function shouldPollRouteResponse(data) {
  return Boolean(data && (data.ok || data.start_accepted) && data.route_ready === false && data.quota_blocked !== true);
}

function retryHeaders(data) {
  let retryAfter = data && Number.parseInt(String(data.retry_after_seconds || ""), 10);
  if ((!Number.isFinite(retryAfter) || retryAfter <= 0) && data && data.retry_after_epoch) {
    const epoch = Number.parseInt(String(data.retry_after_epoch), 10);
    if (Number.isFinite(epoch)) {
      retryAfter = Math.ceil((epoch * 1000 - Date.now()) / 1000);
    }
  }
  if (!Number.isFinite(retryAfter) || retryAfter <= 0) return {};
  return { "retry-after": String(retryAfter) };
}

function withSurvivalFields(data, env) {
  const now = currentDate(env);
  const quotaBlocked = data.reason === "quota_or_billing_blocked" || Number(data.status) === 402;
  const retentionPeriod = normalizeNullableNumber(data.retention_period_minutes);
  const retentionExpires = data.retention_expires_at || null;
  const retentionRisk = retentionRiskFor(retentionExpires, retentionPeriod, now);
  const resetEstimate = nextMonthlyQuotaResetIso(now);
  const survivalNextAction = survivalNextActionFor({
    ...data,
    quota_blocked: quotaBlocked,
    retention_period_minutes: retentionPeriod,
    retention_expires_at: retentionExpires,
    retention_risk: retentionRisk,
    quota_reset_estimate_utc: resetEstimate
  });
  const next = {
    ...data,
    quota_blocked: quotaBlocked,
    quota_reset_estimate_utc: resetEstimate,
    retention_period_minutes: retentionPeriod,
    retention_expires_at: retentionExpires,
    retention_risk: retentionRisk,
    survival_next_action: survivalNextAction
  };
  if (quotaBlocked) {
    next.route_ready = false;
    if (!("route_probe" in next)) next.route_probe = null;
    next.next_action = survivalNextAction;
  }
  return next;
}

function currentDate(env, scheduledTime) {
  const candidate = env && env.TEST_NOW_UTC ? Date.parse(env.TEST_NOW_UTC) : Number.NaN;
  if (Number.isFinite(candidate)) return new Date(candidate);
  if (Number.isFinite(scheduledTime)) return new Date(scheduledTime);
  return new Date();
}

function nextMonthlyQuotaResetIso(now) {
  const reset = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1, 0, 0, 0));
  return reset.toISOString().replace(".000Z", "Z");
}

function normalizeNullableNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function retentionRiskFor(retentionExpiresAt, retentionPeriodMinutes, now) {
  if (!retentionExpiresAt) return retentionPeriodMinutes == null ? "unknown" : "safe";
  const expires = Date.parse(retentionExpiresAt);
  if (!Number.isFinite(expires)) return "unknown";
  const remaining = expires - now.getTime();
  if (remaining <= 3 * 24 * 60 * 60 * 1000) return "urgent";
  if (remaining <= 7 * 24 * 60 * 60 * 1000) return "warning";
  return "safe";
}

function survivalNextActionFor(data) {
  if (data.quota_blocked) {
    return `Quota or billing is blocking starts. Mark this Codespace as Keep codespace in GitHub now, then retry after the estimated quota reset at ${data.quota_reset_estimate_utc}.`;
  }
  if (data.reason === "codespace_not_found_or_token_cannot_access_it" || Number(data.status) === 404) {
    return "Codespace is missing or the token cannot access it. If GitHub deleted it, create a new Codespace and generate new configs.";
  }
  if (data.retention_risk === "urgent" || data.retention_risk === "warning") {
    return "Mark this Codespace as Keep codespace in GitHub Codespaces so the same domain/configs can survive until quota resets.";
  }
  if (data.retention_risk === "unknown") {
    return "Open GitHub Codespaces and confirm this Codespace is marked Keep codespace before quota runs out.";
  }
  return "No quota survival action needed now. For best safety, mark this Codespace as Keep codespace before quota runs out.";
}

function isTransientGithubStatusFailure(last) {
  const status = Number(last && last.status || 0);
  return status === 0 || status >= 500;
}

function isRouteSettlingStatus(routeProbe) {
  const status = Number(routeProbe && routeProbe.http_status || 0);
  return status === 0 || status === 404;
}

function isRouteReadyProbe(routeProbe) {
  return Boolean(
    routeProbe &&
    routeProbe.usable === true &&
    Number(routeProbe.stable_probes || 0) >= ROUTE_READY_STABLE_PROBES &&
    !routeProbe.error
  );
}

function isCodespaceAvailable(status) {
  const state = String(status && status.state || "").toLowerCase();
  return Boolean(status && status.ok && (state === "available" || state === "running") && status.pending_operation !== true);
}

function nextActionForWake(status, routeProbe) {
  if (status.reason === "github_rate_limited" || status.reason === "github_secondary_rate_limited") {
    return "GitHub is throttling this token. Wait for the retry/reset window, then press Check Health or Start Codespace again.";
  }
  if (status.reason === "github_token_rejected_or_missing_scope") {
    return "Rotate the GitHub token and make sure it has the codespace scope.";
  }
  if (status.reason === "github_token_scope_missing") {
    return "Create a new classic GitHub token with the codespace scope, then update Worker secret GITHUB_TOKEN.";
  }
  if (!status.ok) return "Open GitHub Codespaces or rotate the GitHub token, then try the Worker again.";
  if (!isCodespaceAvailable(status)) return "Wait for GitHub to finish starting the Codespace, then press Check Health.";
  if (routeProbe.error === "route_stability_not_confirmed") {
    return "The route answered once, but stability was not confirmed yet. Wait a few seconds, then press Check Health or Start Codespace again.";
  }
  if (routeProbe.usable) return "Try the same VLESS config again.";
  if (routeProbe.route_failure_reason === "edge_or_origin_error") return "GitHub's edge or origin returned a server error. Wait briefly, then Check Health; if it persists, open the panel and Recover Now.";
  if (routeProbe.route_failure_reason === "timeout_or_unreachable" || routeProbe.route_failure_reason === "dns_tls_or_network_unreachable") return "The app.github.dev route did not answer from Cloudflare. Open the Codespace once, then check port visibility and panel diagnostics.";
  if (routeProbe.http_status === 404) return "Open the panel, check option 14 Diagnostics, then use option 6 Recover Now if the route stays 404.";
  if (routeProbe.http_status === 0) return "The app.github.dev route did not resolve or answer. Open the Codespace once, then check port 443 visibility and panel diagnostics.";
  return "Check panel option 14 Diagnostics; if XHTTP is not usable, use option 6 Recover Now.";
}

function healthMessage(status, routeProbe) {
  if (status.token_warning) return status.message;
  if (!status.ok) return status.message || "GitHub status is not available.";
  if (routeProbe.usable) return "Codespace is available and the XHTTP route is usable.";
  if (routeProbe.http_status === 404) {
    return "Codespace exists, but the app.github.dev route is still settling or not routed.";
  }
  if (routeProbe.http_status === 0) {
    return "Codespace status loaded, but the app.github.dev route did not answer.";
  }
  return "Codespace status loaded, but the XHTTP route is not usable yet.";
}

function eventFromResult(kind, codespace, data) {
  const routeChecked = data.route_checked !== false;
  return {
    ts: new Date().toISOString(),
    kind,
    ok: Boolean(data.ok),
    codespace,
    github_status: data.status || null,
    state: data.state || null,
    route_checked: routeChecked,
    route_ready: routeChecked && data.route_ready != null ? data.route_ready === true : null,
    route_http_status: data.route_probe ? data.route_probe.http_status : null,
    route_latency_ms: data.route_probe ? data.route_probe.latency_ms : null,
    route_waited_ms: data.route_probe ? data.route_probe.waited_ms : null,
    route_attempts: data.route_probe ? data.route_probe.attempts : null,
    reason: data.reason || null,
    quota_blocked: data.quota_blocked === true,
    quota_reset_estimate_utc: data.quota_reset_estimate_utc || null,
    retention_expires_at: data.retention_expires_at || null,
    retention_risk: data.retention_risk || null,
    token_warning: data.token_warning || null,
    message: data.message || null
  };
}

async function recordHistory(env, event) {
  if (!env.WAKER_KV) return false;

  try {
    const existing = await readHistory(env, event.codespace);
    const next = [event, ...existing].slice(0, HISTORY_LIMIT);
    await env.WAKER_KV.put(historyKey(event.codespace), JSON.stringify(next));
    return true;
  } catch {
    return false;
  }
}

async function recordQuotaIncident(env, event, data) {
  if (!env.WAKER_KV) return { recorded: false, incident: null };
  try {
    const nowIso = currentDate(env).toISOString();
    const existing = await readQuotaIncident(env, event.codespace) || {};
    const incident = {
      ...existing,
      codespace: event.codespace,
      last_observed_at: nowIso,
      quota_reset_estimate_utc: data.quota_reset_estimate_utc || existing.quota_reset_estimate_utc || null,
      retention_period_minutes: data.retention_period_minutes ?? existing.retention_period_minutes ?? null,
      retention_expires_at: data.retention_expires_at || existing.retention_expires_at || null,
      retention_risk: data.retention_risk || existing.retention_risk || "unknown"
    };

    if (data.quota_blocked) {
      incident.first_quota_blocked_at = incident.first_quota_blocked_at || nowIso;
      incident.latest_quota_blocked_at = nowIso;
      incident.quota_drought_active = true;
      incident.same_codespace_exists = data.reason === "codespace_not_found_or_token_cannot_access_it" ? false : true;
    } else if (data.ok) {
      incident.same_codespace_exists = true;
      if (event.kind === "wake" || event.kind === "cron_wake") {
        incident.last_successful_start_at = nowIso;
      }
      if (event.kind === "health" || event.kind === "cron_health") {
        incident.last_successful_health_at = nowIso;
      }
      if (event.kind === "wake" || event.kind === "cron_wake" || data.route_ready === true) {
        incident.quota_drought_active = false;
      } else if (incident.quota_drought_active !== true) {
        incident.quota_drought_active = false;
      }
    } else if (data.reason === "codespace_not_found_or_token_cannot_access_it") {
      incident.same_codespace_exists = false;
    }

    await env.WAKER_KV.put(quotaIncidentKey(event.codespace), JSON.stringify(incident));
    return { recorded: true, incident };
  } catch {
    return { recorded: false, incident: null };
  }
}

async function readHistory(env, codespace) {
  if (!env.WAKER_KV) return [];

  try {
    const text = await env.WAKER_KV.get(historyKey(codespace));
    const parsed = text ? JSON.parse(text) : [];
    return Array.isArray(parsed) ? parsed.slice(0, HISTORY_LIMIT) : [];
  } catch {
    return [];
  }
}

async function readQuotaIncident(env, codespace) {
  if (!env.WAKER_KV) return null;

  try {
    const text = await env.WAKER_KV.get(quotaIncidentKey(codespace));
    const parsed = text ? JSON.parse(text) : null;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function historyKey(codespace) {
  const suffix = String(codespace || "unknown").trim() || "unknown";
  return HISTORY_KEY_PREFIX + encodeURIComponent(suffix);
}

function quotaIncidentKey(codespace) {
  const suffix = String(codespace || "unknown").trim() || "unknown";
  return QUOTA_INCIDENT_KEY_PREFIX + encodeURIComponent(suffix);
}

function quotaSurvivalCronEnabled(env) {
  const value = String(env && env.QUOTA_SURVIVAL_CRON_ENABLED || "").trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes";
}

async function handleQuotaSurvivalCron(controller, env) {
  const codespaceName = String(env.CODESPACE_NAME || "").trim();
  if (!env.WAKER_KV || !codespaceName || !env.GITHUB_TOKEN) {
    return { ok: false, skipped: "missing_kv_codespace_or_token" };
  }

  const incident = await readQuotaIncident(env, codespaceName);
  if (!incident || incident.quota_drought_active !== true) {
    return { ok: true, skipped: "no_active_quota_drought" };
  }

  const now = currentDate(env, controller && controller.scheduledTime);
  if (!quotaCronCheckAllowed(incident, now)) {
    return { ok: true, skipped: "quota_cron_throttled" };
  }

  const nearReset = quotaCronNearReset(incident, now);
  if (nearReset && !quotaCronWakeAllowed(incident)) {
    if (resultNeedsCronStamp(incident, now)) {
      incident.last_cron_check_at = now.toISOString();
      await env.WAKER_KV.put(quotaIncidentKey(codespaceName), JSON.stringify(incident));
    }
    return { ok: true, skipped: "quota_cron_near_reset_wake_already_attempted" };
  }
  const data = withSurvivalFields(
    nearReset
      ? await startCodespaceData(codespaceName, env.GITHUB_TOKEN, env)
      : await getCodespaceStatus(codespaceName, env.GITHUB_TOKEN),
    env
  );
  const event = eventFromResult(nearReset ? "cron_wake" : "cron_health", codespaceName, data);
  await recordHistory(env, {
    ...event,
    history_recorded_at: now.toISOString()
  });
  const result = await recordQuotaIncident(env, event, data);
  if (result.incident) {
    result.incident.last_cron_check_at = now.toISOString();
    if (nearReset) {
      result.incident.last_cron_wake_at = now.toISOString();
      result.incident.last_cron_wake_reset_estimate_utc = incident.quota_reset_estimate_utc || null;
    }
    await env.WAKER_KV.put(quotaIncidentKey(codespaceName), JSON.stringify(result.incident));
  }
  return { ok: true, near_reset: nearReset, quota_blocked: data.quota_blocked === true };
}

function quotaCronCheckAllowed(incident, now) {
  const last = Date.parse(incident.last_cron_check_at || "");
  if (!Number.isFinite(last)) return true;
  const interval = quotaCronNearReset(incident, now)
    ? QUOTA_CRON_NEAR_RESET_INTERVAL_MS
    : QUOTA_CRON_DAILY_INTERVAL_MS;
  return now.getTime() - last >= interval;
}

function quotaCronNearReset(incident, now) {
  const reset = Date.parse(incident.quota_reset_estimate_utc || "");
  if (!Number.isFinite(reset)) return false;
  return now.getTime() >= reset - QUOTA_CRON_NEAR_RESET_WINDOW_MS;
}

function quotaCronWakeAllowed(incident) {
  return incident.last_cron_wake_reset_estimate_utc !== incident.quota_reset_estimate_utc;
}

function resultNeedsCronStamp(incident, now) {
  const last = Date.parse(incident.last_cron_check_at || "");
  return !Number.isFinite(last) || now.getTime() - last >= QUOTA_CRON_NEAR_RESET_INTERVAL_MS;
}

async function sendNotifications(env, event) {
  if (!shouldNotify(event)) return [];
  if (!hasNotificationChannels(env)) return [];

  const text = notificationText(event);
  const tasks = [];

  if (env.DISCORD_WEBHOOK_URL) {
    tasks.push(
      fetchWithTimeout(env.DISCORD_WEBHOOK_URL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content: text })
      }, FETCH_TIMEOUT_MS).then((res) => res.ok ? null : `discord_http_${res.status}`)
        .catch((error) => `discord_${shortError(error)}`)
    );
  }

  if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    const endpoint = `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`;
    tasks.push(
      fetchWithTimeout(endpoint, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: env.TELEGRAM_CHAT_ID,
          text,
          disable_web_page_preview: true
        })
      }, FETCH_TIMEOUT_MS).then((res) => res.ok ? null : `telegram_http_${res.status}`)
        .catch((error) => `telegram_${shortError(error)}`)
    );
  }

  const results = await Promise.all(tasks);
  return results.filter(Boolean);
}

async function queueNotifications(env, event, ctx) {
  if (!shouldNotify(event)) return { status: "none", deferred: false, errors: [] };
  if (!hasNotificationChannels(env)) return { status: "none", deferred: false, errors: [] };

  const task = sendNotifications(env, event).then((errors) => {
    if (errors.length) {
      console.warn("notification_errors", errors.join(","));
    }
    return errors;
  });

  if (ctx && typeof ctx.waitUntil === "function") {
    ctx.waitUntil(task.catch((error) => {
      console.warn("notification_failed", shortError(error));
    }));
    return { status: "deferred", deferred: true, errors: [] };
  }

  const errors = await task;
  return { status: errors.length ? "failed" : "sent", deferred: false, errors };
}

function hasNotificationChannels(env) {
  return Boolean(env.DISCORD_WEBHOOK_URL || (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID));
}

function shouldNotify(event) {
  if (event.reason === "github_token_rejected_or_missing_scope") return true;
  if (event.kind !== "wake") return false;
  if (event.route_ready) return true;
  return event.route_http_status === 404 || !event.ok;
}

function notificationText(event) {
  const route = event.route_http_status
    ? `route HTTP ${event.route_http_status}${event.route_latency_ms === null ? "" : `, ${event.route_latency_ms}ms`}`
    : "route not checked";
  return [
    `G2ray Codespace Waker: ${event.kind}`,
    `codespace=${event.codespace}`,
    `ok=${event.ok}`,
    `state=${event.state || "unknown"}`,
    `route_ready=${event.route_ready}`,
    route,
    event.reason ? `reason=${event.reason}` : null,
    event.token_warning ? `warning=${event.token_warning}` : null,
    event.message ? `message=${event.message}` : null
  ].filter(Boolean).join("\n");
}

function shortError(error) {
  return error && error.message ? String(error.message).slice(0, 80) : "failed";
}

async function readSuppliedSecret(request) {
  const auth = bearerSecret(request);
  if (auth) return auth;

  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      const body = await request.json();
      return body && typeof body === "object" ? String(body.wake_secret || "") : "";
    } catch {
      return "";
    }
  }

  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    try {
      const form = await request.formData();
      return String(form.get("wake_secret") || "");
    } catch {
      return "";
    }
  }

  return "";
}

function bearerSecret(request) {
  const auth = request.headers.get("authorization") || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

function parseBody(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text.slice(0, 1000);
  }
}

function githubErrorDetail(body) {
  if (!body || typeof body !== "object") return null;
  return {
    message: body.message || null,
    documentation_url: body.documentation_url || null
  };
}

function codespacePort(env) {
  const value = Number.parseInt(String(env.CODESPACE_PORT || DEFAULT_CODESPACE_PORT), 10);
  return Number.isInteger(value) && value > 0 && value <= 65535 ? value : DEFAULT_CODESPACE_PORT;
}

function configuredMs(env, name, fallback, min, max) {
  const value = Number.parseInt(String(env && env[name] != null ? env[name] : fallback), 10);
  if (!Number.isInteger(value)) return fallback;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

function configuredNumber(env, name, fallback, min, max) {
  return configuredMs(env, name, fallback, min, max);
}

function configuredCooldownSeconds(env, name, fallback, max) {
  const value = configuredNumber(env, name, fallback, 0, max);
  return value > 0 && value < 60 ? 60 : value;
}

async function waitForXhttpRoute(name, port, env) {
  const startedAt = Date.now();
  const routeWaitMs = configuredMs(env, "ROUTE_WAIT_MS", ROUTE_WAIT_MS, 1, 300000);
  const pollIntervalMs = configuredMs(env, "ROUTE_POLL_INTERVAL_MS", ROUTE_POLL_INTERVAL_MS, 1, 60000);
  const stableSleepMs = configuredMs(env, "ROUTE_READY_STABLE_SLEEP_MS", ROUTE_READY_STABLE_SLEEP_MS, 0, 10000);
  const deadline = startedAt + routeWaitMs;
  let attempts = 0;
  let stableProbes = 0;
  let last = {
    url: routeUrl(name, port),
    usable: false,
    http_status: 0,
    latency_ms: null,
    attempts,
    waited_ms: 0,
    stable_probes: stableProbes,
    error: "not_checked"
  };

  while (Date.now() < deadline) {
    attempts += 1;
    last = await probeXhttpRoute(name, port, attempts, startedAt);
    if (last.usable) {
      stableProbes += 1;
      last.stable_probes = stableProbes;
      if (stableProbes >= ROUTE_READY_STABLE_PROBES) return last;
      if (stableSleepMs > 0) {
        const delay = Math.min(stableSleepMs, Math.max(0, deadline - Date.now()));
        if (delay > 0) await sleep(delay);
      }
      continue;
    }
    stableProbes = 0;
    last.stable_probes = stableProbes;

    if (Date.now() + pollIntervalMs > deadline) break;
    await sleep(pollIntervalMs);
  }

  if (last.usable && stableProbes < ROUTE_READY_STABLE_PROBES) {
    return {
      ...last,
      stable_probes: stableProbes,
      error: "route_stability_not_confirmed",
      route_failure_reason: "route_stability_not_confirmed"
    };
  }
  return last;
}

async function probeXhttpRoute(name, port, attempts = 1, startedAt = Date.now()) {
  const url = routeUrl(name, port);
  const probeStartedAt = Date.now();
  try {
    const res = await fetchWithTimeout(url, { method: "OPTIONS", redirect: "manual" }, ROUTE_FETCH_TIMEOUT_MS);
    return {
      url,
      usable: isRouteStatusUsable(res.status),
      http_status: res.status,
      latency_ms: Date.now() - probeStartedAt,
      attempts,
      waited_ms: Date.now() - startedAt,
      error: null,
      route_failure_reason: routeFailureReason(res.status, null)
    };
  } catch (error) {
    const reason = routeFailureReason(0, error);
    return {
      url,
      usable: false,
      http_status: 0,
      latency_ms: Date.now() - probeStartedAt,
      attempts,
      waited_ms: Date.now() - startedAt,
      error: shortError(error),
      route_failure_reason: reason
    };
  }
}

async function fetchWithTimeout(input, init = {}, timeoutMs = FETCH_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, {
      ...init,
      signal: controller.signal
    });
  } finally {
    clearTimeout(timer);
  }
}

function routeUrl(name, port) {
  return `https://${name}-${port}.app.github.dev/`;
}

function isRouteStatusUsable(status) {
  return status === 200 || status === 400;
}

function routeFailureReason(status, error) {
  if (isRouteStatusUsable(status)) return "ready";
  if (status === 404) return "route_settling_404";
  if (status === 0) {
    const message = shortError(error).toLowerCase();
    if (message.includes("abort") || message.includes("time") || message.includes("timeout")) return "timeout_or_unreachable";
    return "dns_tls_or_network_unreachable";
  }
  if (status >= 500) return "edge_or_origin_error";
  if (status === 401 || status === 403) return "auth_or_visibility_blocked";
  return "unexpected_http_status";
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: securityHeaders({
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extraHeaders
    }, "json")
  });
}

function html(markup, status = 200) {
  return new Response(markup, {
    status,
    headers: securityHeaders({
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store"
    }, "html")
  });
}

function securityHeaders(headers, kind) {
  const csp = kind === "html"
    ? "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; img-src 'self' data:; connect-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'"
    : "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
  return {
    ...headers,
    "content-security-policy": csp,
    "permissions-policy": "camera=(), geolocation=(), microphone=()",
    "referrer-policy": "no-referrer",
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY"
  };
}

function renderDashboard() {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>G2ray Codespace Waker</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #101214;
    --panel: #181c20;
    --panel-2: #20262c;
    --text: #eef2f4;
    --muted: #9ca8b3;
    --good: #22c55e;
    --warn: #f59e0b;
    --bad: #ef4444;
    --line: #303842;
    --accent: #38bdf8;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    line-height: 1.45;
  }
  main {
    width: min(900px, 100%);
    margin: 0 auto;
    padding: 20px;
  }
  h1 { margin: 0 0 6px; font-size: 30px; letter-spacing: 0; }
  h2 { margin: 0 0 12px; font-size: 18px; letter-spacing: 0; }
  h3 { margin: 16px 0 10px; font-size: 15px; letter-spacing: 0; }
  p { margin: 0 0 14px; color: var(--muted); }
  .card {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 16px;
    margin: 14px 0;
  }
  label { display: block; color: var(--muted); font-size: 14px; margin-bottom: 8px; }
  input {
    width: 100%;
    border: 1px solid var(--line);
    border-radius: 6px;
    background: #0b0d0f;
    color: var(--text);
    font: inherit;
    padding: 12px;
  }
  .actions {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    margin-top: 12px;
  }
  button {
    min-height: 46px;
    border: 0;
    border-radius: 6px;
    background: var(--panel-2);
    color: var(--text);
    font: inherit;
    font-weight: 700;
    cursor: pointer;
  }
  button.primary { background: var(--accent); color: #061017; }
  button:disabled { cursor: wait; opacity: .6; }
  .grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }
  .metric {
    background: var(--panel-2);
    border-radius: 6px;
    padding: 12px;
    min-height: 78px;
  }
  .metric span { display: block; color: var(--muted); font-size: 12px; }
  .metric strong { display: block; margin-top: 6px; font-size: 18px; word-break: break-word; }
  .good { color: var(--good); }
  .warn { color: var(--warn); }
  .bad { color: var(--bad); }
  ol { margin: 0; padding-left: 22px; color: var(--muted); }
  li.active { color: var(--accent); }
  li.done { color: var(--good); }
  pre {
    white-space: pre-wrap;
    word-break: break-word;
    background: #0b0d0f;
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 12px;
    overflow: auto;
  }
  .history {
    display: grid;
    gap: 8px;
  }
  .event {
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 10px;
    color: var(--muted);
  }
  .trend-row {
    display: grid;
    grid-template-columns: 130px 1fr 72px;
    align-items: center;
    gap: 10px;
    color: var(--muted);
    font-size: 13px;
  }
  .trend-track {
    height: 10px;
    border-radius: 999px;
    background: #0b0d0f;
    overflow: hidden;
  }
  .trend-bar {
    height: 100%;
    min-width: 2px;
    background: var(--accent);
  }
  @media (max-width: 640px) {
    main { padding: 14px; }
    h1 { font-size: 25px; }
    .actions, .grid { grid-template-columns: 1fr; }
    button { min-height: 52px; }
  }
</style>
</head>
<body>
<main>
  <h1>G2ray Codespace Waker</h1>
  <p>Mobile wake UI for one GitHub Codespace. Actions require your wake secret; the page starts the Codespace, checks the app.github.dev XHTTP route, and shows whether configs should be usable.</p>

  <section class="card">
    <h2>Start</h2>
    <label for="secret">Wake secret</label>
    <input id="secret" type="password" autocomplete="off" placeholder="Paste WAKE_SECRET">
    <div class="actions">
      <button id="start" class="primary" type="button">Start Codespace</button>
      <button id="health" type="button">Check Health</button>
      <button id="history" type="button">Load History</button>
      <button id="copy" type="button">Copy Status</button>
      <button id="stop" type="button">Stop Polling</button>
    </div>
  </section>

  <section class="card">
    <h2>Health dashboard</h2>
    <div class="grid">
      <div class="metric"><span>GitHub state</span><strong id="githubState">Not checked</strong></div>
      <div class="metric"><span>Route</span><strong id="routeState">Not checked</strong></div>
      <div class="metric"><span>Latency</span><strong id="latency">Not checked</strong></div>
      <div class="metric"><span>Idle timeout</span><strong id="idleTimeout">Not checked</strong></div>
      <div class="metric"><span>Last used</span><strong id="lastUsed">Not checked</strong></div>
      <div class="metric"><span>Last failure</span><strong id="lastFailure">None seen</strong></div>
      <div class="metric"><span>Next action</span><strong id="nextAction">Not checked</strong></div>
    </div>
  </section>

  <section class="card">
    <h2>Quota Survival</h2>
    <div class="grid">
      <div class="metric"><span>Quota block</span><strong id="quotaBlocked">Not checked</strong></div>
      <div class="metric"><span>Estimated reset</span><strong id="quotaReset">Not checked</strong></div>
      <div class="metric"><span>Retention risk</span><strong id="retentionRisk">Not checked</strong></div>
      <div class="metric"><span>Retention expires</span><strong id="retentionExpires">Not checked</strong></div>
      <div class="metric"><span>Quota drought</span><strong id="quotaDrought">Not checked</strong></div>
      <div class="metric"><span>Survival action</span><strong id="survivalAction">Not checked</strong></div>
    </div>
  </section>

  <section class="card">
    <h2>Progress</h2>
    <ol id="progress">
      <li>Waiting for a wake or health check</li>
    </ol>
  </section>

  <section class="card">
    <h2>Result</h2>
    <pre id="result">No result yet.</pre>
  </section>

  <section class="card">
    <h2>History</h2>
    <p id="historyNote">History appears when WAKER_KV is configured.</p>
    <h3>Route history summary</h3>
    <div id="historySummary" class="grid">
      <div class="metric"><span>Samples</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Route ready</span><strong>Not loaded</strong></div>
      <div class="metric"><span>HTTP 404</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Wake success</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Best latency</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Last stuck route</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Quota blocks</span><strong>Not loaded</strong></div>
      <div class="metric"><span>Quota drought</span><strong>Not loaded</strong></div>
    </div>
    <h3>Latency trend</h3>
    <div id="latencyTrend" class="history"></div>
    <h3>Recent events</h3>
    <div id="historyList" class="history"></div>
  </section>
</main>

<script>
const secretInput = document.getElementById("secret");
const resultEl = document.getElementById("result");
const progressEl = document.getElementById("progress");
const historyList = document.getElementById("historyList");
const historyNote = document.getElementById("historyNote");
const historySummary = document.getElementById("historySummary");
const latencyTrend = document.getElementById("latencyTrend");
let lastStatusText = "";
let polling = false;
let pollTimer = null;
let pollAfterSeconds = 5;

document.getElementById("start").addEventListener("click", startWake);
document.getElementById("health").addEventListener("click", checkHealth);
document.getElementById("history").addEventListener("click", loadHistory);
document.getElementById("copy").addEventListener("click", copyStatus);
document.getElementById("stop").addEventListener("click", stopPolling);

function wakeSecret() {
  return secretInput.value.trim();
}

function setButtons(disabled) {
  for (const id of ["start", "health", "history", "copy"]) {
    document.getElementById(id).disabled = disabled;
  }
}

function setProgress(items, activeIndex) {
  progressEl.innerHTML = "";
  items.forEach((item, index) => {
    const li = document.createElement("li");
    li.textContent = item;
    if (index < activeIndex) li.className = "done";
    if (index === activeIndex) li.className = "active";
    progressEl.appendChild(li);
  });
}

async function callApi(path) {
  const secret = wakeSecret();
  if (!secret) throw new Error("Wake secret is required.");
  const res = await fetch(path, {
    method: "POST",
    headers: {
      "authorization": "Bearer " + secret,
      "accept": "application/json"
    }
  });
  const data = await res.json().catch(() => ({ ok: false, error: "invalid_json_response" }));
  if (!res.ok && !data.status) data.status = res.status;
  return data;
}

async function startWake() {
  polling = true;
  setButtons(true);
  const steps = ["Authenticating wake secret", "Calling GitHub start API", "Codespace started", "Checking XHTTP route", "Route ready or settling"];
  setProgress(steps, 0);
  try {
    setProgress(steps, 1);
    const data = await callApi("/api/wake");
    setProgress(steps, data.route_ready ? 4 : data.start_accepted ? 3 : data.ok ? 4 : 1);
    renderResult(data);
    if (shouldPollRoute(data)) {
      scheduleHealthPoll();
    }
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function checkHealth() {
  setButtons(true);
  setProgress(["Authenticating wake secret", "Checking GitHub state", "Probing XHTTP route", "Showing result"], 1);
  try {
    const data = await callApi("/api/health");
    setProgress(["Authenticating wake secret", "Checking GitHub state", "Probing XHTTP route", "Showing result"], 3);
    renderResult(data);
    if (polling && shouldPollRoute(data)) {
      scheduleHealthPoll();
    }
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function loadHistory() {
  setButtons(true);
  try {
    const data = await callApi("/api/history");
    renderHistory(data);
  } catch (error) {
    renderError(error);
  } finally {
    setButtons(false);
  }
}

async function copyStatus() {
  if (!lastStatusText) return;
  try {
    await navigator.clipboard.writeText(lastStatusText);
  } catch (error) {
    renderError(error);
  }
}

function shouldPollRoute(data) {
  return Boolean(data && (data.ok || data.start_accepted) && data.route_ready !== true && data.quota_blocked !== true);
}

function scheduleHealthPoll() {
  if (!polling) return;
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = setTimeout(checkHealth, Math.max(1, pollAfterSeconds) * 1000);
}

function stopPolling() {
  polling = false;
  if (pollTimer) clearTimeout(pollTimer);
  pollTimer = null;
  setProgress(["Polling stopped manually"], 0);
}

function renderResult(data) {
  const route = data.route_probe || {};
  const routeReady = data.route_ready === true;
  pollAfterSeconds = Number.isFinite(Number(data.poll_after_seconds || data.retry_after_seconds))
    ? Number(data.poll_after_seconds || data.retry_after_seconds)
    : 5;
  document.getElementById("githubState").textContent = data.state || (data.ok ? "Available" : "Problem");
  document.getElementById("routeState").textContent = routeReady ? "Route ready" : route.http_status ? "HTTP " + route.http_status : "Not reachable";
  document.getElementById("routeState").className = routeReady ? "good" : route.http_status === 404 ? "warn" : "bad";
  document.getElementById("latency").textContent = route.latency_ms == null ? "Unknown" : route.latency_ms + "ms";
  document.getElementById("idleTimeout").textContent = data.idle_timeout_minutes ? data.idle_timeout_minutes + " minutes" : "Unknown";
  document.getElementById("lastUsed").textContent = data.last_used_at || "Unknown";
  document.getElementById("lastFailure").textContent = routeSettlingFailureText(data, route, routeReady);
  document.getElementById("nextAction").textContent = data.next_action || "No action suggested";
  document.getElementById("quotaBlocked").textContent = data.quota_blocked ? "Quota blocked" : "No block seen";
  document.getElementById("quotaBlocked").className = data.quota_blocked ? "bad" : "good";
  document.getElementById("quotaReset").textContent = data.quota_reset_estimate_utc || "Unknown";
  document.getElementById("retentionRisk").textContent = data.retention_risk || "Unknown";
  document.getElementById("retentionRisk").className = data.retention_risk === "urgent" ? "bad" : data.retention_risk === "warning" ? "warn" : "";
  document.getElementById("retentionExpires").textContent = data.retention_expires_at || "Not scheduled / unknown";
  document.getElementById("quotaDrought").textContent = data.quota_drought_active ? "Active" : "No active drought";
  document.getElementById("survivalAction").textContent = data.survival_next_action || "Not checked";
  resultEl.textContent = JSON.stringify(data, null, 2);
  lastStatusText = [
    "G2ray Codespace Waker",
    "ok=" + Boolean(data.ok),
    "codespace=" + (data.codespace || "unknown"),
    "state=" + (data.state || "unknown"),
    "route_ready=" + routeReady,
    "route_http_status=" + (route.http_status || "unknown"),
    "latency_ms=" + (route.latency_ms == null ? "unknown" : route.latency_ms),
    "quota_blocked=" + Boolean(data.quota_blocked),
    "retention_risk=" + (data.retention_risk || "unknown"),
    "quota_reset_estimate_utc=" + (data.quota_reset_estimate_utc || "unknown"),
    "survival_next_action=" + (data.survival_next_action || ""),
    "next_action=" + (data.next_action || ""),
    "message=" + (data.message || data.error || "")
  ].join("\\n");
  if (routeReady) {
    polling = false;
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = null;
  }
}

function routeSettlingFailureText(data, route, routeReady) {
  const tokenRejected = data.token_warning || data.reason === "github_token_rejected_or_missing_scope";
  if (tokenRejected) return "GitHub token rejected or expired";
  if (data.ok && !routeReady && data.route_probe) {
    return route.http_status
      ? "Route not ready (HTTP " + route.http_status + ")"
      : "Route not reachable yet";
  }
  return data.ok ? "None seen" : (data.reason || data.error || "Unknown failure");
}

function renderHistory(data) {
  historyList.innerHTML = "";
  latencyTrend.innerHTML = "";
  if (data && data.ok === false) {
    const message = data.reason || data.error || (data.status ? "HTTP " + data.status : "history_request_failed");
    historyNote.textContent = "History request failed: " + message;
    const item = document.createElement("div");
    item.className = "event";
    item.textContent = data.message || data.token_warning || message;
    historyList.appendChild(item);
    resultEl.textContent = JSON.stringify(data, null, 2);
    return;
  }
  historyNote.textContent = data.history_enabled
    ? "Recent wake and health events."
    : "History is disabled because WAKER_KV is not configured.";
  const events = data.history || [];
  renderHistorySummary(events, data.quota_incident || null);
  renderLatencyTrend(events);
  for (const event of events) {
    const item = document.createElement("div");
    item.className = "event";
    item.textContent = [
      event.ts,
      event.kind,
      "ok=" + event.ok,
      "route_ready=" + event.route_ready,
      "http=" + (event.route_http_status || "unknown"),
      "latency=" + (event.route_latency_ms == null ? "unknown" : event.route_latency_ms + "ms"),
      "waited=" + (event.route_waited_ms == null ? "unknown" : event.route_waited_ms + "ms"),
      event.reason || ""
    ].filter(Boolean).join(" | ");
    historyList.appendChild(item);
  }
}

function renderHistorySummary(events, quotaIncident) {
  const summary = summarizeHistory(events);
  historySummary.innerHTML = "";
  const cards = [
    ["Samples", String(summary.samples)],
    ["Route ready", summary.ready + " / " + summary.routeSamples],
    ["HTTP 404", String(summary.http404)],
    ["Wake success", summary.wakeOk + " ok / " + summary.wakeFail + " fail"],
    ["Best latency", summary.bestLatency == null ? "None" : summary.bestLatency + "ms"],
    ["Last stuck route", summary.lastStuck || "None seen"],
    ["Quota blocks", String(summary.quotaBlocks)],
    ["Quota drought", quotaIncident && quotaIncident.quota_drought_active ? "Active" : "Inactive / none"]
  ];
  for (const [label, value] of cards) {
    const card = document.createElement("div");
    card.className = "metric";
    const span = document.createElement("span");
    span.textContent = label;
    const strong = document.createElement("strong");
    strong.textContent = value;
    card.appendChild(span);
    card.appendChild(strong);
    historySummary.appendChild(card);
  }
}

function summarizeHistory(events) {
  const summary = {
    samples: events.length,
    routeSamples: 0,
    ready: 0,
    http404: 0,
    wakeOk: 0,
    wakeFail: 0,
    quotaBlocks: 0,
    bestLatency: null,
    lastStuck: ""
  };
  for (const event of events) {
    const routeChecked = event.route_checked !== false && event.route_ready !== null;
    if (routeChecked) {
      summary.routeSamples += 1;
      if (event.route_ready === true) summary.ready += 1;
      if (event.route_http_status === 404) summary.http404 += 1;
    }
    if (event.kind === "wake" && event.ok) summary.wakeOk += 1;
    if (event.kind === "wake" && !event.ok) summary.wakeFail += 1;
    if (event.quota_blocked === true || event.reason === "quota_or_billing_blocked") summary.quotaBlocks += 1;
    if (routeChecked && Number.isFinite(event.route_latency_ms)) {
      summary.bestLatency = summary.bestLatency == null
        ? event.route_latency_ms
        : Math.min(summary.bestLatency, event.route_latency_ms);
    }
    if (routeChecked && !summary.lastStuck && event.route_ready !== true && (event.route_http_status === 404 || event.route_http_status === 0)) {
      const waited = event.route_waited_ms == null ? "" : ", waited " + event.route_waited_ms + "ms";
      summary.lastStuck = (event.ts || "unknown time") + " HTTP " + (event.route_http_status || 0) + waited;
    }
  }
  return summary;
}

function renderLatencyTrend(events) {
  const latencyEvents = events
    .filter((event) => Number.isFinite(event.route_latency_ms))
    .slice(0, 12)
    .reverse();
  if (latencyEvents.length === 0) {
    const empty = document.createElement("div");
    empty.className = "event";
    empty.textContent = "No latency samples yet.";
    latencyTrend.appendChild(empty);
    return;
  }
  const max = Math.max(...latencyEvents.map((event) => event.route_latency_ms), 1);
  for (const event of latencyEvents) {
    const row = document.createElement("div");
    row.className = "trend-row";
    const label = document.createElement("span");
    label.textContent = shortTime(event.ts);
    const track = document.createElement("div");
    track.className = "trend-track";
    const bar = document.createElement("div");
    bar.className = "trend-bar";
    bar.style.width = Math.max(4, Math.round((event.route_latency_ms / max) * 100)) + "%";
    track.appendChild(bar);
    const value = document.createElement("span");
    value.textContent = event.route_latency_ms + "ms";
    row.appendChild(label);
    row.appendChild(track);
    row.appendChild(value);
    latencyTrend.appendChild(row);
  }
}

function shortTime(value) {
  if (!value) return "unknown";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 16);
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function renderError(error) {
  resultEl.textContent = JSON.stringify({
    ok: false,
    error: error && error.message ? error.message : "request_failed"
  }, null, 2);
}
</script>
</body>
</html>`;
}
