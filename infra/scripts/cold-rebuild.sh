#!/usr/bin/env bash
#
# Destroy everything and build it back, measured, and prove the data survived
# (T-7.2).
#
# WHY THIS IS THE KEYSTONE
#
# In an ephemeral model this one path is simultaneously the deploy path, the
# disaster-recovery procedure, and the only evidence that ADR-0002's
# durable-state boundary is real rather than asserted. Everything else in this
# repository is downstream of it working.
#
# WHAT IT PROVES THAT THE SMOKE SUITE CANNOT
#
# `smoke.sh` creates a document and deletes it inside one run, so it would pass
# perfectly against an environment that had just lost every document it ever
# held. This seeds a document BEFORE the destroy and reads it back AFTER the
# rebuild, byte for byte, through a login as the same user.
#
# That last part is the subtle one. Documents are owned by the Keycloak `sub`.
# The realm is rebuilt from a file on every cold start, so if Keycloak minted
# new user ids the rows would survive and become unreachable -- intact,
# owned by nobody, and invisible to every health check. ADR-0010 pins the ids
# for exactly this reason; this is what tests that they are pinned.
#
# WHAT IT DOES NOT DO
#
# It does not rebuild the OS snapshot. That is durable state in ADR-0002's
# sense -- built once, reused by every rebuild, untouched by `make down` -- so
# a rebuild with it present is the warm path and the everyday one. The snapshot
# build is measured separately and added, rather than collapsed into one figure
# that describes neither case. Pass SNAPSHOT=1 to include it.
#
# Usage:
#   ./cold-rebuild.sh [env]
#   SNAPSHOT=1 ./cold-rebuild.sh dev
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
BUILD_SNAPSHOT="${SNAPSHOT:-0}"

case "$ENVIRONMENT" in
  dev) APP="https://app-dev.xenopsoftware.com"; AUTH="https://auth-dev.xenopsoftware.com" ;;
  staging) APP="https://app-staging.xenopsoftware.com"; AUTH="https://auth-staging.xenopsoftware.com" ;;
  prod) APP="https://app.xenopsoftware.com"; AUTH="https://auth.xenopsoftware.com" ;;
  *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

REALM="xenopsbase"
CLIENT_ID="smoke-tests"
USERNAME="${SMOKE_USER:-smoke}"
PASSWORD="${SMOKE_PASSWORD:-smoke-dev-only}"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  CF_ACCESS_CLIENT_ID="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_id 2>/dev/null)"
  CF_ACCESS_CLIENT_SECRET="$(cd infra/terraform/edge && terraform output -raw access_service_token_client_secret 2>/dev/null)"
fi
[ -n "${CF_ACCESS_CLIENT_ID:-}" ] || { echo "error: no Cloudflare Access service token." >&2; exit 1; }
export CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET
ACCESS=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")

