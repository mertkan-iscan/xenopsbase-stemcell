#!/usr/bin/env bash
#
# End-to-end smoke suite against a DEPLOYED environment (T-5.5).
#
# WHAT MAKES THIS DIFFERENT FROM THE INTEGRATION TESTS
#
# The integration suite runs the application against real dependencies in
# containers, on one machine, under the test profile. Everything it proves is
# true of a JVM. This proves things that are only true of the deployed system:
#
#   - Cloudflare Access is in front and a service token gets through it
#   - the tunnel reaches ingress-nginx, which reaches the gateway
#   - the gateway's OIDC issuer resolves to the deployed Keycloak
#   - core is reachable through the gateway's /services/core route
#   - a presigned URL points at real object storage and the bytes survive it
#   - application-prod.yml is the configuration actually running
#
# None of those are exercised by anything else. `docs/testing.md` names this as
# the layer that does not exist; this is it.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It does not install, deploy, or repair anything. It answers one question --
# does this environment work -- and answers it the way a user would, from
# outside, over the public internet.
#
# Usage:
#   ./smoke.sh [env]
#
# Credentials:
#   CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET  read from Terraform output
#   when unset. Cloudflare Access sits in front of the application (T-8.6), so
#   without these every request is answered by a login page rather than by the
#   application.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"

case "$ENVIRONMENT" in
  dev) APP="https://app-dev.xenopsoftware.com"; AUTH="https://auth-dev.xenopsoftware.com" ;;
  staging) APP="https://app-staging.xenopsoftware.com"; AUTH="https://auth-staging.xenopsoftware.com" ;;
  prod) APP="https://app.xenopsoftware.com"; AUTH="https://auth.xenopsoftware.com" ;;
  *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

REALM="xenopsbase"
CLIENT_ID="smoke-tests"
USERNAME="${SMOKE_USER:-smoke}"
# Not a secret. It is committed in platform/envs/dev/keycloak/realm-import.yaml,
# which is a public file, for a user that exists only to be logged in as.
PASSWORD="${SMOKE_PASSWORD:-smoke-dev-only}"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASSED=0
FAILED=0

ok()   { echo "  PASS  $1"; PASSED=$((PASSED + 1)); }
# Detail is truncated and flattened deliberately. An unauthenticated request
# gets an HTML error page back, and dumping it buries every other result under
# a page of markup -- which is how a failing suite becomes one nobody reads.
bad() {
  echo "  FAIL  $1"
  echo "        $(printf '%s' "$2" | tr -d '
' | tr '
' ' ' | tr -s ' ' | cut -c1-160)"
  FAILED=$((FAILED + 1))
}

echo "=================================================================="
echo " Smoke: ${ENVIRONMENT}"
echo " ${APP}"
echo "=================================================================="

# ---------------------------------------------------------------------------
# Credentials for Cloudflare Access
# ---------------------------------------------------------------------------
if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  if [ -d infra/terraform/edge/.terraform ]; then
    CF_ACCESS_CLIENT_ID="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_id 2>/dev/null)"
    CF_ACCESS_CLIENT_SECRET="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_secret 2>/dev/null)"
  fi
fi

if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  echo "  error: no Cloudflare Access service token." >&2
  echo "  Set CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET, or run from a" >&2
  echo "  machine with the edge module initialised." >&2
  exit 1
fi

# Every request to the application carries these. Requests to Keycloak do not:
# auth-* is deliberately NOT behind Access, because putting the identity
# provider behind another identity provider breaks the login it exists to serve.
ACCESS=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")

START="$(date +%s)"

# The service token is checked before anything else, and fatally. Without it
# Cloudflare answers every subsequent request with a redirect to a login page,
# so all six later checks fail with an HTML body that says nothing about the
# actual cause -- six confusing failures instead of one clear one.
probe="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${ACCESS[@]}" "${APP}/management/health")"
if [ "$probe" = "302" ] || [ "$probe" = "000" ]; then
  echo "  error: the Cloudflare Access service token was rejected (probe returned ${probe})." >&2
  echo "  Everything below would fail with a login page rather than a result." >&2
  echo "" >&2
  echo "  Check CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET, or re-read them:" >&2
  echo "    cd infra/terraform/edge && terraform output access_service_token_client_id" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. The edge is up and Access is in front
