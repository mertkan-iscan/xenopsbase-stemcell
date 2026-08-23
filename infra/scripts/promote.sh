#!/usr/bin/env bash
#
# Promotes a service image from one environment to the next, as a git operation.
#
# WHAT PROMOTION IS HERE
#
# Each environment is its own cluster with its own Argo CD, whose root
# Application points at platform/envs/<env> (see infra/terraform/cluster,
# manifests/20-root-app). So an environment IS a directory, and moving a build
# between environments is moving one pinned digest between two files.
#
# Not a tag. `main` moves and even a commit tag can be overwritten by a re-run,
# so the only reference that names the exact bytes that were tested is the
# digest. Promoting a tag would promote whatever that tag points at when the
# target cluster next pulls, which is not the thing that passed staging.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It does not build, does not push, and does not talk to any cluster. The whole
# operation is: read a digest out of one file, write it into another. That is
# what makes it reviewable, revertible, and safe to run from CI with no
# credentials at all.
#
# Usage:
#   ./promote.sh <service> <from-env> <to-env>
#   ./promote.sh gateway dev staging
#   ./promote.sh all staging prod
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

SERVICE="${1:-}"
FROM="${2:-}"
TO="${3:-}"

usage() {
  echo "usage: $0 <core|gateway|all> <from-env> <to-env>" >&2
  echo "example: $0 all dev staging" >&2
  exit 2
}

[ -n "$SERVICE" ] && [ -n "$FROM" ] && [ -n "$TO" ] || usage

case "$SERVICE" in
  core | gateway) SERVICES="$SERVICE" ;;
  all) SERVICES="core gateway" ;;
  *) usage ;;
esac

if [ "$FROM" = "$TO" ]; then
  echo "error: source and target are both '$FROM'. Promotion moves a build between" >&2
  echo "environments; promoting an environment to itself is a no-op that would still" >&2
  echo "produce a commit saying otherwise." >&2
  exit 2
fi

SRC="platform/envs/${FROM}/services/kustomization.yaml"
DST="platform/envs/${TO}/services/kustomization.yaml"

for f in "$SRC" "$DST"; do
  [ -f "$f" ] || {
    echo "error: $f does not exist." >&2
    echo "" >&2
    echo "An environment here is a directory that an Argo CD root Application points" >&2
    echo "at. If the directory is absent the environment does not exist, and there is" >&2
    echo "nothing to promote into -- see docs/runbooks/promotion.md." >&2
    exit 1
  }
done

IMAGE_PREFIX="ghcr.io/mertkan-iscan/xenopsbase-stemcell"
CHANGED=0

echo "=================================================================="
echo " Promote: ${FROM} -> ${TO}"
echo "=================================================================="

for service in $SERVICES; do
  # The digest belonging to this image, not merely the next digest in the file.
  # core and gateway no longer move together, so a positional read would
  # silently promote the wrong one the first time they diverged.
  from_digest="$(
    awk -v img="${IMAGE_PREFIX}/${service}" '
      $1 == "-" && $2 == "name:" && $3 == img { found = 1 }
      found && $1 == "digest:" { print $2; exit }
    ' "$SRC"
  )"

  to_digest="$(
    awk -v img="${IMAGE_PREFIX}/${service}" '
      $1 == "-" && $2 == "name:" && $3 == img { found = 1 }
      found && $1 == "digest:" { print $2; exit }
    ' "$DST"
  )"

  if [ -z "$from_digest" ]; then
    echo "  error: no digest for ${service} in ${SRC}" >&2
    exit 1
  fi
  if [ -z "$to_digest" ]; then
    echo "  error: no digest for ${service} in ${DST}" >&2
    exit 1
  fi

  if [ "$from_digest" = "$to_digest" ]; then
    echo "  ${service}: already at ${from_digest:0:19}… — nothing to do"
    continue
  fi

  # Replace only the digest that follows this image's name block. sed on the
  # bare digest string would also rewrite it inside a comment, and these files
  # carry the change history in comments on purpose.
  python - "$DST" "${IMAGE_PREFIX}/${service}" "$to_digest" "$from_digest" <<'PY'
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
  echo "      was ${to_digest}"
  echo "      now ${from_digest}"
  CHANGED=1
done

echo ""
if [ "$CHANGED" -eq 0 ]; then
  echo "Nothing promoted — ${TO} already matches ${FROM}."
else
  echo "Promoted into ${DST}."
  echo "Review the diff, then commit. Nothing has been deployed: the target"
  echo "cluster's Argo CD applies this when the commit reaches its branch."
fi
echo "=================================================================="

exit 0
