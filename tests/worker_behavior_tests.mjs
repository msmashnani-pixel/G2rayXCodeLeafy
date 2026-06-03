import assert from "node:assert/strict";
import worker from "../worker/codespace-waker/src/index.js";

const originalFetch = globalThis.fetch;

function makeRequest(path, secret = "secret") {
  return new Request(`https://worker.example${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${secret}`
    }
  });
}

function makeKv() {
  const store = new Map();
  return {
    async get(key) {
      return store.get(key) || null;
    },
    async put(key, value) {
      store.set(key, value);
    },
    dump() {
      return Object.fromEntries(store.entries());
    }
  };
}

function baseEnv(overrides = {}) {
  return {
    WAKE_SECRET: "secret",
    GITHUB_TOKEN: "github-token",
    CODESPACE_NAME: "behavior-space",
    ROUTE_READY_STABLE_SLEEP_MS: "0",
    ...overrides
  };
}

async function responseJson(response) {
  return JSON.parse(await response.text());
}

async function testFailedSecretRateLimit() {
  const env = baseEnv({ WAKER_KV: makeKv() });
  let last;
  for (let i = 0; i < 11; i += 1) {
    last = await worker.fetch(makeRequest("/api/health", "wrong-secret"), env, {});
  }
  const body = await responseJson(last);
  assert.equal(last.status, 429);
  assert.equal(last.headers.get("retry-after"), "600");
  assert.equal(body.reason, "worker_wake_secret_rate_limited");
  assert.equal(body.retry_after_seconds, 600);
  console.log("PASS: Worker rate-limits repeated bad wake secrets");
}

async function testGithubRateLimitClassification() {
  const resetEpoch = Math.ceil(Date.now() / 1000) + 120;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "API rate limit exceeded" }), {
        status: 403,
        headers: {
          "content-type": "application/json",
          "x-ratelimit-remaining": "0",
          "x-ratelimit-reset": String(resetEpoch)
        }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 404 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 429);
  assert.equal(Number(response.headers.get("retry-after")) > 0, true);
  assert.equal(body.reason, "github_rate_limited");
  assert.equal(body.retry_after_epoch, resetEpoch);
  assert.match(body.next_action, /GitHub is throttling/);
  console.log("PASS: Worker classifies GitHub primary rate limits");
}

async function testGithubScopeFailureClassification() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "Resource not accessible by personal access token" }), {
        status: 403,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 403);
  assert.equal(body.reason, "github_token_scope_missing");
  assert.match(body.next_action, /codespace scope/);
  console.log("PASS: Worker classifies token scope failures distinctly");
}

async function testWakeSettlingIncludesRetryMetadata() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 404 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/wake"), baseEnv({
    ROUTE_WAIT_MS: "1",
    ROUTE_POLL_INTERVAL_MS: "1"
  }), {});
  const body = await responseJson(response);
  assert.equal(response.status, 202);
  assert.equal(response.headers.get("retry-after"), "5");
  assert.equal(body.route_ready, false);
  assert.equal(body.retry_after_seconds, 5);
  assert.equal(body.poll_after_seconds, 5);
  assert.equal(body.route_probe.route_failure_reason, "route_settling_404");
  console.log("PASS: Worker settling responses include retry and route failure metadata");
}

async function testHealthCanSkipRouteProbe() {
  let routeCalls = 0;
  const kv = makeKv();
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health?route=false"), baseEnv({ WAKER_KV: kv }), {});
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_checked, false);
  assert.equal(body.route_ready, null);
  assert.equal(routeCalls, 0);
  const history = await responseJson(await worker.fetch(makeRequest("/api/history"), baseEnv({ WAKER_KV: kv }), {}));
  assert.equal(history.history[0].route_checked, false);
  assert.equal(history.history[0].route_ready, null);
  console.log("PASS: Worker health can skip route probing for cheap status checks");
}

