#!/usr/bin/env bash
#
# Every FIXED worker keeps room for one ordinary platform pod to land, after the
# platform has converged (T-2.29, #368).
#
# WHAT THIS IS NOT
#
# It is not a check that the applications fit at their HPA ceiling. They do not,
# and that is deliberate. Measured 2026-09-03 with core 1->3 and gateway 2->4:
#
#   memory   floor 2112Mi   ceiling 5056Mi   +2944Mi   free on fixed workers 1836Mi
#   cpu      floor  2700m   ceiling  6100m   +3400m    free on fixed workers  1390m
#
# The autoscaler covers that gap and is the documented answer to it -- see the
# `max_nodes = 2` block in infra/terraform/cluster/env/dev.tfvars, whose
# 2026-08-29 experiment placed the full ceiling on five nodes with zero Pending,
# and which did it again unprompted during the 2026-09-03 load run. Sizing the
# fixed workers for a ceiling the autoscaler exists to absorb would mean paying
# for that headroom around the clock to avoid a node that arrives in ninety
# seconds.
#
# WHAT IT DOES GATE ON, AND WHY THAT NUMBER
#
# #368 was filed because worker-0 had ELEVEN megabytes of schedulable memory.
# Nothing could land on it: not a rescheduled coredns, not a CSI sidecar after a
# node event, not a DaemonSet member rolling. The autoscaler does not help
# there, because those pods are not Pending long enough to trigger it and some
# of them are bound to the node they cannot fit on.
#
# So the floor is "one ordinary PLATFORM pod", not one application pod:
#
#   256Mi   comfortably above the largest single kube-system pod (that namespace
#           books 478Mi across 11 pods) with room for a CSI sidecar set
#   250m    one CPU-modest system pod, sized the same way
#
# These are a floor to detect saturation, not a target to plan against. If they
# start failing, the fixed workers are full and the answer is #341 (carry less)
# or a third fixed worker -- not a smaller floor.
#
# It asks the CLUSTER, because "requested" is a scheduler fact about running
# pods and not a property of any manifest.
#
# Usage:
#   export KUBECONFIG="$PWD/infra/terraform/cluster/kubeconfig"
#   ./check-worker-headroom.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

command -v kubectl >/dev/null 2>&1 || {
  echo "error: kubectl is required" >&2
  exit 1
}

# Test each candidate by RUNNING it. On Windows `python3` is a Microsoft Store
# alias that satisfies `command -v` and then prints an advert and exits, so
# locating an interpreter is not the same as having one.
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

MIN_MEM_MI="${HEADROOM_MIN_MEMORY_MI:-256}"
MIN_CPU_M="${HEADROOM_MIN_CPU_M:-250}"

echo "=================================================================="
echo " Fixed-worker headroom - room for one ordinary platform pod"
echo "=================================================================="
echo ""

if ! kubectl version -o json >/dev/null 2>&1; then
  echo "error: no cluster. Point KUBECONFIG at this project's:" >&2
  echo "  export KUBECONFIG=\"\$PWD/infra/terraform/cluster/kubeconfig\"" >&2
  echo "The shell's own KUBECONFIG is usually a stale local cluster." >&2
  exit 1
fi

# Captured to files rather than piped: `python - <<HEREDOC` takes the SCRIPT on
# stdin, so anything piped in is discarded and json.load reads an empty string.
NODES="$(mktemp)"
PODS="$(mktemp)"
trap 'rm -f "$NODES" "$PODS"' EXIT INT TERM
kubectl get nodes -o json >"$NODES" 2>/dev/null
kubectl get pods -A -o json >"$PODS" 2>/dev/null

"$PY_BIN" - "$NODES" "$PODS" "$MIN_MEM_MI" "$MIN_CPU_M" <<'PY'
import json
import sys

nodes_path, pods_path = sys.argv[1], sys.argv[2]
min_mem, min_cpu = int(sys.argv[3]), int(sys.argv[4])

