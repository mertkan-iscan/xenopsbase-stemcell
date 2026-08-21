/*
 * The minimal browser client for T-3.13.
 *
 * WHY THERE IS NO OIDC CODE HERE
 *
 * The ticket notes that the realm has a `frontend` public client with PKCE and
 * that no Keycloak work should be needed. This page uses neither, deliberately.
 *
 * The gateway is a backend-for-frontend: it is a CONFIDENTIAL client, it holds
 * the session in a cookie, and TokenRelay attaches the access token on the way
 * to core (T-3.5). This page is served BY that gateway, on that origin, which
 * is its own acceptance criterion -- so the session cookie is simply present on
 * every request and there is nothing for a browser-side OIDC library to do.
 *
 * Driving the `frontend` PKCE client instead would mean a second, parallel
 * login, an access token living in JavaScript where any XSS can read it, and a
 * token the gateway's relay knows nothing about. The public client stays in the
 * realm for a future client that is NOT served through the gateway -- a mobile
 * app, or an SPA on its own origin. It is not the right tool from here.
 *
 * Consequence worth knowing: there is no login button. Loading this page at all
 * requires a session, because "/" is authenticated at the gateway, so an
 * anonymous visitor is redirected to Keycloak before this script is ever
 * fetched.
 */

const CORE = "/services/core/api";
const PAGE_SIZE = 10;

const el = (id) => document.getElementById(id);
const state = { page: 0, links: {}, total: 0 };

/* ------------------------------------------------------------------ *
 * Plumbing
 * ------------------------------------------------------------------ */

/**
 * The CSRF token the gateway issues.
 *
 * CookieServerCsrfTokenRepository.withHttpOnlyFalse() puts it in a cookie this
 * script is allowed to read, and ServerCsrfTokenRequestAttributeHandler expects
 * it echoed back in a header on every mutating request. Cookie alone is not
 * enough -- that is the whole point of the pattern, since a cross-site request
 * carries the cookie but cannot read it to set the header.
 */
function csrfToken() {
  const hit = document.cookie.split("; ").find((c) => c.startsWith("XSRF-TOKEN="));
  return hit ? decodeURIComponent(hit.slice("XSRF-TOKEN=".length)) : "";
}

/**
 * Every call to our own API goes through here.
 *
 * `Accept: application/json` is load-bearing, not decoration. T-3.8 splits the
 * unauthenticated response on exactly that header: a browser NAVIGATION says
 * text/html and is redirected to Keycloak, while a fetch says JSON and gets a
 * 401 problem document. Without it an expired session would return 200 and a
 * page of Keycloak's login HTML, which reads as success to anything checking
 * only the status code.
 */
async function api(path, options = {}) {
  const method = options.method || "GET";
  const headers = { Accept: "application/json", ...(options.headers || {}) };

  if (method !== "GET" && method !== "HEAD") {
    headers["X-XSRF-TOKEN"] = csrfToken();
  }

  const response = await fetch(path, { ...options, method, headers, credentials: "same-origin" });

  if (response.status === 401) {
    sessionExpired();
    throw new Error("unauthenticated");
  }
  if (!response.ok) {
    throw new Error(await problemMessage(response));
  }
  return response;
}

/**
 * Reads the RFC 7807 body the services return for every error (T-3.8), and
 * falls back to the status line if something in front of them answered instead
 * -- an ingress 502 is not going to be a problem document.
 */
async function problemMessage(response) {
  try {
    const body = await response.json();
    return body.detail || body.title || `HTTP ${response.status}`;
  } catch {
    return `HTTP ${response.status}`;
  }
}

/**
 * Parses the RFC 8288 Link header that PaginationUtil emits.
 *
 * Not split on "," -- the URLs contain one, in `sort=createdAt,DESC`. Matching
 * the <...>; rel="..." pairs directly sidesteps that; splitting naively yields
 * two broken halves and a "next" page that 404s.
 */
function parseLinks(header) {
  const links = {};
  if (!header) return links;
  for (const match of header.matchAll(/<([^>]+)>;\s*rel="([^"]+)"/g)) {
    links[match[2]] = match[1];
  }
  return links;
}

