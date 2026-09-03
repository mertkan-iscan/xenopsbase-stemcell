#!/usr/bin/env bash
#
# Does Kubernetes agree with Hetzner about where each volume is attached?
# (T-7.9, #254)
#
# WHY THIS EXISTS, AND WHY IT IS THE HIGHEST-VALUE PIECE OF T-7.9
#
# Both workers were replaced twice on 2026-08-30 while landing T-2.28. Both
# times the same thing happened, and it is not the failure anybody expected:
#
#   kubectl get volumeattachment   ->  attached: true   node=xenopsbase-dev-worker-1
#   hcloud volume list             ->  SERVER: (empty)
#
# Kubernetes believed the volume was attached. Hetzner had it attached to
# nothing. The `VolumeAttachment` object had been created against the OLD server,
# survived its destruction, and still reported success -- so the external
# attacher never issued a fresh attach and the device never appeared:
#
#   MountVolume.SetUp failed ... device "/dev/disk/by-id/scsi-0HC_Volume_..." not ready
#
# Both Postgres pods sat in PodInitializing for about THIRTY MINUTES, and
# Keycloak crash-looped behind them for the same window. That is the difference
# between "the application served throughout" and an outage, and it is invisible
# from inside Kubernetes: every object involved reports success.
#
# THIS IS NOT WHAT reap-orphaned-volumes.sh COVERS
#
# That script handles volumes with no owner after a teardown -- garbage. This is
# a live volume, with a live claim, and an attachment object that is lying. The
# two failures look nothing alike and neither script finds the other's.
#
# WHY IT DOES NOT FIX ANYTHING ITSELF
#
# The remedy is to delete the stale VolumeAttachment, after which the attacher
# issues a real attach and the volume binds in seconds. That is safe ONLY while
# Hetzner reports the volume detached -- deleting an attachment for a volume
# Hetzner still has attached elsewhere invites a dual attach, which is how a
# filesystem gets corrupted rather than delayed.
#
# So this reports, names the precondition it verified, and prints the command.
# A script that deletes attachments on its own would be one `--force` away from
# doing it in the case where it must not.
#
# Usage:
#   export KUBECONFIG="$PWD/infra/terraform/cluster/kubeconfig"
#   export HCLOUD_TOKEN=...
#   ./check-volume-attachments.sh
#
#   ./check-volume-attachments.sh <attachments.json> <nodes.json> <volumes.json>
#     Reads captured state instead of querying. For diagnosing from a dump after
#     the fact, and for exercising the detector against a state this cluster is
#     not currently in.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

# Test each candidate by RUNNING it. On Windows `python3` is a Store alias that
# satisfies `command -v` and then prints an advert and exits.
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
echo " Volume attachments: does Kubernetes agree with Hetzner?"
echo "=================================================================="
echo ""

if [ "$#" -ge 3 ]; then
  ATTACHMENTS="$1"
  NODES="$2"
  VOLUMES="$3"
  echo "  reading captured state, not the live cluster"
  echo ""
else
  command -v kubectl >/dev/null 2>&1 || {
    echo "error: kubectl is required" >&2
    exit 1
  }
  [ -n "${HCLOUD_TOKEN:-}" ] || {
    echo "error: HCLOUD_TOKEN is required -- half of this check is Hetzner's view," >&2
    echo "       and without it this would report agreement it never verified." >&2
    exit 1
  }

  if ! kubectl version -o json >/dev/null 2>&1; then
    echo "error: no cluster. Point KUBECONFIG at this project's:" >&2
    echo "  export KUBECONFIG=\"\$PWD/infra/terraform/cluster/kubeconfig\"" >&2
    echo "The shell's own KUBECONFIG is usually a stale local cluster." >&2
    exit 1
  fi

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT INT TERM
  # Under Git Bash a native python cannot resolve /tmp/...; cygpath gives the
  # form both understand. Absent on Linux, where they already agree.
  if command -v cygpath >/dev/null 2>&1; then
    WORK_PY="$(cygpath -m "$WORK")"
  else
    WORK_PY="$WORK"
  fi

  kubectl get volumeattachment -o json > "$WORK/va.json" 2>/dev/null
  kubectl get nodes -o json > "$WORK/nodes.json" 2>/dev/null
  curl -sS --max-time 30 -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "https://api.hetzner.cloud/v1/volumes?per_page=50" > "$WORK/vol.json" || {
      echo "error: could not read volumes from the Hetzner API" >&2
      exit 1
    }

  ATTACHMENTS="$WORK_PY/va.json"
  NODES="$WORK_PY/nodes.json"
  VOLUMES="$WORK_PY/vol.json"