with open(nodes_path, encoding="utf-8") as handle:
    nodes = json.load(handle)
with open(pods_path, encoding="utf-8") as handle:
    pods = json.load(handle)


def cpu_m(value):
    if not value:
        return 0
    value = str(value)
    if value.endswith("m"):
        return int(value[:-1])
    # The API normalises "1000m" to "1", so a plain number is CORES. Reading it
    # as millicores understates a gateway pod by a factor of a thousand.
    return int(float(value) * 1000)


def mem_mi(value):
    if not value:
        return 0
    value = str(value)
    for suffix, factor in (("Gi", 1024), ("Mi", 1), ("Ki", 1.0 / 1024)):
        if value.endswith(suffix):
            return int(float(value[: -len(suffix)]) * factor)
    return int(int(value) / (1024 * 1024))


# A fixed worker is any non-control-plane node that is not in the autoscaled
# pool. Derived from the label rather than the name, so a renamed environment
# fails loudly instead of silently checking nothing.
fixed = []
for node in nodes.get("items", []):
    labels = node["metadata"].get("labels", {})
    if "node-role.kubernetes.io/control-plane" in labels:
        continue
    if labels.get("hcloud/node-group", "").endswith("-autoscaled"):
        continue
    fixed.append(node)

if not fixed:
    print("  error: no fixed workers found - the hcloud/node-group label is missing or renamed")
    sys.exit(1)

# Only Running and Pending pods hold a reservation. A Succeeded or Failed pod
# still has a spec full of requests and reserves nothing; counting those is what
# made #340's premise wrong by 1700Mi.
booked = {}
for pod in pods.get("items", []):
    if pod["status"].get("phase") not in ("Running", "Pending"):
        continue
    node = pod["spec"].get("nodeName")
    if not node:
        continue
    containers = pod["spec"].get("containers", [])
    inits = pod["spec"].get("initContainers", [])
    # The pod's effective request. Init containers run in sequence BEFORE the
    # others, so the pod reserves the larger of the two, never their sum.
    c_mem = sum(mem_mi(c.get("resources", {}).get("requests", {}).get("memory")) for c in containers)
    c_cpu = sum(cpu_m(c.get("resources", {}).get("requests", {}).get("cpu")) for c in containers)
    i_mem = max([mem_mi(c.get("resources", {}).get("requests", {}).get("memory")) for c in inits] + [0])
    i_cpu = max([cpu_m(c.get("resources", {}).get("requests", {}).get("cpu")) for c in inits] + [0])
    slot = booked.setdefault(node, [0, 0])
    slot[0] += max(c_mem, i_mem)
    slot[1] += max(c_cpu, i_cpu)

failed = 0
print("  floor: %dMi memory, %dm cpu per fixed worker" % (min_mem, min_cpu))
print("")
print("  %-34s %11s %10s" % ("node", "mem free", "cpu free"))

for node in sorted(fixed, key=lambda n: n["metadata"]["name"]):
    name = node["metadata"]["name"]
    allocatable = node["status"]["allocatable"]
    used_mem, used_cpu = booked.get(name, [0, 0])
    free_mem = mem_mi(allocatable.get("memory")) - used_mem
    free_cpu = cpu_m(allocatable.get("cpu")) - used_cpu

    short = []
    if free_mem < min_mem:
        short.append("memory")
        failed = 1
    if free_cpu < min_cpu:
        short.append("cpu")
        failed = 1
    verdict = "ok" if not short else "FULL - " + " and ".join(short) + " below the floor"
    print("  %-34s %9dMi %9dm   %s" % (name, free_mem, free_cpu, verdict))

print("")
if failed:
    print("  FAILED - a fixed worker has no room for an ordinary platform pod.")
    print("  This is T-2.29 (#368) recurring. The answer is to carry less (T-2.27, #341)")
    print("  or to add a fixed worker - not to lower the floor.")
else:
    print("  PASSED - every fixed worker can still place an ordinary platform pod.")

sys.exit(1 if failed else 0)
PY