async function testHealthSkipRoutePreservesGithubFailureGuidance() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "Resource not accessible by personal access token" }), {
        status: 403,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health?route=false"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 403);
  assert.equal(body.reason, "github_token_scope_missing");
  assert.match(body.message, /codespace scope/i);
  assert.match(body.next_action, /codespace scope/i);
  assert.doesNotMatch(body.message, /route probe skipped/i);
  console.log("PASS: Worker route-skipped health preserves GitHub failure guidance");
}

async function testAuthorizedWakeCooldownIsOptional() {
  let routeCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const env = baseEnv({ WAKER_KV: makeKv(), WAKE_COOLDOWN_SECONDS: "1" });
  const first = await worker.fetch(makeRequest("/api/wake"), env, {});
  const firstBody = await responseJson(first);
  assert.equal(first.status, 200);
  assert.equal(firstBody.route_ready, true);

  const second = await worker.fetch(makeRequest("/api/wake"), env, {});
  const secondBody = await responseJson(second);
  assert.equal(second.status, 429);
  assert.equal(second.headers.get("retry-after"), "60");
  assert.equal(secondBody.reason, "wake_recently_succeeded");
  assert.equal(secondBody.retry_after_seconds, 60);
  assert.equal(routeCalls >= 2, true);
  console.log("PASS: Worker optional wake cooldown prevents repeated successful wake spam");
}

async function testGithubHttp429Classification() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "Too many requests" }), {
        status: 429,
        headers: {
          "content-type": "application/json",
          "retry-after": "60",
          "x-ratelimit-reset": "1780000123"
        }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 404 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 429);
  assert.equal(body.reason, "github_rate_limited");
  assert.equal(body.retry_after_seconds, 60);
  assert.equal(body.retry_after_epoch, 1780000123);
  assert.match(body.next_action, /GitHub is throttling/);
  console.log("PASS: Worker classifies GitHub HTTP 429 rate limits");
}

async function testQuotaBlockIncludesSurvivalFields() {
  let statusCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ message: "Payment required" }), {
        status: 402,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      statusCalls += 1;
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Shutdown",
        pending_operation: false,
        retention_period_minutes: 43200,
        retention_expires_at: "2026-06-20T00:00:00Z",
        last_used_at: "2026-06-10T00:00:00Z"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ TEST_NOW_UTC: "2026-06-15T12:00:00Z" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 402);
  assert.equal(body.reason, "quota_or_billing_blocked");
  assert.equal(body.quota_blocked, true);
  assert.equal(body.route_ready, false);
  assert.equal(body.quota_reset_estimate_utc, "2026-07-01T00:00:00Z");
  assert.equal(body.retention_period_minutes, 43200);
  assert.equal(body.retention_expires_at, "2026-06-20T00:00:00Z");
  assert.equal(body.retention_risk, "warning");
  assert.match(body.survival_next_action, /Keep codespace/);
  assert.equal(statusCalls, 1);
  console.log("PASS: Worker quota blocks include survival fields");
}

async function testRetentionMissingFieldsAreUnknown() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-06-10T00:00:00Z"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/health"),
    baseEnv({ TEST_NOW_UTC: "2026-06-15T12:00:00Z" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.quota_blocked, false);
  assert.equal(body.retention_period_minutes, null);
  assert.equal(body.retention_expires_at, null);
  assert.equal(body.retention_risk, "unknown");
  assert.equal(body.quota_reset_estimate_utc, "2026-07-01T00:00:00Z");
  console.log("PASS: Worker treats missing retention fields as unknown");
}

async function testMonthlyResetEstimateCrossesYear() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ message: "Payment required" }), {
        status: 402,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Shutdown",
        pending_operation: false
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ TEST_NOW_UTC: "2026-12-31T23:00:00Z" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 402);
  assert.equal(body.quota_reset_estimate_utc, "2027-01-01T00:00:00Z");
  console.log("PASS: Worker monthly reset estimate crosses year boundary");
}