/* ------------------------------------------------------------------ *
 * Presentation
 * ------------------------------------------------------------------ */

function banner(message, kind) {
  const node = el("banner");
  node.textContent = message;
  node.className = kind ? `banner ${kind}` : "banner";
  node.hidden = !message;
}

function sessionExpired() {
  banner("Your session ended. Reload the page to sign in again.", "error");
  el("upload").disabled = true;
  el("logout").disabled = true;
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

function formatDate(iso) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString();
}

/**
 * Rows are built with DOM calls rather than an innerHTML template.
 *
 * A filename is supplied by whoever uploaded it and is echoed straight back
 * here. Through innerHTML that is stored XSS on a page holding a live session;
 * textContent cannot be talked into parsing markup.
 */
function renderRows(documents) {
  const body = el("rows");
  body.replaceChildren();

  for (const doc of documents) {
    const row = document.createElement("tr");

    const name = document.createElement("td");
    name.className = "name";
    name.textContent = doc.filename;
    row.appendChild(name);

    const type = document.createElement("td");
    type.textContent = doc.contentType;
    row.appendChild(type);

    const size = document.createElement("td");
    size.className = "num";
    size.textContent = formatSize(doc.sizeBytes);
    row.appendChild(size);

    const created = document.createElement("td");
    created.textContent = formatDate(doc.createdAt);
    row.appendChild(created);

    const actions = document.createElement("td");

    // A plain anchor, with no JavaScript behind it.
    //
    // The endpoint answers 302 to a short-lived presigned GET precisely so this
    // works (see DocumentResource#download). Fetching it instead would follow
    // the redirect in script and hand us bytes we would then have to turn back
    // into a download, for nothing.
    const download = document.createElement("a");
    download.href = `${CORE}/documents/${doc.id}/download`;
    download.textContent = "Download";
    actions.appendChild(download);

    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "link";
    remove.textContent = "Delete";
    remove.addEventListener("click", () => deleteDocument(doc.id, doc.filename));
    actions.appendChild(remove);

    row.appendChild(actions);
    body.appendChild(row);
  }

  el("empty").hidden = documents.length > 0;
}

/* ------------------------------------------------------------------ *
 * Actions
 * ------------------------------------------------------------------ */

async function loadIdentity() {
  try {
    const response = await api(`${CORE}/whoami`);
    const who = await response.json();

    // whoami reports what CORE sees, not what the gateway saw. If the relay
    // were misconfigured this would come back anonymous while every request
    // still succeeded, so it is worth showing rather than assuming.
    el("identity").textContent = who.name ? `Signed in as ${who.name}` : "Signed in";
    el("logout").disabled = false;
  } catch {
    el("identity").textContent = "Session unknown";
  }
}

async function loadPage(pageOrUrl = 0) {
  let url;
  if (typeof pageOrUrl === "number") {
    state.page = pageOrUrl;
    url = `${CORE}/documents?page=${pageOrUrl}&size=${PAGE_SIZE}&sort=createdAt,desc`;
  } else {
    // A URL straight from the Link header. It is same-origin and correctly
    // prefixed only because the gateway now sends X-Forwarded-Prefix; before
    // that it named https://core/api/... and was unusable from here.
    url = pageOrUrl;
    const parsed = new URL(url, window.location.origin);
    state.page = Number(parsed.searchParams.get("page") || 0);
  }

  const response = await api(url);
  const documents = await response.json();

  state.links = parseLinks(response.headers.get("Link"));
  state.total = Number(response.headers.get("X-Total-Count") || documents.length);

  renderRows(documents);

  el("total").textContent = state.total ? `(${state.total})` : "";
  el("page-label").textContent = state.total
    ? `Page ${state.page + 1} of ${Math.max(1, Math.ceil(state.total / PAGE_SIZE))}`
    : "";
  el("prev").disabled = !state.links.prev;
  el("next").disabled = !state.links.next;
}

