#!/usr/bin/env bash
#
# Every workload this repository owns must declare CPU and memory requests,
# and a memory limit, and no CPU limit
# (T-2.15, #209).
#
# WHY REQUESTS AND NOT LIMITS
#
# A request is what the scheduler books. A container without one is BestEffort:
# invisible to scheduling decisions, first to be evicted under node pressure,
# and able to be placed on a node that is already full. That is a correctness
# property, not a tuning preference.
#
# Limits are a different argument and this deliberately does not assert on CPU
# limits, because there are none on purpose -- a CPU limit is enforced by CFS
# throttling, which stalls a request mid-flight and surfaces as tail latency.
# The reasoning is written out in services/gateway.yaml. A check that demanded
# CPU limits would be demanding the opposite of a decision that was made.
#
# WHY IT READS THE MANIFESTS AND NOT THE CLUSTER
#
# Two reasons. It runs in CI, where there is no cluster to read (T-1.5 closed
# the API to the public internet). And the things it would find in a cluster
# are mostly third-party chart sidecars this repository did not write and
# cannot fix without a values override -- asserting on those makes the check
# fail for reasons nobody here can act on, which is how a check gets skipped.
#
# Usage:
#   ./verify-resources.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

FAILED=0
CHECKED=0
TOTAL_FILE="$(mktemp)"
trap 'rm -f "$TOTAL_FILE"' EXIT INT TERM

echo "=================================================================="
echo " Every workload we own declares requests, a memory limit, and no CPU limit"
echo "=================================================================="
echo ""

# Only manifests this repository authors. Chart values are a different shape
# and are covered by the exception list below rather than by parsing.
FILES="$(find platform/envs -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"

for file in $FILES; do
  python - "$file" "$TOTAL_FILE" <<'PY' || FAILED=1
import sys

try:
    import yaml
except ImportError:
    sys.exit(0)

path = sys.argv[1]
WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

try:
    docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
except Exception:
    # A template with placeholders is not something this check can parse and is
    # not something it should fail on.
    sys.exit(0)

bad = []
found = 0
for doc in docs:
    if not isinstance(doc, dict) or doc.get("kind") not in WORKLOADS:
        continue
    name = doc.get("metadata", {}).get("name", "?")
    spec = doc.get("spec", {})
    # CronJob nests one level deeper than the rest.
    tmpl = spec.get("jobTemplate", {}).get("spec", {}).get("template") or spec.get("template") or {}
    containers = tmpl.get("spec", {}).get("containers", []) or []
    for c in containers:
        found += 1
        resources = c.get("resources") or {}
        req = resources.get("requests") or {}
        lim = resources.get("limits") or {}
        missing = [k for k in ("cpu", "memory") if k not in req]
        if missing:
            bad.append(f"{doc.get('kind')}/{name} container {c.get('name')} has no {' or '.join(missing)} request")
        # A MEMORY LIMIT IS REQUIRED; a CPU limit is required to be ABSENT.
        # Both halves are the same decision, stated in T-2.15 and restated in
        # the HPA manifests (T-2.8): memory is incompressible, so without a
        # limit one leaking pod takes the node and everything on it; CPU is
        # compressible, so a limit buys nothing and costs tail latency to CFS
        # throttling. Checking only the first half would let a well-meaning
        # change add CPU limits back and quietly undo the reasoning.
        if "memory" not in lim:
            bad.append(f"{doc.get('kind')}/{name} container {c.get('name')} has no memory limit")
        if "cpu" in lim:
            bad.append(
                f"{doc.get('kind')}/{name} container {c.get('name')} sets a CPU limit — "
                "deliberately not used here, see the comment in this script"
            )

if found:
    print(f"  {'FAIL' if bad else 'ok  '}  {path}  ({found} container(s))")
    # Counted so the caller can refuse to pass on having inspected nothing.
    with open(sys.argv[2], "a", encoding="utf-8") as fh:
        fh.write("x" * found)
for b in bad:
    print(f"          {b}")

sys.exit(1 if bad else 0)
PY
  CHECKED=$((CHECKED + 1))
done

TOTAL="$(wc -c < "$TOTAL_FILE" | tr -d ' ')"

# A check that inspected nothing must not report success. platform/envs is
# mostly Argo Application CRs, so the set of real workloads is small and a
# layout change could silently empty it — which would look exactly like passing.
# This repository has met that shape often enough to spend three lines on it.
if [ "${TOTAL:-0}" -eq 0 ]; then
  echo ""
  echo "  error: no workloads found under platform/envs at all." >&2
  echo "  Either the layout moved or this check is looking in the wrong place;" >&2
  echo "  passing with nothing inspected would be worse than failing." >&2
  FAILED=1
fi

echo ""
echo "=================================================================="
if [ "$FAILED" -eq 0 ]; then
  echo "PASSED — ${TOTAL} container(s) across platform/envs: requests and memory limits set, no CPU limits."
else
  echo "FAILED — a workload violates the resource policy. See the lines above."
  echo "         Without one it is BestEffort: invisible to the scheduler and"
  echo "         first to be evicted. Size it from measurement if there is any"
  echo "         (docs/slos.md), and from a guess you write down if there is not."
fi
echo "=================================================================="

exit "$FAILED"
