#!/usr/bin/env bash
#
# Nothing in this cluster runs BestEffort, and the thing that keeps that true is
# still in place (T-2.8 #22, T-2.25 #339).
#
# WHY THIS EXISTS SEPARATELY FROM verify-resources.sh
#
# That check reads the MANIFESTS and asserts that every workload this repository
# owns declares requests and a memory limit. It runs in CI, where there is no
# cluster, and it says in its own header why it stops at what we own: the rest
# are third-party chart sidecars nobody here can fix, and a check that fails for
# reasons nobody can act on is a check people learn to skip.
#
# T-2.25 removed that excuse for one specific property. A LimitRange in
# kube-system, cnpg-system and system-upgrade now gives a request to anything
# created without one, including manifests the kube-hetzner module renders and
# this repository cannot edit. So "no pod runs BestEffort" became true of the
# whole cluster rather than of our corner of it -- and a property that is true
# and unchecked is a property that stops being true quietly.
#
# It asks the CLUSTER because that is where the answer lives. A LimitRange
# defaults at admission, so whether it worked is a fact about running pods and
# not about YAML.
#
# WHAT IT GATES ON, AND WHAT IT MERELY REPORTS
#
# Gates on two things:
#
#   no Running pod is BestEffort
#   the three LimitRanges exist
#
# The second is not redundant. Deleting a LimitRange changes nothing about pods
# already running, so the first check would keep passing for days while the
# guarantee was gone -- until something restarted and came back BestEffort, at
# the least convenient moment. This is the shape of failure this repository
# keeps finding, so the mechanism is checked as well as the outcome.
#
# REPORTS, and deliberately does not gate on, how many containers have no memory
# LIMIT. T-2.8's third criterion asks for "requests and limits" on every
# workload. Requests are a correctness property -- without one a pod is invisible
# to the scheduler and first to be evicted. A limit is a tuning decision, this
# project has twice declined to make it universal (T-2.15 refuses CPU limits
# outright; platform/envs/dev/limits.yaml refuses a default memory limit because
# it would turn a scheduling fix into a source of OOMKills), and gating on one
# here would demand the opposite of a decision that was made.
#
# Usage:
#   export KUBECONFIG="$PWD/infra/terraform/cluster/kubeconfig"
#   ./verify-qos.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

command -v kubectl >/dev/null 2>&1 || {
  echo "error: kubectl is required" >&2
  exit 1
}

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

# The namespaces whose manifests this repository does not write, and which
# therefore depend on a LimitRange rather than on authorship. Kept in step with
# platform/envs/dev/limits.yaml by this check failing when they disagree.
GUARDED="kube-system cnpg-system system-upgrade"

echo "=================================================================="
echo " QoS: nothing BestEffort, and the floor that keeps it that way"
echo "=================================================================="
echo ""

FAILED=0

if ! kubectl version -o json >/dev/null 2>&1; then
  echo "error: no cluster. Point KUBECONFIG at this project's:" >&2
  echo "  export KUBECONFIG=\"\$PWD/infra/terraform/cluster/kubeconfig\"" >&2
  echo "The shell's own KUBECONFIG is usually a stale local cluster." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "The floor:"
for ns in $GUARDED; do
  mem="$(kubectl get limitrange default-requests -n "$ns" \
    -o jsonpath='{.spec.limits[0].defaultRequest.memory}' 2>/dev/null)"
  cpu="$(kubectl get limitrange default-requests -n "$ns" \
    -o jsonpath='{.spec.limits[0].defaultRequest.cpu}' 2>/dev/null)"
  if [ -z "$mem" ]; then
    printf '  %-16s MISSING — nothing stops the next pod here being BestEffort\n' "$ns"
    FAILED=1
  else
    printf '  %-16s %s / %s\n' "$ns" "$cpu" "$mem"
  fi
done
echo ""

# ---------------------------------------------------------------------------
# Captured to a file rather than piped. `python - <<HEREDOC` takes the SCRIPT on
# stdin, so a pipe into it is silently discarded and json.load reads an empty
# string -- which is how the first version of this failed, with a traceback that
# named the JSON decoder and not the mistake.
PODS="$(mktemp)"
trap 'rm -f "$PODS"' EXIT INT TERM
kubectl get pods -A -o json >"$PODS" 2>/dev/null

"$PY_BIN" - "$PODS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

qos = {}
besteffort = []
no_limit = 0
running = 0

for pod in data.get("items", []):
    if pod["status"].get("phase") != "Running":
        continue
    running += 1
    klass = pod["status"].get("qosClass", "Unknown")
    qos[klass] = qos.get(klass, 0) + 1
    if klass == "BestEffort":
        besteffort.append("%s/%s" % (pod["metadata"]["namespace"], pod["metadata"]["name"]))
    for container in pod["spec"].get("containers", []):
        if not container.get("resources", {}).get("limits", {}).get("memory"):
            no_limit += 1
            break

print("QoS across %d running pods:" % running)
for klass in sorted(qos):
    print("  %-12s %d" % (klass, qos[klass]))
print("")

if besteffort:
    print("FAIL - %d pod(s) run BestEffort:" % len(besteffort))
    for name in besteffort[:20]:
        print("    %s" % name)
    print("")
    print("  A BestEffort pod is invisible to the scheduler and first to be")
    print("  evicted under node memory pressure. If it is in a guarded namespace")
    print("  the LimitRange should have defaulted it -- a LimitRange applies at")
    print("  ADMISSION, so a pod that predates it keeps its old spec until it is")
    print("  recreated. Otherwise it needs a request in its own manifest.")
    sys.exit(1)

# Reported, never gated. See this file's header for why.
print("%d pod(s) have a container with no memory limit." % no_limit)
print("  Not a failure: limits are a tuning decision this project has twice")
print("  declined to make universal. Requests are the correctness property, and")
print("  every pod above has one.")
PY

RC=$?
[ "$RC" -ne 0 ] && FAILED=1

echo ""
echo "=================================================================="
if [ "$FAILED" -ne 0 ]; then
  echo " FAILED"
  echo "=================================================================="
  exit 1
fi
echo " PASSED - nothing BestEffort, and the floor is in place."
echo "=================================================================="
