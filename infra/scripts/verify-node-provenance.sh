#!/usr/bin/env bash
#
# Did this node boot the image, or did it build itself? (T-1.27, #288)
#
# WHY THIS EXISTS
#
# #250 and #251 put nodes on the golden image so they would stop downloading and
# installing k3s at boot. Two clusters have been built and destroyed since, and
# nobody has ever confirmed that they do. Not because the answer is hard --
# because asking it was. The first cluster was thrashing badly enough that
# `kubectl debug` returned nothing; the second died before an agent existed.
#
# So this asks the node, not the cluster. No kubectl, no scheduler, no API
# server. The node that most needs checking is the one that failed to join, and
# that is exactly the node no in-cluster tool can reach.
#
# WHAT IT COMPARES AGAINST
#
# The image's own `k3s-version` label, read back from the Hetzner API for the
# image THAT SERVER ACTUALLY BOOTED -- not the newest golden image, and not the
# version in versions.pkrvars.hcl. Those two are what you would assume; the
# label on the booted image is the fact. A node running a k3s the image did not
# ship is the failure this is for, and comparing against an assumption would
# hide exactly that case.
#
# Usage:
#   ./verify-node-provenance.sh [env]
#
set -uo pipefail

ENVIRONMENT="${1:-dev}"
CLUSTER="${CLUSTER_NAME:-xenopsbase}-${ENVIRONMENT}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/xenopsbase_ed25519}"
# -n matters and is not decoration. This loop reads its node list from a
# process substitution, and ssh reads stdin -- so without it the first node's
# ssh drains every remaining line and the loop silently checks one node and
# reports success. Which it did, twice, while three servers were running.
SSH_OPTS="-n -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

FAIL=0
CHECKED=0
GAPS=0

note() { printf '  %-6s %s\n' "$1" "$2"; }

echo "=================================================================="
echo " Node provenance — $CLUSTER"
echo "=================================================================="

command -v hcloud >/dev/null 2>&1 || { echo "  hcloud CLI not found." >&2; exit 1; }
[ -n "${HCLOUD_TOKEN:-}" ] || {
  echo "  HCLOUD_TOKEN is not set — run: source ~/.xenopsbase.env" >&2
  exit 1
}

# The project is confirmed before anything is read from it. An ambient token
# pointing at a different Hetzner project reports a clean run against servers
# that are not ours, which is worse than reporting nothing.
if ! hcloud server list -o noheader -o columns=name 2>/dev/null | grep -q "^${CLUSTER}"; then
  echo "  no servers named ${CLUSTER}-* in the project this token sees." >&2
  echo "  either the cluster is down, or HCLOUD_TOKEN belongs to another project." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Reached over the tailnet by name, not by public IP. ADR-0006 closes 22 to the