async function upload(file) {
  // Both of these are rejected by bean validation on the way in -- @Positive on
  // sizeBytes, @NotBlank on contentType -- and a 400 for an empty file is a
  // worse answer than saying so here. A browser reports type as "" for anything
  // it does not recognise, which is common enough to be worth handling.
  if (file.size === 0) {
    throw new Error("That file is empty, and an empty upload cannot be signed.");
  }
  const contentType = file.type || "application/octet-stream";

  el("upload-status").textContent = "Requesting an upload ticket…";
  const ticketResponse = await api(`${CORE}/documents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ filename: file.name, contentType, sizeBytes: file.size }),
  });
  const ticket = await ticketResponse.json();

  el("upload-status").textContent = `Uploading ${file.name}…`;

  // Straight to object storage, not through the gateway.
  //
  // credentials "omit" on purpose: this is a different origin, the presigned
  // URL already carries its own authorisation, and the bucket's CORS policy
  // does not allow credentials -- sending them would fail the check outright.
  //
  // Content-Type comes from the TICKET, not from the File. The signature covers
  // content-length, content-type and host; sending a type even slightly
  // different from the one core signed produces a 403 from the bucket that says
  // nothing about why.
  const put = await fetch(ticket.uploadUrl, {
    method: "PUT",
    headers: { "Content-Type": ticket.contentType },
    body: file,
    credentials: "omit",
    mode: "cors",
  });
  if (!put.ok) {
    throw new Error(`The object store rejected the upload (HTTP ${put.status}).`);
  }

  // Nothing is downloadable until this lands: completion is what verifies the
  // bytes actually arrived, so a failure here leaves a document that exists but
  // is not AVAILABLE.
  el("upload-status").textContent = "Confirming…";
  await api(`${CORE}/documents/${ticket.id}/complete`, { method: "POST" });

  el("upload-status").textContent = "";
  banner(`Uploaded ${file.name}.`, "ok");
  await loadPage(0);
}

async function deleteDocument(id, filename) {
  if (!window.confirm(`Delete ${filename}?`)) return;
  try {
    await api(`${CORE}/documents/${id}`, { method: "DELETE" });
    banner(`Deleted ${filename}.`, "ok");
    // Re-request the page rather than splicing the row out: the row that moves
    // up into this page comes from the server, and guessing at it locally is
    // how a list drifts out of step with its own pagination.
    await loadPage(state.page);
  } catch (error) {
    banner(error.message, "error");
  }
}

async function logout() {
  el("logout").disabled = true;
  try {
    // Invalidates the gateway session and returns Keycloak's end-session URL.
    // Going there is what ends the SSO session too -- skipping it would leave
    // the browser able to log straight back in with no prompt, which looks
    // exactly like logout having failed.
    const response = await api("/api/logout", { method: "POST" });
    const body = await response.json();
    window.location.href = body.logoutUrl;
  } catch (error) {
    banner(error.message, "error");
    el("logout").disabled = false;
  }
}

/* ------------------------------------------------------------------ *
 * Wiring
 * ------------------------------------------------------------------ */

el("file").addEventListener("change", (event) => {
  el("upload").disabled = event.target.files.length === 0;
  banner("");
});

el("upload").addEventListener("click", async () => {
  const file = el("file").files[0];
  if (!file) return;

  el("upload").disabled = true;
  banner("");
  try {
    await upload(file);
    el("file").value = "";
  } catch (error) {
    el("upload-status").textContent = "";
    if (error.message !== "unauthenticated") banner(error.message, "error");
  } finally {
    el("upload").disabled = el("file").files.length === 0;
  }
});

el("prev").addEventListener("click", () => loadPage(state.links.prev).catch((e) => banner(e.message, "error")));
el("next").addEventListener("click", () => loadPage(state.links.next).catch((e) => banner(e.message, "error")));
el("logout").addEventListener("click", logout);

/*
 * A bfcache restore is the back button after logout: the browser can serve this
 * page from memory without asking the server, which would show a signed-in UI
 * backed by a session that no longer exists. Reloading on a persisted restore
 * forces the gateway to answer, and the gateway sends anyone without a session
 * to Keycloak.
 */
window.addEventListener("pageshow", (event) => {
  if (event.persisted) window.location.reload();
});

loadIdentity();
loadPage(0).catch((error) => {
  if (error.message !== "unauthenticated") banner(error.message, "error");
});
