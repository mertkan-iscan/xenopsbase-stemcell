#!/usr/bin/env bash
#
# No node is above 75% memory, on a denominator that means something (T-2.27, #341).
#
# WHY THIS SCRIPT EXISTS RATHER THAN `kubectl top nodes`
#
# T-2.27's criterion is "no node above 75% memory". That sentence had no
# denominator, and the two obvious ones disagreed by THIRTY POINTS on the same
# node at the same instant:
#
#   kubectl top (working set / allocatable)      worker-1  91%
#   MemAvailable            / MemTotal           worker-1  52%
#
# Two reasons the second is the one worth gating on, decided 2026-09-04:
#
# 1. `kubectl top` counts RECLAIMABLE PAGE CACHE as used. worker-1 was holding
#    3612Mi of it. Cache is returned under pressure; it is not memory the node
#    has spent. Reading it as spent makes a healthy node look nearly full.
#
# 2. `kubectl top` divides by ALLOCATABLE, which moves. T-2.28 (#367) cut
#    allocatable by 1250Mi, so this card's own before-and-after figures are not
#    comparable: worker-1's absolute footprint went DOWN over that period while
#    its percentage went UP. A threshold that moves when kubelet reservations
#    change measures the kubelet, not the platform.
#
# What this measures is `(MemTotal - MemAvailable) / MemTotal`: physical memory
# actually committed, over physical memory present. It is independent of
# kube-reserved, system-reserved and eviction-hard, and it is the number that
# predicts the failure the threshold exists to prevent -- T-1.12 (#133), where
# the machine ran out and Argo's repo-server began failing its probes, so
# committed changes silently stopped arriving.
#
# AT FLOOR, which is the condition the criterion states. Under load the HPAs add
# replicas and the autoscaler adds nodes; measuring then answers a different
# question (T-2.29, #368 covers that one).
#
# Usage:
#   export KUBECONFIG="$PWD/infra/terraform/cluster/kubeconfig"
#   ./check-node-memory.sh [threshold-percent]      default 75
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

THRESHOLD="${1:-75}"

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

echo "=================================================================="
echo " Node memory at floor - committed / physical, threshold ${THRESHOLD}%"
echo "=================================================================="
echo ""

if ! kubectl version -o json >/dev/null 2>&1; then
  echo "error: no cluster. Point KUBECONFIG at this project's:" >&2
  echo "  export KUBECONFIG=\"\$PWD/infra/terraform/cluster/kubeconfig\"" >&2
  exit 1
fi

# node-exporter, through the API server, so this needs no port-forward and no
# credential beyond the kubeconfig. Prometheus is the source because it already
# scrapes every node; reading /proc on each would need a privileged pod per node.
PROM="/api/v1/namespaces/observability/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query"
QUERY="100%20%2A%20%281%20-%20node_memory_MemAvailable_bytes%20%2F%20node_memory_MemTotal_bytes%29"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
if command -v cygpath >/dev/null 2>&1; then
  WORK_PY="$(cygpath -m "$WORK")"
else
  WORK_PY="$WORK"
fi

kubectl get --raw "${PROM}?query=${QUERY}" > "$WORK/mem.json" 2>/dev/null || {
  echo "error: could not query Prometheus. Is the observability stack up?" >&2
  exit 1
}
kubectl get nodes -o json > "$WORK/nodes.json" 2>/dev/null

"$PY_BIN" - "$WORK_PY/mem.json" "$WORK_PY/nodes.json" "$THRESHOLD" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    mem = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    nodes = json.load(handle)
threshold = float(sys.argv[3])

# node-exporter reports by scrape target address, which is the node's internal
# IP. Mapping back to names so the output names something a person can act on.
by_ip = {}
for node in nodes.get("items", []):
    for address in node["status"].get("addresses", []):
        if address["type"] == "InternalIP":
            by_ip[address["address"]] = node["metadata"]["name"]

results = mem.get("data", {}).get("result", [])
if not results:
    print("  error: node-exporter returned no series. Nothing was measured.")
    print("  A green result here would be a claim about data that does not exist.")
    sys.exit(1)

rows = []
for item in results:
    instance = item["metric"].get("instance", "?")
    ip = instance.split(":")[0]
    rows.append((by_ip.get(ip, instance), float(item["value"][1])))

rows.sort()
over = [r for r in rows if r[1] > threshold]

print("  %-46s %8s" % ("node", "committed"))
for name, pct in rows:
    mark = "  OVER" if pct > threshold else ""
    print("  %-46s %7.1f%%%s" % (name, pct, mark))
print("")

if over:
    print("  FAILED - %d node(s) above %.0f%% of physical memory." % (len(over), threshold))
    print("")
    print("  This is committed memory, not page cache: the figure that predicts T-1.12")
    print("  (#133), where the machine ran out and Argo's repo-server began failing its")
    print("  probes, so committed changes silently stopped arriving.")
    print("")
    print("  The largest consumer is normally the observability stack. T-2.27 asks for")
    print("  its footprint to be derived from what dev needs to observe rather than")
    print("  trimmed by guess.")
    sys.exit(1)

print("  PASSED - every node is below %.0f%% of its physical memory." % threshold)
print("")
print("  Measured as (MemTotal - MemAvailable) / MemTotal. `kubectl top nodes` will")
print("  report higher: it counts reclaimable page cache as used and divides by")
print("  allocatable, which moves whenever kubelet reservations change.")
sys.exit(0)
PY
