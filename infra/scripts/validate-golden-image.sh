#!/usr/bin/env bash
#
# Boot the candidate image. Promote it only if it works. (T-1.20, #252)
#
# WHY PACKER CANNOT DO THIS PART
#
# Every assertion in golden-image.pkr.hcl runs on the BUILD INSTANCE -- the
# machine whose disk becomes the snapshot. It is already booted, already has a
# machine-id, already ran cloud-init. Those assertions prove the files are on
# the disk. They cannot prove that a snapshot of that disk BOOTS.
#
# That gap is not hypothetical. The build's last act is to empty
# /etc/machine-id and wipe cloud-init's state, precisely so the image comes up
# fresh -- and if any of that leaves the image unable to boot, get an address
# or accept a key, packer still exits 0 and the snapshot still gets published.
# A control that reports success while the thing it names is broken is the
# exact shape #113, #155, #211 and #22 all turned out to be.
#
# Packer's hcloud builder cannot close it either: it has no mode that boots an
# image without producing another snapshot, so using it for the second stage
# would leave a junk snapshot per validation run -- on the very account whose
# retention problem was #253. So this stage talks to the API directly.
#
# WHAT "NOT PUBLISHED" MEANS HERE
#
# The build labels its output `xenopsbase-golden=candidate`. Everything that
# selects an image -- terraform, and the retention policy that decides what may
# be deleted -- selects `xenopsbase-golden=yes`. So a candidate is invisible to
# every consumer. This script relabels it to `yes` on success and DELETES it on
# failure. The Hetzner object exists for the few minutes validation takes,
# because you cannot boot an image that does not exist; it is never selectable.
#
# THE SERVER IS DESTROYED WHETHER THIS PASSES OR FAILS
#
# Cleanup is on a trap, covering success, assertion failure, an API error and
# Ctrl-C. Leaving a billable server behind on a failure -- the moment attention
# is elsewhere -- is how a cost surprise starts (#62).
#
# Usage:
#   source ~/.xenopsbase.env && ./validate-golden-image.sh [snapshot_id]
#
#   With no id, reads infra/packer/manifest.json, which `make golden-image`
#   has just written.
#
#   KEEP_SERVER=1  leave the instance up on failure so it can be inspected.
#                  It prints the exact command to remove it. You are then
#                  paying for it until you do.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKER_DIR="$ROOT/infra/packer"
VARS_FILE="$PACKER_DIR/versions.pkrvars.hcl"
ASSERTIONS="$PACKER_DIR/validate-assertions.sh"

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN is not set - run: source ~/.xenopsbase.env" >&2
  exit 1
fi

PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

api() {
  method="$1"; path="$2"; shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.hetzner.cloud/v1/${path}" "$@"
}

# ---------------------------------------------------------------------------
# Everything below must agree with what was built, so it is read from the same
# files the build read. A second copy of the location or the k3s version is a
# second thing to update, and the failure when they disagree looks like a
# broken image rather than a stale constant.
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*$/\\1/p" "$VARS_FILE" | head -1; }

LOCATION="$(tfvar location)"
SERVER_TYPE="$(tfvar server_type)"
K3S_VERSION="$(tfvar k3s_version)"
TAILSCALE_VERSION="$(tfvar tailscale_version)"

for v in LOCATION SERVER_TYPE K3S_VERSION TAILSCALE_VERSION; do
  if [ -z "$(eval echo "\$$v")" ]; then
    echo "error: could not read $v from $VARS_FILE" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Which snapshot. Packer's manifest, not "the newest candidate": two overlapping
# builds, or a previous build that died leaving its candidate behind, would
# otherwise have this boot one image and promote another -- with every
# assertion passing.
SNAPSHOT_ID="${1:-}"
if [ -z "$SNAPSHOT_ID" ]; then
  if [ ! -f "$PACKER_DIR/manifest.json" ]; then
    echo "error: no snapshot id given and no $PACKER_DIR/manifest.json." >&2
    echo "       run: make golden-image" >&2
    exit 1
  fi
  SNAPSHOT_ID="$("$PY_BIN" -c '
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
# hcloud reports artifact_id as the bare image id; take the most recent build.
print(m["builds"][-1]["artifact_id"].split(":")[-1])
' "$PACKER_DIR/manifest.json")"
fi