# internet, so the public address is not a way in even when it answers ping.
DOMAIN="$(grep -oE 'tailscale_magicdns_domain[[:space:]]*=[[:space:]]*"[^"]+"' \
  "infra/terraform/cluster/env/${ENVIRONMENT}.tfvars" 2>/dev/null | cut -d'"' -f2)"

while IFS=$'\t' read -r name image_id; do
  [ -n "$name" ] || continue
  CHECKED=$((CHECKED + 1))
  echo ""
  echo "  ${name}"

  # What the image claims. `+` is not a legal Hetzner label value, so the build
  # stores v1.36.3_k3s1 and it converts back here.
  if [ -z "$image_id" ]; then
    note FAIL "could not read which image this server booted"
    FAIL=1
    continue
  fi

  want="$(hcloud image describe "$image_id" -o json 2>/dev/null \
    | python -c "import json,sys; print(json.load(sys.stdin).get('labels',{}).get('k3s-version',''))" 2>/dev/null \
    | tr '_' '+')"

  if [ -z "$want" ]; then
    # Not a golden image. The base OS snapshot carries no k3s-version label
    # because it ships no k3s -- so a node on it MUST download one, and
    # "FAIL: no label" would blame the image for the very thing being
    # measured. The download check below still runs, and on such a node it is
    # expected to fail. That is the finding, stated where it belongs.
    note info "image ${image_id} is not a golden image — no k3s-version label"
    want=""
  else
    note info "image ${image_id} ships k3s ${want}"
  fi

  # RESOLVED FROM THE TAILNET, NOT FROM MAGICDNS.
  #
  # Tailscale appends a suffix when a hostname is taken, and a rebuilt node
  # finds its own name held by its dead predecessor:
  #
  #   xenopsbase-dev-worker-0      offline, last seen 31m ago   <- MagicDNS answers this
  #   xenopsbase-dev-worker-0-1    offline, last seen 6m ago
  #   xenopsbase-dev-worker-0-2    the node that is actually running
  #
  # So the name resolves to a corpse and the ssh times out.
  #
  # The key IS ephemeral (T-1.29, #290: verified in the admin console, and it
  # has been since before that card was raised), so those devices do get reaped
  # -- but not instantly, and the suffix outlives them. A rebuild faster than the
  # reap window gives the new node `-1`, and it keeps that name for life. This
  # resolver is therefore permanent rather than a workaround: the collision is
  # inherent to rebuilding faster than devices are reaped, which is the normal
  # operating mode here.
  #
  # Prefer the live device whose name is the server name or that name plus a
  # numeric suffix. Fall back to MagicDNS when tailscale is not on this machine.
  host="$(tailscale status 2>/dev/null     | awk -v n="$name" '$2 == n || $2 ~ "^"n"-[0-9]+$" { if ($0 !~ /offline/) { print $1; exit } }')"
  host="${host:-${name}${DOMAIN:+.$DOMAIN}}"
  out="$(ssh $SSH_OPTS "root@${host}" '
    printf "GOT_VERSION=%s\n" "$(/usr/local/bin/k3s --version 2>/dev/null | head -1 | awk "{print \$3}")"
    printf "BTIME=%s\n"      "$(awk "/btime/{print \$2}" /proc/stat)"
    printf "K3S_MTIME=%s\n"  "$(stat -c %Y /usr/local/bin/k3s 2>/dev/null || echo 0)"
    printf "INSTALLER=%s\n"  "$(ls /usr/local/bin/k3s-uninstall.sh /usr/local/bin/k3s-agent-uninstall.sh /usr/local/bin/k3s-killall.sh 2>/dev/null | wc -l)"
    printf "DOWNLOADS=%s\n"  "$(journalctl -b 2>/dev/null | grep -icE "get\.k3s\.io|github\.com/k3s-io/k3s/releases|install-verified-kubernetes" || true)"
    printf "PKGOPS=%s\n"      "$(journalctl -b 2>/dev/null | grep -icE "zypper (in|install)|transactional-update (pkg|up)" || true)"
    printf "SERVER=%s\n"      "$(systemctl is-active k3s 2>/dev/null)"
    printf "AGENT=%s\n"       "$(systemctl is-active k3s-agent 2>/dev/null)"
    printf "READY_AT=%s\n"    "$(systemd-analyze 2>/dev/null | head -1)"
  ' 2>&1)"

  if ! printf '%s' "$out" | grep -q "GOT_VERSION="; then
    # Not counted as a pass. A node that cannot be reached is the case this
    # whole check was written for, so silence here must be loud.
    note FAIL "unreachable over the tailnet — ${out%%$'\n'*}"
    FAIL=1
    continue
  fi

  eval "$(printf '%s' "$out" | grep -E '^(GOT_VERSION|BTIME|K3S_MTIME|INSTALLER|DOWNLOADS|PKGOPS|SERVER|AGENT)=')"
  READY_AT="$(printf '%s' "$out" | sed -n 's/^READY_AT=//p')"

  # THE QUESTION THIS FILE EXISTS FOR, asked of the filesystem.
  #
  # NOT the journal. The first version of this check read `journalctl -b` for
  # a k3s fetch and reported "installed nothing" for a control plane that
  # demonstrably had: the module installs over terraform's remote-exec, in an
  # SSH session, so nothing about it reaches the journal at all. A check that
  # passes the exact node it was written to catch is worse than no check.
  #
  # Two filesystem facts answer it and neither depends on how the install was
  # invoked:
  #
  #   1. When /usr/local/bin/k3s was written, against when the node booted.
  #      Baked means older than this boot. Written after it means here.
  #   2. Whether the upstream installer's uninstall and killall scripts exist.
  #      The golden image curls the binary and writes the unit itself, so it
  #      never produces them; `sh install.sh` always does.
  #
  # Measured on a module-built control plane, which is the positive control:
  #   k3s mtime 11:40:07, boot 11:39, k3s-uninstall.sh and k3s-killall.sh both
  #   present.
  # Detection and verdict are separate. Printing "FAIL" here and then deciding
  # the node is out of scope produced output that contradicted its own summary.
  installed_here=0
  why=""
  if [ "${K3S_MTIME:-0}" -gt "${BTIME:-0}" ]; then
    why="k3s written $(( ${K3S_MTIME:-0} - ${BTIME:-0} ))s after boot"
    installed_here=1
  fi
  if [ "${INSTALLER:-0}" -gt 0 ]; then
    why="${why:+$why; }upstream installer left ${INSTALLER} script(s)"
    installed_here=1
  fi
  if [ "$installed_here" -eq 0 ]; then
    note ok "installed nothing — k3s predates this boot and no installer ran"
  elif [ -z "$want" ]; then
    # SCOPED, and the scope is the assertion: a node that booted the GOLDEN
    # IMAGE installed nothing. A node on the base OS snapshot ships no k3s, so
    # it must install one -- that is not a violation of the claim, it is a node
    # the claim does not cover yet.
    #
    # Reported as a gap rather than a pass, and rather than a failure. A pass
    # would launder the thing this file exists to make visible; a failure would
    # leave the target permanently red, and a check that is always red is a
    # check nobody reads. Control planes are still on the base snapshot; #287
    # is where that ends, and this line is what will notice when it does.
    note gap "installed k3s ($why) — expected on the base snapshot, #287"
    GAPS=$((GAPS + 1))
  else
    note FAIL "booted a golden image and installed k3s anyway ($why)"
    FAIL=1
  fi

  # Supplementary. Catches a download from cloud-init or a unit, which does
  # reach the journal; on its own it proves nothing, per the note above.
  [ "${DOWNLOADS:-0}" -gt 0 ] && note info "journal also shows ${DOWNLOADS} k3s fetch line(s)"

  if [ "${PKGOPS:-1}" -eq 0 ]; then
    note ok "no package transaction during boot"
  else
    note FAIL "ran ${PKGOPS} package operation(s) at boot"
    FAIL=1
  fi

  if [ -z "$want" ]; then
    note info "runs ${GOT_VERSION:-nothing}; no image version to compare against"
  elif [ "${GOT_VERSION:-}" = "$want" ]; then
    note ok "runs ${GOT_VERSION}, which is what its image ships"
  else
    note FAIL "runs ${GOT_VERSION:-nothing}, image ships ${want}"
    FAIL=1
  fi

  # Exactly one role. Both active means an image that boots into a cluster;
  # neither means a node that never started.
  case "${SERVER:-},${AGENT:-}" in
    active,active)     note FAIL "both k3s units are active"; FAIL=1 ;;
    active,*)          note ok   "control plane: k3s active, k3s-agent ${AGENT:-inactive}" ;;
    *,active)          note ok   "agent: k3s-agent active, k3s ${SERVER:-inactive}" ;;
    *)                 note FAIL "neither k3s unit is active (k3s=${SERVER:-?} k3s-agent=${AGENT:-?})"; FAIL=1 ;;
  esac

  [ -n "$READY_AT" ] && note info "$READY_AT"