# ---------------------------------------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${APP}/")"
if [ "$code" = "302" ] || [ "$code" = "200" ]; then
  ok "the edge answers (${code})"
else
  bad "the edge answers" "expected 302 or 200, got ${code}"
fi

# Without the service token the application must not be reachable at all. If
# this ever returns the application, Access has stopped protecting it and T-8.6
# is undone -- which nothing else would notice.
noauth="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 20 "${APP}/services/core/api/documents")"
case "$noauth" in
  *cloudflareaccess.com*) ok "Access refuses a request with no service token" ;;
  *) bad "Access refuses a request with no service token" "redirect was '${noauth:-<none>}'" ;;
esac

# ---------------------------------------------------------------------------
# 2. Login: a real token from the deployed Keycloak
# ---------------------------------------------------------------------------
token_json="$(
  curl -s --max-time 30 -X POST "${AUTH}/realms/${REALM}/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=${CLIENT_ID}" \
    -d "username=${USERNAME}" -d "password=${PASSWORD}" \
    -d 'scope=openid profile email'
)"
TOKEN="$(echo "$token_json" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"

if [ -n "$TOKEN" ]; then
  ok "login as ${USERNAME} against the deployed Keycloak"
else
  bad "login as ${USERNAME}" "$(echo "$token_json" | head -c 200)"
  echo ""
  echo "Nothing below can run without a token."
  echo "=================================================================="
  exit 1
fi

AUTHED=("${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}")

# ---------------------------------------------------------------------------
# 3. An unauthenticated API call is refused visibly
# ---------------------------------------------------------------------------
# 401 with a problem document, not a 302 to a login page that a client would
# follow and read as success (T-3.8). Asserted here because the deployed edge
# is the one place the entry point, the ingress and Access all interact.
code="$(curl -s -o "$WORK/unauth.json" -w '%{http_code}' --max-time 20 \
  "${ACCESS[@]}" -H 'Accept: application/json' "${APP}/services/core/api/documents")"
if [ "$code" = "401" ]; then
  ok "an unauthenticated API call is 401, not a redirect"
else
  bad "an unauthenticated API call is 401" "got ${code}: $(head -c 160 "$WORK/unauth.json")"
fi

# ---------------------------------------------------------------------------
# 4. An authenticated call reaches core through the gateway
# ---------------------------------------------------------------------------
code="$(curl -s -o "$WORK/list.json" -w '%{http_code}' --max-time 30 \
  "${AUTHED[@]}" "${APP}/services/core/api/documents")"
if [ "$code" = "200" ]; then
  ok "an authenticated call reaches core through the gateway"
else
  bad "an authenticated call reaches core" "got ${code}: $(head -c 200 "$WORK/list.json")"
fi

# ---------------------------------------------------------------------------
# 4b. The absolute URLs core hands back point at the PUBLIC hostname over https
#
# This is the check that was missing when it was most needed. T-3.15 narrowed
# `trusted-proxies`, the gateway stopped forwarding X-Forwarded-* to core, and
# core built its pagination Link header from its own in-cluster address:
#
#   <http://core:8081/api/documents?page=1&size=2>; rel="next"
#
# The whole suite passed. Every check above still passes with the forwarded
# headers stripped entirely -- verified deliberately on 2026-08-24 -- because
# nothing looked at a URL core generated. The regression was caught by a human
# reading a header, and reverted a day later (#170).
#
# A client following that Link leaves the public hostname for a name that does
# not resolve outside the cluster, over plaintext. That is a broken API
# contract (T-3.8) and it is invisible to every other assertion here.
#
# Paged deliberately: RFC 8288 Link headers only appear when there is another
# page, so `size=1` is what makes the header exist at all.
links="$(curl -s -D - -o /dev/null --max-time 30   "${AUTHED[@]}" "${APP}/services/core/api/documents?page=0&size=1"   | tr -d '' | sed -n 's/^[Ll]ink: //p')"

if [ -z "$links" ]; then
  # Not a failure: with fewer than two documents there is no next page and no
  # header. Saying so is better than a pass that inspected nothing.
  ok "pagination Link header absent (fewer than 2 documents to page over)"
