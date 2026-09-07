#!/usr/bin/env bash
#
# Do the realm imports fit in Keycloak's own columns?
#
# THE FAILURE THIS EXISTS FOR, WHICH IS WORSE THAN IT SOUNDS
#
# Keycloak stores a realm role's description in KEYCLOAK_ROLE.DESCRIPTION, a
# varchar(255). An import carrying a longer one does not truncate and does not
# warn: the import JOB CRASHES, with
#
#   org.hibernate.exception.DataException: could not execute batch
#   ERROR: value too long for type character varying(255)
#
# and the operator retries it for ever. That is survivable when the realm already
# exists, because --override=false means the import was a no-op anyway. It is NOT
# survivable while applying a realm change, because applying one means DELETING
# the realm first (T-9.2): the realm is gone, the import cannot put it back, and
# every login and every service call fails until somebody shortens a comment.
#
# That happened on 2026-09-07 with a 271-character description on `svc-caller`.
# This is the check that would have caught it in review.
#
# Checks every realm-import manifest under platform/envs/*/keycloak/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

echo ""
echo "Realm imports against Keycloak's column limits"
echo ""

python "$ROOT/infra/scripts/verify_realm_limits.py"
status=$?

echo ""
echo "=================================================================="
if [ "$status" -eq 0 ]; then
  echo "PASSED - every realm import fits the columns Keycloak stores it in."
else
  echo "FAILED - see above. An import that does not fit crashes the job, and"
  echo "         a crashed import cannot recreate a realm that was deleted to"
  echo "         apply the change."
fi
echo "=================================================================="
exit $status