if ! printf '%s' "$SNAPSHOT_ID" | grep -qE '^[0-9]+$'; then
  echo "error: '$SNAPSHOT_ID' is not a snapshot id" >&2
  exit 1
fi

# It must be a candidate produced by this project. Booting and then RELABELLING
# an arbitrary image id is a destructive operation to hand to a typo.
IMAGE_JSON="$(api GET "images/${SNAPSHOT_ID}")"
IMAGE_STATE="$(printf '%s' "$IMAGE_JSON" | "$PY_BIN" -c '
import json, sys
try:
    i = json.load(sys.stdin)["image"]
except Exception:
    print("missing"); raise SystemExit
labels = i.get("labels") or {}
print(labels.get("xenopsbase-golden", "unlabelled"))
')"

# Two modes, because what a failure MEANS differs completely between them.
#
#   promote  the image is a fresh candidate. Nothing selects it yet, so a
#            failure deletes it and the previous golden image stays newest.
#
#   recheck  the image is already published, and may well be the one the
#            cluster is running. A failure here must NOT delete it: removing
#            an image nodes booted from turns a bad image into a cold-rebuild
#            outage (ADR-0008), and the right response is a human decision.
#            This is also the mode T-7.9 wants before a rolling replacement --
#            re-proving the image you are about to roll onto every node.
case "$IMAGE_STATE" in
  candidate) MODE=promote ;;
  yes)       MODE=recheck ;;
  missing)
    echo "error: no image ${SNAPSHOT_ID} in this project." >&2
    exit 1 ;;
  *)
    echo "error: image ${SNAPSHOT_ID} is labelled xenopsbase-golden=${IMAGE_STATE}." >&2
    echo "       This refuses to touch anything it did not build." >&2
    exit 1 ;;
esac

echo "=================================================================="
if [ "$MODE" = promote ]; then
  echo " Validating candidate ${SNAPSHOT_ID}"
else
  echo " Re-checking published golden image ${SNAPSHOT_ID}"
fi
echo "=================================================================="
echo "  location    : ${LOCATION}"
echo "  server type : ${SERVER_TYPE}"
echo "  expecting   : k3s ${K3S_VERSION}, tailscale ${TAILSCALE_VERSION}"
echo ""

# ---------------------------------------------------------------------------
# A keypair that exists for the length of this run and is registered nowhere
# else. Reusing a real key would put a long-lived credential on a machine whose
# only purpose is to be thrown away.
WORK="$(mktemp -d)"
SERVER_ID=""
SSH_KEY_ID=""
SERVER_NAME="golden-validate-$(date +%s)"

CLEANED=0
cleanup() {
  rc=$?
  # The trap covers INT and TERM as well as EXIT, and on a Ctrl-C both fire --
  # which would try to delete an already-deleted server and print an alarming
  # "FAILED (HTTP 404) - REMOVE IT BY HAND" for something that is gone.
  [ "$CLEANED" = 1 ] && return
  CLEANED=1
  echo ""
  if [ -n "$SERVER_ID" ]; then
    if [ "$rc" -ne 0 ] && [ "${KEEP_SERVER:-0}" = "1" ]; then
      echo "!! KEEP_SERVER=1 - server ${SERVER_ID} (${IP:-no ip}) is STILL RUNNING and billable."
      echo "   ssh -i ${WORK}/key root@${IP:-?}"
      echo "   remove it with:"
      echo "     curl -X DELETE -H \"Authorization: Bearer \$HCLOUD_TOKEN\" \\"
      echo "       https://api.hetzner.cloud/v1/servers/${SERVER_ID}"
      echo "   (the throwaway key is in ${WORK} and is not removed either)"
      # Deliberately skips the rm below, or the key would be gone.
      return
    fi
    printf '==> destroying validation server %s ... ' "$SERVER_ID"
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      "https://api.hetzner.cloud/v1/servers/${SERVER_ID}")"
    case "$code" in
      20*) echo "ok" ;;
      *)   echo "FAILED (HTTP ${code}) - REMOVE IT BY HAND, it is billable" ;;
    esac
  fi
  if [ -n "$SSH_KEY_ID" ]; then
    curl -sS -o /dev/null -X DELETE \
      -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
      "https://api.hetzner.cloud/v1/ssh_keys/${SSH_KEY_ID}"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ssh-keygen -t ed25519 -N '' -C "golden-image-validation" -f "$WORK/key" >/dev/null
