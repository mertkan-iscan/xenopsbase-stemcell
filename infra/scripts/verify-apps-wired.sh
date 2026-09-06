#!/usr/bin/env bash
#
# Is every Argo CD Application in platform/envs/<env>/apps/ actually deployed?
#
# THE FAILURE THIS EXISTS FOR, WHICH REPORTS SUCCESS EVERYWHERE
#
# The root Application renders platform/envs/<env> with kustomize, and
# kustomize deploys what its `resources:` list names -- not what the directory
# contains. An Application file that is committed, reviewed, correct, and
# missing from that list is deployed by nobody.
#
# Nothing reports it. `kustomize build` succeeds, the root Application is
# Synced and Healthy, every other Application is Synced and Healthy, and the
# workload simply does not exist. T-9.6 shipped apps/nats.yaml this way: the
# `messaging` namespace appeared, because namespaces.yaml IS in the list, and
# the broker it was created for was never deployed. The first evidence would
# have been core's outbox filling up with last_error set.
#
# So: the directory is the claim, the resources list is the deployment, and
# this asserts they agree.
#
# WHY BOTH DIRECTIONS
#
# A file in apps/ that nothing references is the case above. A reference to a
# file that does not exist is the opposite mistake -- a rename that missed one
# place -- and that one at least fails the render, so it is caught. It is
# checked anyway because the check costs a line and the message is better than
# kustomize's.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

failures=0

echo ""
echo "Argo CD Applications, directory against kustomization"
echo ""

for env_dir in platform/envs/*/; do
  env="$(basename "$env_dir")"
  kustomization="${env_dir}kustomization.yaml"
  apps_dir="${env_dir}apps"

  [ -d "$apps_dir" ] || continue

  if [ ! -f "$kustomization" ]; then
    echo "  FAIL  $env: has apps/ but no kustomization.yaml to deploy them from"
    failures=$((failures + 1))
    continue
  fi

  echo "  $env"

  # Every Application file present on disk must be named in the list.
  for app in "$apps_dir"/*.yaml; do
    [ -e "$app" ] || continue
    name="$(basename "$app")"
    if grep -qE "^[[:space:]]*-[[:space:]]+apps/${name}[[:space:]]*$" "$kustomization"; then
      echo "    ok      apps/$name"
    else
      echo "    FAIL    apps/$name is not in $kustomization -- committed, and deployed by nobody"
      failures=$((failures + 1))
    fi
  done

  # And every name in the list must exist on disk.
  while read -r referenced; do
    [ -n "$referenced" ] || continue
    if [ ! -f "${env_dir}${referenced}" ]; then
      echo "    FAIL    $kustomization names ${referenced}, which does not exist"
      failures=$((failures + 1))
    fi
  done < <(grep -oE "^[[:space:]]*-[[:space:]]+apps/[^[:space:]]+" "$kustomization" | sed -E 's/^[[:space:]]*-[[:space:]]+//')
done

echo ""
echo "=================================================================="
if [ "$failures" -eq 0 ]; then
  echo "PASSED - every Argo CD Application on disk is deployed by its environment."
  echo "=================================================================="
  exit 0
fi
echo "FAILED - $failures Application file(s) out of step with their kustomization."
echo "=================================================================="
exit 1
