#!/usr/bin/env bash
#
# A document uploaded BEFORE a rebuild is downloadable by its OWNER after one
# (T-7.3, #55; the assertion T-7.8 (#147) closed without and pointed here for).
#
# WHY "THE DATABASE CAME BACK" IS THE WRONG ASSERTION
#
# Ownership spans two systems. A document's owner is the Keycloak `sub`, which
# lives in Keycloak's Postgres schema; the document's row lives in a different
# database and its bytes live in object storage. A drill that restores Postgres,
# counts the rows and never signs in would report success against exactly the
# failure #147 is about: every row present, every object present, and nothing
# reachable, because the users were recreated with new subs.
#
# So the check is end to end and from the outside: sign in as the owning user,
# confirm the count the API reports for THEM, and pull one document's bytes
# through its presigned redirect. Anything less passes while the data is
# orphaned.
#
# TWO PHASES, BECAUSE THE CLAIM IS ABOUT SURVIVING SOMETHING
#
#   record   before the rebuild, capture what must still be true afterwards
#   verify   after it, assert exactly that
#
# The recorded file is the whole point: a verify that recomputes its own
# expectations proves nothing, because it would agree with whatever it found.
#
# Usage:
#   ./restore-verify.sh record dev state.json
#   ./restore-verify.sh verify dev state.json
#
# Credentials, same as smoke.sh:
#   CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET, read from Terraform output
#   when unset. SMOKE_USER / SMOKE_PASSWORD to use a different owner.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

MODE="${1:-}"
ENVIRONMENT="${2:-dev}"
STATE="${3:-}"

case "$MODE" in
  record | verify) ;;
  *)
    echo "usage: $0 {record|verify} <environment> <state-file>" >&2
    exit 2
    ;;
esac
[ -n "$STATE" ] || {
  echo "usage: $0 $MODE <environment> <state-file>" >&2
  exit 2
}

case "$ENVIRONMENT" in
  dev) APP="https://app-dev.xenopsoftware.com"; AUTH="https://auth-dev.xenopsoftware.com" ;;
  staging) APP="https://app-staging.xenopsoftware.com"; AUTH="https://auth-staging.xenopsoftware.com" ;;
  prod) APP="https://app.xenopsoftware.com"; AUTH="https://auth.xenopsoftware.com" ;;
  *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

REALM="xenopsbase"
CLIENT_ID="smoke-tests"
USERNAME="${SMOKE_USER:-smoke}"
# Not a secret: committed in platform/envs/dev/keycloak/realm-import.yaml, a
# public file, for a user that exists only to be logged in as.
PASSWORD="${SMOKE_PASSWORD:-smoke-dev-only}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "=================================================================="
echo " Restore verification — ${MODE} (${ENVIRONMENT})"
echo "=================================================================="
echo ""

# Cloudflare Access sits in front of the application, so without a service token
# every request is answered by a login page rather than by the application.
if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  CF_ACCESS_CLIENT_ID="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_id 2>/dev/null)"
  CF_ACCESS_CLIENT_SECRET="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_secret 2>/dev/null)"
fi
[ -n "${CF_ACCESS_CLIENT_ID:-}" ] || {
  echo "error: no Cloudflare Access service token. Set CF_ACCESS_CLIENT_ID and" >&2
  echo "       CF_ACCESS_CLIENT_SECRET, or run where the edge module is initialised." >&2
  exit 1
}
ACCESS=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")

# ---------------------------------------------------------------------------
# Sign in AS THE OWNER. This is the step a row count skips, and the one that
# fails when users have been recreated with new subs.
# ---------------------------------------------------------------------------
token_json="$(
  curl -s --max-time 30 -X POST "${AUTH}/realms/${REALM}/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=${CLIENT_ID}" \
    -d "username=${USERNAME}" -d "password=${PASSWORD}" \
    -d 'scope=openid profile email'
)"
TOKEN="$(echo "$token_json" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || {
  echo "  FAILED  sign in as ${USERNAME}" >&2
  echo "          $(echo "$token_json" | head -c 200)" >&2
  echo "" >&2
  echo "  This alone is the #147 failure: the realm came back without the user, so" >&2
  echo "  whatever is in the database belongs to nobody who can reach it." >&2
  exit 1
}
echo "  signed in as ${USERNAME}"

# The sub, so the record names WHO the documents must still belong to rather
# than trusting the username to have kept its identity (ADR-0010).
SUB="$(
  echo "$TOKEN" | cut -d. -f2 |
    sed 's/-/+/g; s/_/\//g' | awk '{ while (length($0) % 4) $0 = $0 "="; print }' |
    base64 -d 2>/dev/null | sed -n 's/.*"sub":"\([^"]*\)".*/\1/p'
)"
echo "  sub ${SUB:-<unreadable>}"

AUTHED=("${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}")

# ---------------------------------------------------------------------------
# What this owner can see, from the API rather than from the database.
# ---------------------------------------------------------------------------
headers="$WORK/headers.txt"
body="$WORK/list.json"
curl -s --max-time 30 -D "$headers" -o "$body" "${AUTHED[@]}" \
  -H 'Accept: application/json' "${APP}/services/core/api/documents?size=100"