chmod 600 "$WORK/key"
PUBKEY="$(cat "$WORK/key.pub")"

# Registered as a Hetzner ssh_key as well as injected through cloud-init.
# Passing ssh_keys is what stops Hetzner generating a root password and mailing
# it in plain text -- for a machine that is about to sit on a public IP with
# root SSH enabled, briefly, but on purpose.
SSH_KEY_ID="$(api POST ssh_keys -d "$("$PY_BIN" -c '
import json, sys
print(json.dumps({"name": sys.argv[1], "public_key": sys.argv[2]}))
' "$SERVER_NAME" "$PUBKEY")" | "$PY_BIN" -c '
import json, sys
d = json.load(sys.stdin)
if "ssh_key" not in d:
    sys.stderr.write(json.dumps(d) + "\n"); raise SystemExit(1)
print(d["ssh_key"]["id"])
')"
if [ -z "$SSH_KEY_ID" ]; then
  echo "error: could not register the throwaway ssh key" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# `disable_root: false` for the same reason the build needs it: the base
# snapshot ships root's authorized_keys behind a forced command that refuses
# the session, and cloud-init only writes the key without that guard when root
# login is explicitly enabled.
echo "==> creating ${SERVER_NAME} from image ${SNAPSHOT_ID}"
CREATE="$(api POST servers -d "$("$PY_BIN" -c '
import json, sys
name, stype, loc, image, key_id, pubkey = sys.argv[1:7]
print(json.dumps({
    "name": name,
    "server_type": stype,
    "location": loc,
    "image": int(image),
    "ssh_keys": [int(key_id)],
    "start_after_create": True,
    "labels": {"xenopsbase-validate": "yes"},
    "user_data": "#cloud-config\ndisable_root: false\nssh_authorized_keys:\n  - %s\n" % pubkey,
}))
' "$SERVER_NAME" "$SERVER_TYPE" "$LOCATION" "$SNAPSHOT_ID" "$SSH_KEY_ID" "$PUBKEY")")"

SERVER_ID="$(printf '%s' "$CREATE" | "$PY_BIN" -c '
import json, sys
d = json.load(sys.stdin)
print(d["server"]["id"] if "server" in d else "")
')"

if [ -z "$SERVER_ID" ]; then
  echo "error: could not create the validation server:" >&2
  printf '%s\n' "$CREATE" | "$PY_BIN" -m json.tool >&2 2>/dev/null || printf '%s\n' "$CREATE" >&2
  echo "" >&2
  echo "  If this says 'limit exceeded', the account is at its server cap." >&2
  echo "  Validation needs ONE server beyond whatever is already running." >&2
  exit 1
fi

IP="$(printf '%s' "$CREATE" | "$PY_BIN" -c '
import json, sys
print(json.load(sys.stdin)["server"]["public_net"]["ipv4"]["ip"])
')"
echo "    server ${SERVER_ID} at ${IP}"

# ---------------------------------------------------------------------------
printf '==> waiting for it to run '
for _ in $(seq 1 60); do
  status="$(api GET "servers/${SERVER_ID}" | "$PY_BIN" -c '
import json, sys
print(json.load(sys.stdin).get("server", {}).get("status", "?"))
')"
  [ "$status" = "running" ] && break
  printf '.'
  sleep 5
done
echo " ${status}"
if [ "$status" != "running" ]; then
  echo "error: the server never reached 'running' - the image may not boot." >&2
  exit 1
fi

SSH_OPTS="-i $WORK/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_OPTS="$SSH_OPTS -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes"

# 'running' means Hetzner started the VM, not that anything inside it works.
# Reaching sshd is the first real evidence that the image boots at all, and a
# timeout here IS the finding: it means the snapshot produced a machine that
# never came up.
printf '==> waiting for ssh '
SSH_OK=0
for _ in $(seq 1 60); do
  if ssh $SSH_OPTS "root@${IP}" true 2>/dev/null; then SSH_OK=1; break; fi
  printf '.'
  sleep 5
done
echo ""
if [ "$SSH_OK" -ne 1 ]; then
  echo "error: could not ssh in within five minutes." >&2
  echo "       The candidate booted into something unreachable. NOT promoting." >&2
  api POST "servers/${SERVER_ID}/actions/request_console" >/dev/null 2>&1 || true
  exit 1
fi

# ---------------------------------------------------------------------------
echo ""
ssh $SSH_OPTS "root@${IP}" 'bash -s' -- "$K3S_VERSION" "$TAILSCALE_VERSION" < "$ASSERTIONS"
ASSERT_RC=$?

echo ""
if [ "$ASSERT_RC" -ne 0 ]; then
  if [ "$MODE" = recheck ]; then
    echo "=================================================================="
    echo " RE-CHECK FAILED for published image ${SNAPSHOT_ID}"
    echo "=================================================================="
    echo ""
    echo "  This image is NOT deleted, deliberately. It is published, so"
    echo "  nodes may have booted from it, and removing it would turn a bad"
    echo "  image into a failed cold rebuild (ADR-0008) at the worst moment."
    echo ""
    echo "  Decide, then act:"
    echo "    - build a replacement:  make golden-image"
    echo "    - then retire this one: make prune-snapshots"
    exit 1
  fi

  echo "=================================================================="
  echo " VALIDATION FAILED - deleting candidate ${SNAPSHOT_ID}"
  echo "=================================================================="
  echo ""
  echo "  Nothing was promoted, so terraform still selects the previous"
  echo "  golden image and 'make up' is unaffected."
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
    "https://api.hetzner.cloud/v1/images/${SNAPSHOT_ID}")"
  case "$code" in
    20*) echo "  candidate ${SNAPSHOT_ID} deleted." ;;
    *)   echo "  WARNING: could not delete candidate ${SNAPSHOT_ID} (HTTP ${code})." ;;
  esac
  exit 1