async function testKvQuotaIncidentHistoryRecordsBlockedAndRecovery() {
  const kv = makeKv();
  let routeReady = false;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start") && !routeReady) {
      return new Response(JSON.stringify({ message: "Payment required" }), {
        status: 402,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: routeReady ? "Available" : "Shutdown",
        pending_operation: false,
        retention_period_minutes: 43200,
        retention_expires_at: routeReady ? null : "2026-06-20T00:00:00Z",
        last_used_at: "2026-06-10T00:00:00Z"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const env = baseEnv({ WAKER_KV: kv, TEST_NOW_UTC: "2026-06-15T12:00:00Z" });
  let response = await worker.fetch(makeRequest("/api/wake"), env, {});
  let body = await responseJson(response);
  assert.equal(response.status, 402);
  assert.equal(body.quota_incident_recorded, true);
  assert.equal(body.quota_drought_active, true);

  routeReady = true;
  env.TEST_NOW_UTC = "2026-07-01T00:05:00Z";
  response = await worker.fetch(makeRequest("/api/wake"), env, {});
  body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.quota_incident_recorded, true);
  assert.equal(body.quota_drought_active, false);

  response = await worker.fetch(makeRequest("/api/history"), env, {});
  body = await responseJson(response);
  assert.equal(body.quota_incident.first_quota_blocked_at, "2026-06-15T12:00:00.000Z");
  assert.equal(body.quota_incident.latest_quota_blocked_at, "2026-06-15T12:00:00.000Z");
  assert.equal(body.quota_incident.last_successful_start_at, "2026-07-01T00:05:00.000Z");
  assert.equal(body.quota_incident.quota_drought_active, false);
  assert.equal(body.quota_incident.same_codespace_exists, true);
  console.log("PASS: Worker KV quota incident history records blocked and recovery states");
}

async function testScheduledQuotaCronIsDisabledAndThrottledBeforeReset() {
  const kv = makeKv();
  await kv.put("quota-incident:behavior-space", JSON.stringify({
    quota_drought_active: true,
    quota_reset_estimate_utc: "2026-07-01T00:00:00Z"
  }));
  let statusCalls = 0;
  let startCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      startCalls += 1;
      return new Response(JSON.stringify({ message: "should not start before reset window" }), {
        status: 500,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      statusCalls += 1;
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Shutdown",
        pending_operation: false,
        retention_period_minutes: 43200,
        retention_expires_at: "2026-06-25T00:00:00Z"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const disabledPromises = [];
  await worker.scheduled(
    { scheduledTime: Date.parse("2026-06-15T00:00:00Z") },
    baseEnv({ WAKER_KV: kv }),
    { waitUntil(promise) { disabledPromises.push(promise); } }
  );
  assert.equal(disabledPromises.length, 0);
  assert.equal(statusCalls, 0);

  const env = baseEnv({
    WAKER_KV: kv,
    QUOTA_SURVIVAL_CRON_ENABLED: "true",
    TEST_NOW_UTC: "2026-06-15T00:00:00Z"
  });
  const waitUntilPromises = [];
  await worker.scheduled(
    { scheduledTime: Date.parse("2026-06-15T00:00:00Z") },
    env,
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  await Promise.all(waitUntilPromises);
  await worker.scheduled(
    { scheduledTime: Date.parse("2026-06-15T01:00:00Z") },
    env,
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  await Promise.all(waitUntilPromises);
  assert.equal(statusCalls, 1);
  assert.equal(startCalls, 0);
  const incident = JSON.parse(await kv.get("quota-incident:behavior-space"));
  assert.equal(incident.quota_drought_active, true);
  assert.equal(incident.last_successful_health_at, "2026-06-15T00:00:00.000Z");
  console.log("PASS: Worker scheduled quota survival cron is disabled by default and throttled before reset");
}

async function testScheduledQuotaCronAttemptsOneNearResetWake() {
  const kv = makeKv();
  await kv.put("quota-incident:behavior-space", JSON.stringify({
    quota_drought_active: true,
    quota_reset_estimate_utc: "2026-07-01T00:00:00Z"
  }));
  let startCalls = 0;
  let statusCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      startCalls += 1;
      return new Response(JSON.stringify({ message: "Payment required" }), {
        status: 402,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      statusCalls += 1;
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Shutdown",
        pending_operation: false,
        retention_period_minutes: 43200,
        retention_expires_at: "2026-07-20T00:00:00Z"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const env = baseEnv({
    WAKER_KV: kv,
    QUOTA_SURVIVAL_CRON_ENABLED: "true",
    TEST_NOW_UTC: "2026-06-30T19:00:00Z"
  });
  let waitUntilPromises = [];
  await worker.scheduled(
    { scheduledTime: Date.parse("2026-06-30T19:00:00Z") },
    env,
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  await Promise.all(waitUntilPromises);

  env.TEST_NOW_UTC = "2026-06-30T20:00:00Z";
  waitUntilPromises = [];
  await worker.scheduled(
    { scheduledTime: Date.parse("2026-06-30T20:00:00Z") },
    env,
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  await Promise.all(waitUntilPromises);

  assert.equal(startCalls, 1);
  assert.equal(statusCalls, 1);
  const incident = JSON.parse(await kv.get("quota-incident:behavior-space"));
  assert.equal(incident.quota_drought_active, true);
  assert.equal(incident.last_cron_wake_reset_estimate_utc, "2026-07-01T00:00:00Z");
  console.log("PASS: Worker scheduled quota survival cron attempts only one near-reset wake");
}

async function testWakeFailureIncludesNextAction() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "Bad credentials" }), {
        status: 401,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/wake"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 401);
  assert.equal(body.reason, "github_token_rejected_or_missing_scope");
  assert.match(body.next_action, /Rotate the GitHub token/);
  console.log("PASS: Worker wake failures include actionable next_action");
}

async function testHealthTreatsHttp400RouteAsUsable() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240,
        location: "EastUs"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      return new Response("", { status: 400 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/health"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.route_probe.http_status, 400);
  assert.equal(body.message, "Codespace is available and the XHTTP route is usable.");
  console.log("PASS: Worker route readiness matches panel HTTP 400/200 semantics");
}

async function testWakeRequiresStableRouteReadiness() {
  let routeCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      const status = routeCalls === 1 ? 200 : routeCalls === 2 ? 404 : 200;
      return new Response("", { status });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(makeRequest("/api/wake"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.route_probe.attempts, 4);
  assert.equal(body.route_probe.stable_probes, 2);
  console.log("PASS: Worker rejects transient single route success");
}

async function testWakeWaitsBetweenStableRouteProbes() {
  const routeCallTimes = [];
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCallTimes.push(Date.now());
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ ROUTE_READY_STABLE_SLEEP_MS: "25" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.route_probe.stable_probes, 2);
  assert.equal(routeCallTimes.length >= 2, true);
  assert.equal(routeCallTimes[1] - routeCallTimes[0] >= 20, true);
  console.log("PASS: Worker waits between stable route-readiness probes");
}

async function testWakeDoesNotClaimReadyFromSingleDeadlineProbe() {
  let routeCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ ROUTE_WAIT_MS: "5", ROUTE_READY_STABLE_SLEEP_MS: "25" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 202);
  assert.equal(body.route_ready, false);
  assert.equal(body.route_probe.usable, true);
  assert.equal(body.route_probe.http_status, 200);
  assert.equal(body.route_probe.stable_probes, 1);
  assert.equal(body.route_probe.error, "route_stability_not_confirmed");
  assert.equal(body.route_probe.route_failure_reason, "route_stability_not_confirmed");
  assert.equal(routeCalls, 1);
  console.log("PASS: Worker does not claim route ready from one deadline-limited probe");
}

async function testHealthRequiresStableRouteReadiness() {
  let routeCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/health"),
    baseEnv({ ROUTE_WAIT_MS: "5", ROUTE_READY_STABLE_SLEEP_MS: "25" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, false);
  assert.equal(body.route_probe.usable, true);
  assert.equal(body.route_probe.stable_probes, 1);
  assert.equal(body.route_probe.error, "route_stability_not_confirmed");
  assert.equal(body.route_probe.route_failure_reason, "route_stability_not_confirmed");
  assert.equal(routeCalls, 1);
  console.log("PASS: Worker health requires stable route readiness");
}

async function testWakePreservesStartAcceptedWhenGithubStateWaitTimesOut() {
  let statusCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Starting" }), {
        status: 202,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      statusCalls += 1;
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Starting",
        pending_operation: true,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ GITHUB_STATE_WAIT_MS: "5", GITHUB_STATE_POLL_INTERVAL_MS: "1" }),
    {}
  );
  const body = await responseJson(response);
  assert.equal(response.status, 202);
  assert.equal(body.ok, false);
  assert.equal(body.start_accepted, true);
  assert.equal(body.reason, "codespace_state_not_ready");
  assert.equal(body.github_wait_attempts >= 1, true);
  assert.equal(statusCalls >= 1, true);
  console.log("PASS: Worker preserves start_accepted when GitHub state wait times out");
}

async function testDashboardIncludesRouteHistorySummaryUi() {
  const response = await worker.fetch(new Request("https://worker.example/wake"), baseEnv(), {});
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /Route history summary/);
  assert.match(html, /Quota Survival/);
  assert.match(html, /quotaBlocked/);
  assert.match(html, /quotaReset/);
  assert.match(html, /latencyTrend/);
  assert.match(html, /renderHistorySummary/);
  assert.match(html, /History request failed:/);
  console.log("PASS: Worker dashboard includes route history summary UI");
}

async function testHistoryRejectsBadSecretClearly() {
  const response = await worker.fetch(makeRequest("/api/history", "wrong-secret"), baseEnv(), {});
  const body = await responseJson(response);
  assert.equal(response.status, 401);
  assert.equal(body.ok, false);
  assert.equal(body.error, "unauthorized");
  console.log("PASS: Worker history rejects bad wake secret clearly");
}

async function testResponsesIncludeSecurityHeaders() {
  const htmlResponse = await worker.fetch(new Request("https://worker.example/wake"), baseEnv(), {});
  assert.equal(htmlResponse.headers.get("x-content-type-options"), "nosniff");
  assert.equal(htmlResponse.headers.get("referrer-policy"), "no-referrer");
  assert.equal(htmlResponse.headers.get("x-frame-options"), "DENY");
  assert.match(htmlResponse.headers.get("content-security-policy") || "", /frame-ancestors 'none'/);

  const jsonResponse = await worker.fetch(makeRequest("/api/history", "wrong-secret"), baseEnv(), {});
  assert.equal(jsonResponse.headers.get("x-content-type-options"), "nosniff");
  assert.equal(jsonResponse.headers.get("referrer-policy"), "no-referrer");
  assert.match(jsonResponse.headers.get("content-security-policy") || "", /default-src 'none'/);
  console.log("PASS: Worker responses include security headers");
}

async function testWakeQueuesNotificationsWithWaitUntil() {
  let routeCalls = 0;
  let notificationCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({ state: "Available" }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    if (url.includes("discord.example")) {
      notificationCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const waitUntilPromises = [];
  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ DISCORD_WEBHOOK_URL: "https://discord.example/hook" }),
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.notification_status, "deferred");
  assert.equal(body.notifications_deferred, true);
  assert.deepEqual(body.notification_errors, []);
  assert.equal(waitUntilPromises.length, 1);
  await Promise.all(waitUntilPromises);
  assert.equal(routeCalls >= 2, true);
  assert.equal(notificationCalls, 1);
  console.log("PASS: Worker queues notifications with waitUntil");
}

async function testWakeReportsNoNotificationsWhenChannelsAreUnconfigured() {
  let routeCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({
        state: "Available"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const waitUntilPromises = [];
  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv(),
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.notification_status, "none");
  assert.equal(body.notifications_deferred, false);
  assert.deepEqual(body.notification_errors, []);
  assert.equal(waitUntilPromises.length, 0);
  assert.equal(routeCalls >= 2, true);
  console.log("PASS: Worker reports no notifications when channels are unconfigured");
}

async function testHealthQueuesTokenFailureNotificationWithWaitUntil() {
  let routeCalls = 0;
  let notificationCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "Bad credentials" }), {
        status: 401,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 404 });
    }
    if (url.includes("discord.example")) {
      notificationCalls += 1;
      return new Response("", { status: 200 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const waitUntilPromises = [];
  const response = await worker.fetch(
    makeRequest("/api/health"),
    baseEnv({ DISCORD_WEBHOOK_URL: "https://discord.example/hook" }),
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  const body = await responseJson(response);
  assert.equal(response.status, 401);
  assert.equal(body.reason, "github_token_rejected_or_missing_scope");
  assert.equal(body.notification_status, "deferred");
  assert.equal(body.notifications_deferred, true);
  assert.deepEqual(body.notification_errors, []);
  assert.equal(waitUntilPromises.length, 1);
  await Promise.all(waitUntilPromises);
  assert.equal(routeCalls, 0);
  assert.equal(notificationCalls, 1);
  console.log("PASS: Worker queues health token-failure notifications with waitUntil");
}

async function testDeferredNotificationFailureIsMarkedDeferred() {
  let routeCalls = 0;
  let notificationCalls = 0;
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("/start")) {
      return new Response(JSON.stringify({
        state: "Available"
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({
        name: "behavior-space",
        state: "Available",
        pending_operation: false,
        last_used_at: "2026-05-30T00:00:00Z",
        idle_timeout_minutes: 240
      }), {
        status: 200,
        headers: { "content-type": "application/json" }
      });
    }
    if (url.includes("app.github.dev")) {
      routeCalls += 1;
      return new Response("", { status: 200 });
    }
    if (url.includes("discord.example")) {
      notificationCalls += 1;
      return new Response("bad webhook", { status: 500 });
    }
    throw new Error(`unexpected fetch ${url}`);
  };

  const waitUntilPromises = [];
  const response = await worker.fetch(
    makeRequest("/api/wake"),
    baseEnv({ DISCORD_WEBHOOK_URL: "https://discord.example/hook" }),
    { waitUntil(promise) { waitUntilPromises.push(promise); } }
  );
  const body = await responseJson(response);
  assert.equal(response.status, 200);
  assert.equal(body.route_ready, true);
  assert.equal(body.notification_status, "deferred");
  assert.equal(body.notifications_deferred, true);
  assert.deepEqual(body.notification_errors, []);
  assert.equal(waitUntilPromises.length, 1);
  await Promise.all(waitUntilPromises);
  assert.equal(routeCalls >= 2, true);
  assert.equal(notificationCalls, 1);
  console.log("PASS: Worker marks deferred notification failures as deferred");
}

try {
  await testFailedSecretRateLimit();
  await testGithubRateLimitClassification();
  await testGithubScopeFailureClassification();
  await testWakeSettlingIncludesRetryMetadata();
  await testHealthCanSkipRouteProbe();
  await testHealthSkipRoutePreservesGithubFailureGuidance();
  await testAuthorizedWakeCooldownIsOptional();
  await testGithubHttp429Classification();
  await testQuotaBlockIncludesSurvivalFields();
  await testRetentionMissingFieldsAreUnknown();
  await testMonthlyResetEstimateCrossesYear();
  await testKvQuotaIncidentHistoryRecordsBlockedAndRecovery();
  await testScheduledQuotaCronIsDisabledAndThrottledBeforeReset();
  await testScheduledQuotaCronAttemptsOneNearResetWake();
  await testWakeFailureIncludesNextAction();
  await testHealthTreatsHttp400RouteAsUsable();
  await testWakeRequiresStableRouteReadiness();
  await testWakeWaitsBetweenStableRouteProbes();
  await testWakeDoesNotClaimReadyFromSingleDeadlineProbe();
  await testHealthRequiresStableRouteReadiness();
  await testWakePreservesStartAcceptedWhenGithubStateWaitTimesOut();
  await testDashboardIncludesRouteHistorySummaryUi();
  await testHistoryRejectsBadSecretClearly();
  await testResponsesIncludeSecurityHeaders();
  await testWakeQueuesNotificationsWithWaitUntil();
  await testWakeReportsNoNotificationsWhenChannelsAreUnconfigured();
  await testHealthQueuesTokenFailureNotificationWithWaitUntil();
  await testDeferredNotificationFailureIsMarkedDeferred();
} finally {
  globalThis.fetch = originalFetch;
}