TOTAL="$(tr -d '\r' < "$headers" | sed -n 's/^[Xx]-[Tt]otal-[Cc]ount: *//p' | tail -1)"
[ -n "$TOTAL" ] || {
  echo "  FAILED  no X-Total-Count on the document list" >&2
  exit 1
}
echo "  ${USERNAME} can see ${TOTAL} document(s)"

PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json,sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
[ -n "$PY_BIN" ] || {
  echo "error: a working python3 (or python) is required" >&2
  exit 1
}

if command -v cygpath >/dev/null 2>&1; then
  WORK_PY="$(cygpath -m "$WORK")"
  STATE_PY="$(cygpath -m "$(cd "$(dirname "$STATE")" && pwd)")/$(basename "$STATE")"
else
  WORK_PY="$WORK"
  STATE_PY="$STATE"
fi

# The OLDEST document, deliberately. It is the one most likely to predate a
# rebuild, and therefore the one whose survival actually means something.
read -r DOC_ID DOC_NAME DOC_CREATED <<EOF
$("$PY_BIN" - "$WORK_PY/list.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
if not docs:
    print("  none")
    raise SystemExit(0)
oldest = min(docs, key=lambda d: d.get("createdAt") or "")
print("%s %s %s" % (oldest["id"], oldest.get("filename", "?"), oldest.get("createdAt", "?")))
PY
)
EOF

[ -n "${DOC_ID:-}" ] && [ "$DOC_ID" != "none" ] || {
  echo "  FAILED  ${USERNAME} owns no documents, so there is nothing to prove survived" >&2
  exit 1
}
echo "  oldest document ${DOC_ID} (${DOC_NAME}) created ${DOC_CREATED}"

# -L, because download answers 302 to a presigned GET. Following it IS the test:
# a row that lists but whose object cannot be fetched is the half-restore this
# check exists to catch. curl drops the Authorization header on a cross-host
# redirect, which is what makes this safe to point at object storage.
curl -s -L --max-time 60 -o "$WORK/doc.bin" "${AUTHED[@]}" \
  "${APP}/services/core/api/documents/${DOC_ID}/download"
[ -s "$WORK/doc.bin" ] || {
  echo "  FAILED  document ${DOC_ID} listed but downloaded 0 bytes" >&2
  exit 1
}
SHA="$(sha256sum "$WORK/doc.bin" | cut -d' ' -f1)"
BYTES="$(wc -c < "$WORK/doc.bin" | tr -d ' ')"
echo "  downloaded ${BYTES} bytes, sha256 ${SHA:0:16}..."
echo ""

if [ "$MODE" = "record" ]; then
  "$PY_BIN" - "$STATE_PY" "$USERNAME" "${SUB:-}" "$TOTAL" "$DOC_ID" "$DOC_NAME" "$DOC_CREATED" "$SHA" "$BYTES" <<'PY'
import json
import sys
import datetime

path, username, sub, total, doc_id, doc_name, created, sha, size = sys.argv[1:10]
state = {
    "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "username": username,
    "sub": sub,
    "total": int(total),
    "document": {"id": int(doc_id), "filename": doc_name, "created_at": created, "sha256": sha, "bytes": int(size)},
}
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(state, handle, indent=2)
    handle.write("\n")
print("  RECORDED - %s owns %s document(s); document %s must still be downloadable" % (username, total, doc_id))
print("  %s" % path)
PY
  exit $?
fi

# ---------------------------------------------------------------------------
# verify: compare against what was recorded, not against what we just found.
# ---------------------------------------------------------------------------
[ -f "$STATE" ] || {
  echo "  FAILED  no recorded state at ${STATE}; run 'record' before the rebuild" >&2
  exit 1
}

"$PY_BIN" - "$STATE_PY" "${SUB:-}" "$TOTAL" "$SHA" "$DOC_ID" <<'PY'
import json
import sys

path, sub, total, sha, doc_id = sys.argv[1:6]
with open(path, encoding="utf-8") as handle:
    before = json.load(handle)

failures = []

sub_changed = bool(before.get("sub")) and bool(sub) and before["sub"] != sub
if sub_changed:
    failures.append(
        "the owner's sub CHANGED: %s -> %s. Every document now belongs to a user "
        "that no longer exists (ADR-0010, #147)." % (before["sub"], sub)
    )

if int(total) != int(before["total"]):
    failures.append("document count %s -> %s" % (before["total"], total))

want = before["document"]
if sha != want["sha256"]:
    failures.append("document %s bytes differ: sha256 %s -> %s" % (want["id"], want["sha256"][:16], sha[:16]))

# Not a failure on its own, but the thing that makes the result meaningful.
print("  recorded %s" % before["recorded_at"])
print("  owner    %s (%s)" % (before["username"], (before.get("sub") or "?")[:8]))
print("  expected %s document(s); oldest %s created %s" % (before["total"], want["id"], want.get("created_at")))
print("")

if failures:
    print("  FAILED - the restore did not preserve what matters:")
    for line in failures:
        print("    - %s" % line)
    print("")
    # Said only where it is true. A changed count IS visible to a row count; a
    # changed owner is not, and that is the failure this check exists for.
    if sub_changed:
        print("  A row count would have passed this: the rows are all there, and they")
        print("  belong to a user who cannot sign in (#147).")
    sys.exit(1)

print("  PASSED - the owner signed in, sees the same %s document(s), and the oldest" % before["total"])
print("           one still returns byte-identical content.")
sys.exit(0)
PY
