#!/usr/bin/env bash
#
# Did the commit that was promoted actually reach the cluster, and is it healthy?
#
# WHY THIS IS NOT A CI JOB
#
# T-6.3 asked for rollout status surfaced in CI. It cannot be, today. The
# Kubernetes API is a tailnet address on a port that is closed to the public
# internet (T-1.5, docs/runbooks/network-access.md):
#
#   server: https://xenopsbase-dev-control-plane-*.tail894b71.ts.net:6443
#
# A GitHub-hosted runner is not on the tailnet, so no workflow can ask Argo CD
# anything. Making it possible means either joining runners to the tailnet or
# having Argo CD push status outward, and both are real decisions rather than
# plumbing -- tracked separately.
#
# So this runs where cluster access already exists: a machine with the
# kubeconfig. It is the same question CI would ask, asked from somewhere that
# can reach the answer.
#
# WHAT IT ASSERTS
#
# That every Argo CD Application is Synced AND Healthy, and -- the part that
# matters -- that the revision Argo has synced is the commit you expect. An
# Application can be Synced and Healthy against a commit from an hour ago,
# which is exactly what a promotion that never arrived looks like.
#
# Usage:
#   ./rollout-status.sh [env] [expected-git-sha]
#   ./rollout-status.sh dev
#   ./rollout-status.sh dev 2e44a9e
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
EXPECTED_SHA="${2:-}"
TIMEOUT="${ROLLOUT_TIMEOUT:-300}"

# THIS project's kubeconfig, unconditionally -- the same rule wait-for-stack.sh
# already states and for the same reason. An inherited KUBECONFIG is ignored.
#
# Written as ${KUBECONFIG:-...} first, again, and it pointed this script at an
# unrelated project's cluster on the very first run, because the development
# machine carries a user-level KUBECONFIG. It reported "cannot reach the
# cluster" about a cluster that was healthy throughout.
#
# The worse version is the one that did not happen: if the inherited cluster is
# RUNNING, a rollout check reports someone else's applications as Synced and
# Healthy and exits 0 -- a green tick for a deploy that never landed.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

[ -f "$KUBECONFIG" ] || {
  echo "error: no kubeconfig at $KUBECONFIG" >&2
  echo "Run: make kubeconfig ENV=${ENVIRONMENT}" >&2
  exit 1
}

# Say which cluster is being asked. A status report that does not name its
# subject is one nobody can check.
SERVER="$(grep -oE '"server": *"[^"]+"' "$KUBECONFIG" | head -1 | sed 's/.*"server": *"//; s/"$//')"

echo "=================================================================="
echo " Rollout status: ${ENVIRONMENT}"
echo " ${SERVER}"
echo "=================================================================="

kubectl get namespace argocd >/dev/null 2>&1 || {
  echo "  error: cannot reach the cluster, or Argo CD is not installed." >&2
  echo "  If this is a laptop, check you are on the tailnet." >&2
  exit 1
}

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  # One call, then parse. Asking per-application races a sync that changes
  # state between calls, and produces a report that was never true at once.
  snapshot="$(
    kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.sync.revision}{"\n"}{end}' 2>/dev/null
  )"

  if [ -z "$snapshot" ]; then
    echo "  error: no Argo CD Applications found." >&2
    exit 1
  fi

  not_ready="$(echo "$snapshot" | awk -F'\t' '$2 != "Synced" || $3 != "Healthy"')"

  if [ -z "$not_ready" ]; then
    break
  fi

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo ""
    echo "  NOT READY after ${TIMEOUT}s:"
    echo "$not_ready" | awk -F'\t' '{printf "    %-24s %-12s %s\n", $1, $2, $3}'
    echo ""
    echo "=================================================================="
    echo "ROLLOUT FAILED — see above."
    echo "=================================================================="
    exit 1
  fi

  echo "  waiting ($(echo "$not_ready" | wc -l | tr -d ' ') application(s) not ready)…"
  sleep 10
done

echo ""
echo "$snapshot" | awk -F'\t' '{printf "  %-24s %-8s %-8s %s\n", $1, $2, $3, substr($4,1,8)}'
echo ""

FAILED=0
if [ -n "$EXPECTED_SHA" ]; then
  # The check that stops this being a green tick with no content. Synced and
  # Healthy says the cluster matches SOME revision; only this says it matches
  # the one that was promoted.
  short="${EXPECTED_SHA:0:7}"
  mismatched="$(echo "$snapshot" | awk -F'\t' -v want="$short" 'substr($4,1,7) != want {print $1"\t"substr($4,1,7)}')"
  if [ -n "$mismatched" ]; then
    echo "  EXPECTED revision ${short}, but:"
    echo "$mismatched" | awk -F'\t' '{printf "    %-24s is at %s\n", $1, $2}'
    echo ""
    echo "  Argo CD polls rather than being notified, so this is normal for the"
    echo "  first few minutes after a merge. It is a failure only if it persists."
    FAILED=1
  else
    echo "  revision ${short}: every application matches"
  fi
fi

echo "=================================================================="
if [ "$FAILED" -eq 0 ]; then
  echo "ROLLOUT OK — every application Synced and Healthy."
else
  echo "ROLLOUT INCOMPLETE — healthy, but not yet running the expected commit."
fi
echo "=================================================================="

exit "$FAILED"
