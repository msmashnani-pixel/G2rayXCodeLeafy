const GITHUB_API_VERSION = "2022-11-28";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" && request.method === "GET") {
      return new Response(renderForm(), {
        headers: { "content-type": "text/html; charset=utf-8" }
      });
    }

    if (url.pathname !== "/wake") {
      return json({ ok: false, error: "not_found" }, 404);
    }

    if (request.method === "GET") {
      return new Response(renderForm(), {
        headers: { "content-type": "text/html; charset=utf-8" }
      });
    }

    if (request.method !== "POST") {
      return json({ ok: false, error: "method_not_allowed" }, 405);
    }

    const form = await readForm(request);
    const suppliedSecret = bearerSecret(request) || form.get("wake_secret") || "";

    if (!env.WAKE_SECRET || suppliedSecret !== env.WAKE_SECRET) {
      return json({ ok: false, error: "unauthorized" }, 401);
    }

    const codespaceName = String(env.CODESPACE_NAME || "").trim();
    if (!codespaceName) {
      return json({ ok: false, error: "missing_codespace_name" }, 500);
    }

    if (!env.GITHUB_TOKEN) {
      return json({ ok: false, error: "missing_github_token" }, 500);
    }

    return startCodespace(codespaceName, env.GITHUB_TOKEN);
  }
};

async function startCodespace(name, token) {
  const endpoint = `https://api.github.com/user/codespaces/${encodeURIComponent(name)}/start`;
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": GITHUB_API_VERSION,
      "user-agent": "g2ray-codespace-waker"
    }
  });

  const text = await res.text();
  const body = parseBody(text);

  if (res.status === 402) {
    return json({
      ok: false,
      status: res.status,
      reason: "quota_or_billing_blocked",
      detail: githubErrorDetail(body)
    }, 402);
  }

  if (res.status === 401 || res.status === 403) {
    return json({
      ok: false,
      status: res.status,
      reason: "github_token_rejected_or_missing_scope",
      detail: githubErrorDetail(body)
    }, res.status);
  }

  if (res.status === 404) {
    return json({
      ok: false,
      status: res.status,
      reason: "codespace_not_found_or_token_cannot_access_it",
      detail: githubErrorDetail(body)
    }, 404);
  }

  return json({
    ok: res.ok || res.status === 202 || res.status === 304 || res.status === 409,
    status: res.status,
    codespace: name,
    state: body && typeof body === "object" ? body.state || null : null,
    last_used_at: body && typeof body === "object" ? body.last_used_at || null : null,
    idle_timeout_minutes: body && typeof body === "object" ? body.idle_timeout_minutes || null : null,
    message: "Codespace start request accepted. Wait for the Codespace and app route to become ready."
  }, res.ok || res.status === 202 || res.status === 304 || res.status === 409 ? 200 : 502);
}

function bearerSecret(request) {
  const auth = request.headers.get("authorization") || "";
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : "";
}

async function readForm(request) {
  const contentType = request.headers.get("content-type") || "";
  if (contentType.includes("application/x-www-form-urlencoded") || contentType.includes("multipart/form-data")) {
    return request.formData();
  }
  return new FormData();
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

function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

function renderForm() {
  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>G2ray Codespace Waker</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; }
  label, input, button { display: block; width: 100%; box-sizing: border-box; }
  input, button { font: inherit; padding: .7rem; margin-top: .4rem; }
  button { margin-top: 1rem; cursor: pointer; }
  code { background: #eee; padding: .1rem .3rem; }
</style>
<h1>G2ray Codespace Waker</h1>
<p>This privately starts the configured GitHub Codespace. It cannot bypass GitHub quota, billing, deletion, or account restrictions.</p>
<form method="post" action="/wake">
  <label>
    Wake secret
    <input name="wake_secret" type="password" autocomplete="off" required>
  </label>
  <button type="submit">Start Codespace</button>
</form>
<p>Browser use is recommended so the wake secret stays out of shell history. For CLI use, prefer an environment variable over typing the secret directly into the command.</p>
<pre><code>read -rsp "Wake secret: " WAKE_SECRET; echo
curl -X POST -H "Authorization: Bearer \${WAKE_SECRET}" https://YOUR_WORKER/wake
unset WAKE_SECRET</code></pre>`;
}
