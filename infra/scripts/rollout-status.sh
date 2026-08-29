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

short="${EXPECTED_SHA:0:7}"

# THE REVISION IS WAITED FOR, NOT SAMPLED ONCE (T-6.7, #195)
#
# This loop used to wait only for Synced and Healthy, then compare revisions
# once, after it had exited. On a merge that is always the wrong moment to look:
# every application is ALREADY Synced and Healthy against the PREVIOUS commit, so
# the loop broke on its first iteration and the comparison ran seconds later,
# against a cluster Argo CD had not polled yet.
#
# That is not a theory about what could happen. Every push-triggered run of this
# check between 2026-08-27 and 2026-08-29 failed this way, in about 25 seconds
# of a 600-second budget, and the only green one in that window is a run where
# no cluster existed and the workflow skipped the check entirely. It had never
# once verified a deploy.
#
# The two files said so and the code did not. deploy-status.yml: "rollout-status
# .sh polls internally until this expires, so it does the waiting ... 'not yet'
# is the expected answer for the first couple of attempts and must not read as a
# failure". And the branch below printed "this is normal for the first few
# minutes after a merge. It is a failure only if it persists" -- and then exited
# non-zero without ever checking whether it persisted.
#
# So the revision is now part of the loop condition. Waiting is what distinguishes
# "has not arrived yet" from "is not going to".
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

  # Only Applications sourced from git. A Helm-sourced one reports its CHART
  # VERSION in this field -- `1.11.1`, `v1.21.1`, `88.5.0` -- not a commit. So
  # comparing every Application against a git SHA marks cert-manager, loki and
  # kube-prometheus-stack as stale forever, on a cluster that is entirely up to
  # date, which makes the whole check unusable.
  #
  # Found the first time this ran with SHA= set, immediately after fixing #193
  # so that it could run at all.
  git_apps="$(echo "$snapshot" | awk -F'\t' '$4 ~ /^[0-9a-f]{40}$/')"
  mismatched=""
  no_git_apps=""

  if [ -n "$EXPECTED_SHA" ]; then
    if [ -z "$git_apps" ]; then
      # Never pass by finding nothing to compare. That is the shape of failure
      # this repository keeps meeting: a check reporting success having checked
      # nothing at all. Kept inside the loop because an Application whose status
      # has not been populated yet reports an empty revision, and that is a
      # not-yet rather than a verdict.
      no_git_apps=1
    else
      mismatched="$(echo "$git_apps" | awk -F'\t' -v want="$short" '$1 != "" && substr($4,1,7) != want {print $1"\t"substr($4,1,7)}')"
    fi
  fi

  if [ -z "$not_ready" ] && [ -z "$mismatched" ] && [ -z "$no_git_apps" ]; then
    break
  fi

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo ""
    echo "$snapshot" | awk -F'\t' '{printf "  %-24s %-8s %-8s %s\n", $1, $2, $3, substr($4,1,8)}'
    echo ""
    # Which of the two failures this is decides what somebody does next, so it
    # is stated rather than left to be inferred from a generic timeout.
    if [ -n "$not_ready" ]; then
      echo "  NOT READY after ${TIMEOUT}s:"
      echo "$not_ready" | awk -F'\t' '{printf "    %-24s %-12s %s\n", $1, $2, $3}'
    fi
    if [ -n "$no_git_apps" ]; then
      echo "  no git-sourced application reported a revision — nothing was compared"
    fi
    if [ -n "$mismatched" ]; then
      echo "  EXPECTED revision ${short} after ${TIMEOUT}s, but:"
      echo "$mismatched" | awk -F'\t' '{printf "    %-24s is at %s\n", $1, $2}'
      echo ""
      echo "  Argo CD polls roughly every 3 minutes, so this waited well past"
      echo "  normal lag. The commit has not arrived rather than not arrived yet."
    fi
    echo ""
    echo "=================================================================="
    if [ -n "$not_ready" ]; then
      echo "ROLLOUT FAILED — see above."
    else
      echo "ROLLOUT INCOMPLETE — healthy, but not running the expected commit."
    fi
    echo "=================================================================="
    exit 1
  fi

  waiting_for=""
  [ -n "$not_ready" ] && waiting_for="$(echo "$not_ready" | wc -l | tr -d ' ') application(s) not ready"
  if [ -n "$mismatched" ]; then
    [ -n "$waiting_for" ] && waiting_for="${waiting_for}, "
    waiting_for="${waiting_for}$(echo "$mismatched" | wc -l | tr -d ' ') not yet at ${short}"
  fi
  [ -n "$no_git_apps" ] && waiting_for="no application has reported a revision yet"
  echo "  waiting (${waiting_for})…"
  sleep 10
done

echo ""
echo "$snapshot" | awk -F'\t' '{printf "  %-24s %-8s %-8s %s\n", $1, $2, $3, substr($4,1,8)}'
echo ""

if [ -n "$EXPECTED_SHA" ]; then
  echo "  revision ${short}: every git-sourced application matches"
  echo "  (Helm-sourced applications report a chart version and are not compared)"
fi

echo "=================================================================="
echo "ROLLOUT OK — every application Synced and Healthy${EXPECTED_SHA:+ at ${short}}."
echo "=================================================================="

exit 0