fi

"$PY_BIN" - "$ATTACHMENTS" "$NODES" "$VOLUMES" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    attachments = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    nodes = json.load(handle)
with open(sys.argv[3], encoding="utf-8") as handle:
    volumes = json.load(handle)

# providerID is `hcloud://<server id>`, which is the only reliable link between
# a Node and a Hetzner server. Names are not: a replaced node can reappear with
# the same name and a different server.
node_server = {}
for node in nodes.get("items", []):
    provider = node.get("spec", {}).get("providerID", "")
    if provider.startswith("hcloud://"):
        node_server[node["metadata"]["name"]] = provider[len("hcloud://") :]

# Hetzner keys volumes by NAME, and the CSI driver names them after the PV.
volume_server = {}
for volume in volumes.get("volumes", []):
    server = volume.get("server")
    volume_server[volume["name"]] = str(server) if server is not None else None

rows = []
for attachment in attachments.get("items", []):
    if not attachment.get("status", {}).get("attached"):
        continue

    name = attachment["metadata"]["name"]
    spec = attachment.get("spec", {})
    node = spec.get("nodeName", "")
    pv = spec.get("source", {}).get("persistentVolumeName", "")

    if node not in node_server:
        rows.append((name, node, pv, "STALE", "the node it names does not exist"))
        continue

    expected = node_server[node]
    if pv not in volume_server:
        rows.append((name, node, pv, "UNKNOWN", "no Hetzner volume with this name"))
        continue

    actual = volume_server[pv]
    if actual is None:
        rows.append((name, node, pv, "STALE", "Hetzner has this volume attached to nothing"))
    elif actual != expected:
        rows.append((name, node, pv, "MISMATCH", "Hetzner has it on server %s, not %s" % (actual, expected)))
    else:
        rows.append((name, node, pv, "ok", ""))

if not rows:
    print("  No attached volumes. Nothing to disagree about.")
    sys.exit(0)

print("  %-22s %-34s %-10s %s" % ("node", "volume (pv)", "verdict", "why"))
for name, node, pv, verdict, why in rows:
    print("  %-22s %-34s %-10s %s" % (node or "(none)", pv[:34], verdict, why))
print("")

stale = [r for r in rows if r[3] == "STALE"]
mismatch = [r for r in rows if r[3] == "MISMATCH"]
unknown = [r for r in rows if r[3] == "UNKNOWN"]

if mismatch:
    print("  FAILED - Kubernetes and Hetzner disagree about WHERE a volume is attached.")
    print("")
    print("  DO NOT delete these attachment objects. Hetzner still has the volume attached")
    print("  somewhere, so forcing a re-attach risks a dual attach, which corrupts a")
    print("  filesystem rather than delaying it. Find out why the two disagree first.")
    sys.exit(1)

if stale:
    print("  FAILED - %d attachment(s) claim a volume Hetzner has attached to nothing." % len(stale))
    print("")
    print("  This is the T-7.9 (#254) failure: the object outlived the server it was made")
    print("  against, still reports success, and the attacher will never issue a fresh")
    print("  attach. Pods stay in PodInitializing with 'device ... not ready' until it is")
    print("  removed -- 30 minutes, twice, on 2026-08-30.")
    print("")
    print("  Safe to delete: this check has confirmed Hetzner holds each of these detached,")
    print("  which is the precondition. The attacher re-attaches within seconds.")
    print("")
    for name, node, pv, _verdict, _why in stale:
        print("    kubectl delete volumeattachment %s" % name)
    sys.exit(1)

if unknown:
    print("  WARNING - %d attachment(s) name a volume the Hetzner API did not return." % len(unknown))
    print("  Not necessarily wrong: a volume in another project or past the page size")
    print("  looks the same from here. Worth resolving before trusting a PASSED.")
    sys.exit(1)

print("  PASSED - every attached volume is where Kubernetes believes it is.")
sys.exit(0)
PY