# `hcloud server list` has no image column -- it is not one of the fields
# the CLI will format -- so the id comes from describe, one call per server.
# Which is the point of reading it at all: the image a server BOOTED, not
# whichever golden image happens to be newest now.
done < <(hcloud server list -o noheader -o columns=name 2>/dev/null \
         | awk -v c="$CLUSTER" '$1 ~ "^"c {print $1}' \
         | while read -r n; do
             img="$(hcloud server describe "$n" -o json 2>/dev/null \
               | python -c "import json,sys; print(json.load(sys.stdin).get('image',{}).get('id',''))" 2>/dev/null)"
             printf '%s\t%s\n' "$n" "$img"
           done)

echo ""
if [ "$CHECKED" -eq 0 ]; then
  echo "  no servers checked."
  exit 1
fi
echo "=================================================================="
if [ "$FAIL" -ne 0 ]; then
  echo " FAILED — $CHECKED node(s) checked"
  exit 1
fi
if [ "$GAPS" -gt 0 ]; then
  echo " PASSED with $GAPS gap(s) — $CHECKED node(s) checked"
  echo ""
  echo " A gap is a node still on the base OS snapshot, which has to install"
  echo " k3s because its image ships none. Not a regression; not done either."
  exit 0
fi
echo " PASSED — $CHECKED node(s) booted their image and installed nothing"
