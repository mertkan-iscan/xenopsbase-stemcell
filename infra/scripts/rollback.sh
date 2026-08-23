#!/usr/bin/env bash
#
# Roll an environment back to the digest it was running before the current one.
#
# WHAT "PREVIOUS KNOWN-GOOD" MEANS HERE
#
# The digest this environment was pinned to before the most recent change. It
# is known-good in the only sense that matters during an incident: it was
# actually running, in this environment, and nobody was rolling back from it.
#
# That is deliberately weaker than "passed a test suite". A rollback target
# chosen by test results can be a build that never ran here; a rollback target
# chosen by history is the state you were in when things were fine.
#
# HOW IT FINDS IT
#
# Git history of the environment's kustomization, per image. Not "the commit
# before HEAD" -- core and gateway are promoted independently now, so the last
# commit touching the file may have moved the other service and left this one
# alone. Walking per-image history is what makes rolling back the gateway
# actually roll back the gateway.
#
# WHAT IT DOES NOT DO
#
# It does not deploy. Like promote.sh, it edits one line and leaves a diff for
# review; the target cluster's Argo CD applies it when the commit lands. And it
# does not touch the database -- see the runbook, because that limit is the one
# that turns a calm rollback into an outage.
#
# Usage:
#   ./rollback.sh <env> <core|gateway|all>
#   ./rollback.sh dev gateway
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
SERVICE="${2:-all}"

case "$SERVICE" in
  core | gateway) SERVICES="$SERVICE" ;;
  all) SERVICES="core gateway" ;;
  *)
    echo "usage: $0 <env> <core|gateway|all>" >&2
    exit 2
    ;;
esac

FILE="platform/envs/${ENVIRONMENT}/services/kustomization.yaml"
IMAGE_PREFIX="ghcr.io/mertkan-iscan/xenopsbase-stemcell"

[ -f "$FILE" ] || {
  echo "error: $FILE does not exist — environment '${ENVIRONMENT}' is not defined." >&2
  exit 1
}

# The digest for one image, out of a given revision of the file.
digest_at() {
  local revision="$1" image="$2" content
  if [ "$revision" = "WORKING" ]; then
    content="$(cat "$FILE")"
  else
    content="$(git show "${revision}:${FILE}" 2>/dev/null)" || return 1
  fi
  echo "$content" | awk -v img="${IMAGE_PREFIX}/${image}" '
    $1 == "-" && $2 == "name:" && $3 == img { found = 1 }
    found && $1 == "digest:" { print $2; exit }
  '
}

echo "=================================================================="
echo " Rollback: ${ENVIRONMENT}"
echo "=================================================================="

CHANGED=0

for service in $SERVICES; do
  current="$(digest_at WORKING "$service")"
  if [ -z "$current" ]; then
    echo "  error: no digest for ${service} in ${FILE}" >&2
    exit 1
  fi

  # Walk this file's history, newest first, for the first digest that differs.
  previous=""
  previous_commit=""
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    candidate="$(digest_at "$commit" "$service")" || continue
    if [ -n "$candidate" ] && [ "$candidate" != "$current" ]; then
      previous="$candidate"
      previous_commit="$commit"
      break
    fi
  done < <(git log --format=%H -- "$FILE")

  if [ -z "$previous" ]; then
    echo "  ${service}: no earlier digest in history — nothing to roll back to."
    echo "            This is the first version this environment has run."
    continue
  fi

  python - "$FILE" "${IMAGE_PREFIX}/${service}" "$current" "$previous" <<'PY'
import sys

path, image, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path, encoding="utf-8").read().split("\n")

in_block = False
replaced = False
for i, line in enumerate(lines):
    if line.strip() == f"- name: {image}":
        in_block = True
        continue
    if in_block and line.strip().startswith("- name: "):
        in_block = False
    if in_block and line.strip().startswith("digest:") and old in line:
        lines[i] = line.replace(old, new)
        replaced = True
        break

if not replaced:
    sys.stderr.write(f"error: could not rewrite the digest for {image} in {path}\n")
    sys.exit(1)

open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
PY
  # shellcheck disable=SC2181
  [ $? -eq 0 ] || exit 1

  echo "  ${service}:"
  echo "      from ${current}"
  echo "      to   ${previous}"
  echo "      which this environment ran as of $(git log -1 --format='%h %s' "$previous_commit" | cut -c1-70)"
  CHANGED=1
done

echo ""
if [ "$CHANGED" -eq 0 ]; then
  echo "Nothing rolled back."
else
  cat <<'NOTE'
Rolled back in the working tree. Commit and merge to deploy.

  THIS DOES NOT UNDO A DATABASE MIGRATION.

Flyway migrations are forward-only and already applied. Rolling the image back
runs OLDER code against a NEWER schema, which is safe for an additive migration
and is not safe for one that dropped or renamed a column. If the deploy you are
undoing included a destructive migration, the rollback is a point-in-time
restore (make backup-status, docs/runbooks/disaster-recovery.md), not this.
NOTE
fi
echo "=================================================================="

exit 0
