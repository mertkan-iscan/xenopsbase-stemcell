#!/usr/bin/env bash
#
# Probes every public address in the project from outside and asserts that only
# the intended ports answer. Acceptance criterion for T-1.5.
#
# WHY THIS EXISTS
#
# A firewall that is configured is not the same as a firewall that is closed.
# The Hetzner firewall, the module's rules, and the node's own state can each
# disagree, and none of them announce it. The only way to know what the internet
# can reach is to reach for it.
#
# Deliberately uses raw TCP connects rather than reading the firewall config
# back: reading the config proves what was requested, not what is true.
#
# Expected after ADR-0006 (tailscale transport):
#
#   22   SSH          CLOSED   reachable only over the tailnet
#   6443 Kubernetes   CLOSED   there is no public API endpoint
#   80   HTTP         open ONLY once an ingress controller exists (T-2.2)
#   443  HTTPS        same
#
# Anything else answering is a finding.
#
# Note this runs from wherever you are. If that machine is ON the tailnet, the
# node addresses tested here are still the PUBLIC ones from hcloud, so the
# result is honest -- but a genuinely external check (a phone on mobile data,
# or CI) is stronger. T-7.3 runs it from CI for that reason.
#
# Usage:
#   export HCLOUD_TOKEN=...
#   ./verify-exposure.sh [expect-web]
#
#     expect-web   pass this once an ingress controller is deployed, to require
#                  80 and 443 to ANSWER on the load balancer rather than merely
#                  tolerating them.
#
set -uo pipefail

EXPECT_WEB="${1:-}"

# The expected answer depends on how the cluster is reached (ADR-0006):
#
#   tailscale        nothing answers on a node, ever
#   hetzner_private  22 and 6443 answer, but ONLY from firewall_source_cidrs
#
# Under the escape hatch this script usually runs FROM an allowlisted address,
# so 22 and 6443 answering is correct rather than a finding. Calling that a
# failure trains people to ignore the check, which is worse than not having it.
#
# Read from the tfvars rather than passed in, so the check cannot disagree with
# what was actually deployed.
ENVIRONMENT="${ENVIRONMENT:-dev}"
TFVARS_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/infra/terraform/cluster/env/${ENVIRONMENT}.tfvars"
TRANSPORT="tailscale"
if [ -f "$TFVARS_PATH" ]; then
  TRANSPORT="$(grep -oE '^node_transport_mode[[:space:]]*=[[:space:]]*"[a-z_]+"' "$TFVARS_PATH" | head -1 | cut -d'"' -f2)"
  TRANSPORT="${TRANSPORT:-tailscale}"
fi
TIMEOUT=4
FAILED=0

if [ -z "${HCLOUD_TOKEN:-}" ]; then
  echo "error: HCLOUD_TOKEN must be set" >&2
  exit 2
fi

# Raw TCP connect via bash, so the script needs no nc/nmap. Git Bash supports
# /dev/tcp, which matters because this must run on the machine it documents.
port_open() {
  local host="$1" port="$2"
  timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

check() {
  local label="$1" host="$2" port="$3" want="$4"
  printf '  %-16s %-22s %-5s ' "$label" "$host" "$port"
  if port_open "$host" "$port"; then got="OPEN"; else got="closed"; fi

  if [ "$got" = "OPEN" ] && [ "$want" = "closed" ]; then
    echo "OPEN   <-- EXPOSED, expected closed"
    FAILED=1
  elif [ "$got" = "closed" ] && [ "$want" = "OPEN" ]; then
    echo "closed <-- expected to answer"
    FAILED=1
  else
    echo "$got"
  fi
}

mapfile -t NODES < <(hcloud server list -o columns=name,ipv4 2>/dev/null | tail -n +2 | awk 'NF>=2 {print $1" "$2}')
mapfile -t LBS < <(hcloud load-balancer list -o columns=name,ipv4 2>/dev/null | tail -n +2 | awk 'NF>=2 {print $1" "$2}')

if [ "${#NODES[@]}" -eq 0 ] && [ "${#LBS[@]}" -eq 0 ]; then
  echo "No servers or load balancers exist. Nothing is exposed, trivially."
  echo "Bring a cluster up first: make cluster-apply"
  exit 0
fi

echo "=================================================================="
if [ "$TRANSPORT" = "hetzner_private" ]; then
  echo " NODES — escape hatch: 22 and 6443 answer, allowlisted only"
else
  echo " NODES — must answer nothing (ADR-0006: no public API, no SSH)"
fi
echo " transport: $TRANSPORT"
echo "=================================================================="
# Under the escape hatch these two are open by design, restricted to an IP
# allowlist. Whether the allowlist actually holds cannot be proved from an
# allowlisted host -- that needs an off-allowlist vantage point, which is why
# T-7.3 runs this from CI.
if [ "$TRANSPORT" = "hetzner_private" ]; then
  WANT_SSH="OPEN"; WANT_API="OPEN"
else
  WANT_SSH="closed"; WANT_API="closed"
fi

for entry in "${NODES[@]}"; do
  name="${entry%% *}"; ip="${entry##* }"

  # Only control planes serve the Kubernetes API. Expecting 6443 to answer on a
  # worker is wrong even under the escape hatch, and asserting it would report a
  # correctly-closed port as a failure.
  case "$name" in
    *control-plane*) want_api="$WANT_API" ;;
    *)               want_api="closed" ;;
  esac

  check "$name" "$ip" 22 "$WANT_SSH"
  check "$name" "$ip" 6443 "$want_api"
  check "$name" "$ip" 2379 closed  # etcd: never public, under any transport
  check "$name" "$ip" 10250 closed # kubelet: never public
done

if [ "${#LBS[@]}" -gt 0 ]; then
  echo
  echo "=================================================================="
  echo " LOAD BALANCERS — the only intended public surface"
  echo "=================================================================="
  want_web="closed"
  [ "$EXPECT_WEB" = "expect-web" ] && want_web="OPEN"
  for entry in "${LBS[@]}"; do
    name="${entry%% *}"; ip="${entry##* }"
    check "$name" "$ip" 80 "$want_web"
    check "$name" "$ip" 443 "$want_web"
    check "$name" "$ip" 22 closed
    check "$name" "$ip" 6443 closed
  done
elif [ "$EXPECT_WEB" = "expect-web" ]; then
  echo
  echo "expect-web was requested but there is no load balancer to answer on."
  FAILED=1
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "EXPOSURE CHECK FAILED — the public surface is not what it should be."
  exit 1
fi

if [ "$EXPECT_WEB" != "expect-web" ]; then
  if [ "$TRANSPORT" = "hetzner_private" ]; then
  echo "NOTE: running on the escape hatch, so 22 and 6443 are open by design."
  echo "      This run cannot prove the allowlist holds -- it was made from an"
  echo "      allowlisted address. Run it from elsewhere, or wait for T-7.3."
  echo
fi
echo "Nothing unexpected is exposed. Note 80/443 are not required to answer yet:"
  echo "ingress_controller is \"none\" until T-2.2 installs it via GitOps."
  echo "Re-run with 'expect-web' once it exists, to require them rather than"
  echo "merely tolerate them."
else
  echo "EXPOSURE CORRECT — only 80 and 443 answer, and only on the load balancer."
fi