fi

if [ "$MODE" = recheck ]; then
  echo "=================================================================="
  echo " ${SNAPSHOT_ID} still passes every assertion"
  echo "=================================================================="
  echo "  Already published; nothing to promote."
  exit 0
fi

# ---------------------------------------------------------------------------
# Promotion. The label is the only thing that makes an image selectable, so
# this single call is what "published" means -- and it happens after the
# assertions rather than before, which is the whole of #252.
echo "==> promoting ${SNAPSHOT_ID}"
PROMOTE_BODY="$(printf '%s' "$IMAGE_JSON" | "$PY_BIN" -c '
import json, sys
image = json.load(sys.stdin)["image"]
labels = dict(image.get("labels") or {})
labels["xenopsbase-golden"] = "yes"
# Renamed too, so a snapshot still called "candidate" in the Hetzner console is
# unambiguously one whose validation did not finish.
desc = (image.get("description") or "").replace("-candidate", "", 1)
print(json.dumps({"description": desc, "labels": labels}))
')"

RESULT="$(api PUT "images/${SNAPSHOT_ID}" -d "$PROMOTE_BODY")"
printf '%s' "$RESULT" | "$PY_BIN" -c '
import json, sys
d = json.load(sys.stdin)
if "image" not in d:
    sys.stderr.write("promotion FAILED: " + json.dumps(d) + "\n"); raise SystemExit(1)
i = d["image"]
labels = i.get("labels") or {}
if labels.get("xenopsbase-golden") != "yes":
    sys.stderr.write("promotion did not take: " + json.dumps(labels) + "\n"); raise SystemExit(1)
print("")
print("=" * 66)
print(" PROMOTED  %s" % i["id"])
print("=" * 66)
print("  %s" % i.get("description"))
print("  k3s=%s  tailscale=%s  %.1fGB" % (
    labels.get("k3s-version", "?"), labels.get("tailscale-version", "?"),
    i.get("image_size") or 0.0))
print("")
print("  It is now selectable by xenopsbase-golden=yes, and by the retention")
print("  policy that keeps the newest few (make prune-snapshots).")
' || exit 1