token() {
  curl -s --max-time 30 -X POST "${AUTH}/realms/${REALM}/protocol/openid-connect/token" \
    -d grant_type=password -d "client_id=${CLIENT_ID}" \
    -d "username=${USERNAME}" -d "password=${PASSWORD}" -d 'scope=openid profile email' |
    sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

banner() {
  echo ""
  echo "=================================================================="
  echo " $1"
  echo "=================================================================="
}

DRILL_START="$(date +%s)"

# ---------------------------------------------------------------------------
banner "Phase 0 — seed a document that must survive"
# ---------------------------------------------------------------------------
# THE DRILL CANNOT START ON A HALF-TORN-DOWN ENVIRONMENT, and it has to say so
# (T-7.10, #291).
#
# This used to be one line: "cannot log in; is dev up?" -- which is the right
# question and no help at all. The situation that produces it is not usually a
# cluster that was never built; it is a PREVIOUS run of this drill that failed
# after phase 2. Phase 2 deletes the PersistentVolumeClaims early, so Postgres
# is gone before anything downstream can fail, and the drill has then broken the
# thing it needs to start.
#
# That happened twice in one afternoon -- once to a Hetzner 503 mid-destroy,
# once to a stalled subnet deletion -- and each time recovery was improvised.
# The recovery is one command and it belongs here rather than in somebody's
# memory.
TOKEN="$(token)"
if [ -z "$TOKEN" ]; then
  echo "  error: cannot log in to ${ENVIRONMENT}, so there is nothing to seed." >&2
  echo "" >&2
  if hcloud server list -o noheader -o columns=name 2>/dev/null | grep -q "^${CLUSTER_NAME:-xenopsbase}-${ENVIRONMENT}"; then
    echo "  Servers exist, so this is most likely a teardown that stopped partway:" >&2
    echo "  phase 2 deletes the PVCs first, so the database goes before anything" >&2
    echo "  else does. The environment has to be whole before the drill can" >&2
    echo "  destroy it meaningfully." >&2
  else
    echo "  No servers for ${ENVIRONMENT}. The environment is not built." >&2
  fi
  echo "" >&2
  echo "    make down ENV=${ENVIRONMENT} SKIP_BACKUP_CHECK=1 && make up ENV=${ENVIRONMENT}" >&2
  echo "" >&2
  echo "  SKIP_BACKUP_CHECK is right here and only here: a half-destroyed" >&2
  echo "  cluster has no database to archive from, so the gate would refuse a" >&2
  echo "  teardown that is the only way forward." >&2
  exit 1
fi

CONTENT="cold-rebuild drill $(date -u +%Y-%m-%dT%H:%M:%SZ) $RANDOM"
echo -n "$CONTENT" > "$WORK/seed.txt"
SIZE="$(wc -c < "$WORK/seed.txt" | tr -d ' ')"
SEED_SHA="$(sha256sum "$WORK/seed.txt" | cut -d' ' -f1)"
FILENAME="cold-rebuild-$(date -u +%Y%m%dT%H%M%SZ).txt"

ticket="$(curl -s --max-time 30 -X POST "${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"filename\":\"${FILENAME}\",\"contentType\":\"text/plain\",\"sizeBytes\":${SIZE}}" \
  "${APP}/services/core/api/documents")"
SEED_ID="$(echo "$ticket" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
UPLOAD_URL="$(echo "$ticket" | sed -n 's/.*"uploadUrl":"\([^"]*\)".*/\1/p')"
[ -n "$SEED_ID" ] || { echo "  error: no upload ticket: $(echo "$ticket" | head -c 200)" >&2; exit 1; }

curl -s --max-time 60 -X PUT -H 'Content-Type: text/plain' --data-binary "@$WORK/seed.txt" "$UPLOAD_URL" >/dev/null
curl -s --max-time 30 -X POST "${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${APP}/services/core/api/documents/${SEED_ID}/complete" >/dev/null

echo "  document ${SEED_ID}  ${FILENAME}"
echo "  sha256    ${SEED_SHA}"
echo ""
echo "  This is the whole point. It must come back byte for byte, owned by the"
echo "  same user, after everything below has been destroyed."

# Backups must be recoverable BEFORE the destroy, not discovered afterwards.
banner "Phase 1 — backups are recoverable"
bash infra/scripts/verify-backup.sh "$ENVIRONMENT" || {
  echo "  Refusing to destroy: the database is not provably recoverable." >&2
  exit 1
}

# ---------------------------------------------------------------------------
banner "Phase 2 — destroy"
# ---------------------------------------------------------------------------
DOWN_START="$(date +%s)"
make down ENV="$ENVIRONMENT" || { echo "  DESTROY FAILED" >&2; exit 1; }
DOWN_END="$(date +%s)"
DOWN=$(( DOWN_END - DOWN_START ))
echo "  destroy: ${DOWN}s"

# ---------------------------------------------------------------------------
if [ "$BUILD_SNAPSHOT" = "1" ]; then
  banner "Phase 2b — rebuild the OS snapshot (the genuinely cold path)"
  SNAP_START="$(date +%s)"
  make snapshot || { echo "  SNAPSHOT BUILD FAILED" >&2; exit 1; }
  SNAP=$(( $(date +%s) - SNAP_START ))
  echo "  snapshot: ${SNAP}s"
else
  SNAP=0
  echo ""
  echo "  (OS snapshot kept — warm path. SNAPSHOT=1 to rebuild it and measure the cold one.)"
fi

# ---------------------------------------------------------------------------
banner "Phase 3 — build it back"
# ---------------------------------------------------------------------------
UP_START="$(date +%s)"
make up ENV="$ENVIRONMENT" || { echo "  REBUILD FAILED" >&2; exit 1; }
UP_END="$(date +%s)"
UP=$(( UP_END - UP_START ))
echo "  rebuild: ${UP}s"

# ---------------------------------------------------------------------------
banner "Phase 4 — does it work at all"
# ---------------------------------------------------------------------------
SMOKE_START="$(date +%s)"
bash infra/scripts/smoke.sh "$ENVIRONMENT" || { echo "  SMOKE FAILED after rebuild" >&2; exit 1; }
SMOKE=$(( $(date +%s) - SMOKE_START ))

# ---------------------------------------------------------------------------
banner "Phase 5 — did the data survive"
# ---------------------------------------------------------------------------
TOKEN="$(token)"
[ -n "$TOKEN" ] || { echo "  error: cannot log in after the rebuild." >&2; exit 1; }

curl -s -L --max-time 60 -o "$WORK/restored.txt" \
  "${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${APP}/services/core/api/documents/${SEED_ID}/download"

RESTORED_SHA="$(sha256sum "$WORK/restored.txt" 2>/dev/null | cut -d' ' -f1)"

SURVIVED=1
if [ "$RESTORED_SHA" = "$SEED_SHA" ]; then
  echo "  PASS  document ${SEED_ID} came back byte for byte"
  echo "        ${RESTORED_SHA}"
  SURVIVED=0
else
  echo "  FAIL  document ${SEED_ID} did not survive"
  echo "        expected ${SEED_SHA}"
  echo "        got      ${RESTORED_SHA:-<nothing>}"
  echo ""
  echo "  If the download 404s rather than returning wrong bytes, the row may"
  echo "  have survived while its OWNER did not: documents are owned by the"
  echo "  Keycloak sub, and a realm that mints new user ids on rebuild orphans"
  echo "  every row it ever owned. See ADR-0010."
fi

# Tidy up so repeated drills do not accumulate.
curl -s -o /dev/null --max-time 30 -X DELETE "${ACCESS[@]}" -H "Authorization: Bearer ${TOKEN}" \
  "${APP}/services/core/api/documents/${SEED_ID}"

TOTAL=$(( $(date +%s) - DRILL_START ))
REBUILD_ONLY=$(( DOWN + SNAP + UP + SMOKE ))

banner "Result"
printf "  %-38s %6ss\n" "destroy" "$DOWN"
[ "$SNAP" -gt 0 ] && printf "  %-38s %6ss\n" "OS snapshot build" "$SNAP"
printf "  %-38s %6ss\n" "rebuild to serving" "$UP"
printf "  %-38s %6ss\n" "smoke suite" "$SMOKE"
printf "  %-38s %6ss\n" "----" ""
printf "  %-38s %6ss  (%s min)\n" "destroy to verified" "$REBUILD_ONLY" "$(( REBUILD_ONLY / 60 ))"
printf "  %-38s %6ss\n" "whole drill including seeding" "$TOTAL"
echo ""
echo "  ADR-0002 target, cold rebuild: 3600s (60 min)"
if [ "$REBUILD_ONLY" -le 3600 ]; then
  echo "  WITHIN TARGET by $(( 3600 - REBUILD_ONLY ))s"
else
  echo "  OVER TARGET by $(( REBUILD_ONLY - 3600 ))s"
fi
echo "=================================================================="

exit "$SURVIVED"