elif printf '%s' "$links" | grep -q "http://"; then
  bad "core builds absolute https URLs" "Link contains a plaintext URL: ${links}"
elif printf '%s' "$links" | grep -q "${APP#https://}"; then
  ok "core builds absolute https URLs at the public hostname"
else
  bad "core builds absolute https URLs" "Link does not name ${APP#https://}: ${links}"
fi

# ---------------------------------------------------------------------------
# 5. Upload, download, and the bytes survive
# ---------------------------------------------------------------------------
CONTENT="smoke ${ENVIRONMENT} $(date -u +%Y-%m-%dT%H:%M:%SZ) $RANDOM"
echo -n "$CONTENT" > "$WORK/upload.txt"
SIZE="$(wc -c < "$WORK/upload.txt" | tr -d ' ')"
FILENAME="smoke-$(date -u +%Y%m%dT%H%M%SZ).txt"

ticket="$(
  curl -s --max-time 30 -X POST "${AUTHED[@]}" -H 'Content-Type: application/json' \
    -d "{\"filename\":\"${FILENAME}\",\"contentType\":\"text/plain\",\"sizeBytes\":${SIZE}}" \
    "${APP}/services/core/api/documents"
)"
DOC_ID="$(echo "$ticket" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
UPLOAD_URL="$(echo "$ticket" | sed -n 's/.*"uploadUrl":"\([^"]*\)".*/\1/p')"

if [ -n "$DOC_ID" ] && [ -n "$UPLOAD_URL" ]; then
  ok "upload ticket issued (document ${DOC_ID})"
else
  bad "upload ticket issued" "$(echo "$ticket" | head -c 200)"
  echo ""
  echo "=================================================================="
  exit 1
fi

# Straight to object storage. NO Access headers and NO bearer: this URL is
# presigned and goes to Hetzner, not through the edge -- which is the whole
# point of the design (bytes never transit the JVM), and is worth proving
# against the real store rather than MinIO.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X PUT \
  -H 'Content-Type: text/plain' --data-binary "@$WORK/upload.txt" "$UPLOAD_URL")"
if [ "$code" = "200" ] || [ "$code" = "204" ]; then
  ok "bytes PUT directly to object storage (${code})"
else
  bad "bytes PUT directly to object storage" "got ${code}"
fi

code="$(curl -s -o "$WORK/complete.json" -w '%{http_code}' --max-time 30 -X POST \
  "${AUTHED[@]}" "${APP}/services/core/api/documents/${DOC_ID}/complete")"
if [ "$code" = "200" ]; then
  ok "upload completed and recorded"
else
  bad "upload completed" "got ${code}: $(head -c 200 "$WORK/complete.json")"
fi

# -L, because download answers 302 to a presigned GET. Following it is the test.
curl -s -L --max-time 60 -o "$WORK/download.txt" \
  "${AUTHED[@]}" "${APP}/services/core/api/documents/${DOC_ID}/download"

if cmp -s "$WORK/upload.txt" "$WORK/download.txt"; then
  ok "downloaded bytes are identical to what was uploaded"
else
  bad "downloaded bytes are identical" "got $(wc -c < "$WORK/download.txt" | tr -d ' ') bytes, expected ${SIZE}"
fi

# ---------------------------------------------------------------------------
# 6. Clean up after itself
# ---------------------------------------------------------------------------
# A smoke suite that leaves rows and objects behind turns a health check into a
# slow storage leak, and makes the next run's "list documents" less meaningful
# every time.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X DELETE \
  "${AUTHED[@]}" "${APP}/services/core/api/documents/${DOC_ID}")"
if [ "$code" = "204" ] || [ "$code" = "200" ]; then
  ok "the document is deleted again"
else
  bad "the document is deleted again" "got ${code} — document ${DOC_ID} was left behind"
fi

ELAPSED=$(( $(date +%s) - START ))

echo ""
echo "=================================================================="
if [ "$FAILED" -eq 0 ]; then
  echo "SMOKE PASSED — ${PASSED} checks in ${ELAPSED}s against ${ENVIRONMENT}."
else
  echo "SMOKE FAILED — ${FAILED} of $((PASSED + FAILED)) checks, in ${ELAPSED}s."
fi
echo "=================================================================="

[ "$FAILED" -eq 0 ] || exit 1
exit 0
