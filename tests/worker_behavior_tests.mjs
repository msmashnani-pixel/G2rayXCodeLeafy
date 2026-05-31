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
    }
  };
}

function baseEnv(overrides = {}) {
  return {
    WAKE_SECRET: "secret",
    GITHUB_TOKEN: "github-token",
    CODESPACE_NAME: "behavior-space",
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
  assert.equal(body.reason, "worker_wake_secret_rate_limited");
  assert.equal(body.retry_after_seconds, 600);
  console.log("PASS: Worker rate-limits repeated bad wake secrets");
}

async function testGithubRateLimitClassification() {
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.includes("api.github.com")) {
      return new Response(JSON.stringify({ message: "API rate limit exceeded" }), {
        status: 403,
        headers: {
          "content-type": "application/json",
          "x-ratelimit-remaining": "0",
          "x-ratelimit-reset": "1780000000"
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
  assert.equal(body.retry_after_epoch, 1780000000);
  assert.match(body.next_action, /GitHub is throttling/);
  console.log("PASS: Worker classifies GitHub primary rate limits");
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

async function testDashboardIncludesRouteHistorySummaryUi() {
  const response = await worker.fetch(new Request("https://worker.example/wake"), baseEnv(), {});
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /Route history summary/);
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

try {
  await testFailedSecretRateLimit();
  await testGithubRateLimitClassification();
  await testGithubHttp429Classification();
  await testWakeFailureIncludesNextAction();
  await testHealthTreatsHttp400RouteAsUsable();
  await testDashboardIncludesRouteHistorySummaryUi();
  await testHistoryRejectsBadSecretClearly();
} finally {
  globalThis.fetch = originalFetch;
}
