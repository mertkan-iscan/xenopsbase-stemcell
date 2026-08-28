#!/usr/bin/env bash
#
# Waits until the cluster is SERVING, and says which part is not yet.
#
# WHY THIS IS NOT JUST `terraform apply`
#
# `cluster-apply` finishing means Terraform is done. It does not mean the stack
# is up: Argo has only just been handed the root Application at that point, and
# Postgres, Keycloak and the services come up over the following few minutes.
#
# T-1.7 asks for "nothing to a serving stack, unattended". The gap between those
# two is where every interesting failure lives -- an image that will not pull, a
# database that will not recover, a realm that will not import -- and all of
# them present as "the apply succeeded" if nobody waits.
#
# THREE GATES, IN ORDER
#
#   nodes     every node Ready. Nothing else can be true first.
#   platform  every Argo Application Healthy. This is what "converged" means.
#   edge      the public hostname answers. Proves the tunnel, the ingress and
#             the gateway are all live -- which nothing inside the cluster can.
#
# Each reports what it is waiting for, every time, so an unattended run leaves a
# log that says where it stopped rather than just "timed out".
#
# Usage:
#   ./wait-for-stack.sh <environment> [timeout-seconds]
set -uo pipefail

ENVIRONMENT="${1:-dev}"
DEADLINE_SECONDS="${2:-900}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# THIS project's kubeconfig, unconditionally. An inherited KUBECONFIG is ignored
# on purpose, and that is a fix rather than a preference.
#
# Written as ${KUBECONFIG:-...} first, which looked considerate and was not. The
# machine this was developed on carries a user-level KUBECONFIG pointing at an
# unrelated project's cluster. `make up` therefore asked a different, stopped
# cluster how it was doing; every call blocked until its timeout, and the gate
# reported "0/0 nodes Ready" for twenty minutes about a cluster that was healthy
# the entire time.
#
# The worse version is the one that did not happen here: if the inherited
# cluster is RUNNING, this reports a serving stack belonging to somebody else's
# project and `make up` exits 0.
#
# Same reasoning as TF_GIT in the Makefile and java-home.sh: a project-scoped
# tool uses the project's settings rather than inheriting a developer's global
# state to decide what it is talking to.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

if [ ! -f "$KUBECONFIG" ]; then
  echo "error: no kubeconfig at $KUBECONFIG — run: make kubeconfig ENV=$ENVIRONMENT" >&2
  exit 1
fi

# Read from the tfvars rather than passed in, so this cannot disagree with what
# was actually deployed.
HOSTVARS="$ROOT/infra/terraform/edge/env/${ENVIRONMENT}.tfvars"
HOSTNAME_="$(grep -oE '^hostname[[:space:]]*=[[:space:]]*"[^"]+"' "$HOSTVARS" 2>/dev/null | cut -d'"' -f2)"

started=$(date +%s)
elapsed() { echo $(( $(date +%s) - started )); }
deadline_passed() { [ "$(elapsed)" -ge "$DEADLINE_SECONDS" ]; }

say() { printf '  [%4ss] %s\n' "$(elapsed)" "$*"; }

# Every kubectl call is time-boxed.
#
# Not defensive decoration: an unbounded `kubectl get` against a control plane
# reached over the tailnet stalled once during development, and the loop sat
# there well past its own deadline, because the deadline is only checked
# BETWEEN iterations. A gate that can block forever inside one iteration is not
# unattended, whatever the timeout argument says.
kc() { timeout 20 kubectl "$@"; }

echo
echo "Waiting for the $ENVIRONMENT stack (timeout ${DEADLINE_SECONDS}s)"
echo

# ---------------------------------------------------------------- nodes

# HOW MANY NODES THE CONFIGURATION DECLARES, not how many happen to exist
# (T-7.11, #293).
#
# This gate used to compare the cluster to itself: `ready == total`, both
# counted from `kubectl get nodes`. A number compared to itself cannot fail.
# With both workers destroyed and being recreated, one control plane out of one
# control plane passed:
#
#   [  6s] nodes      0/0 Ready
#   [ 23s] nodes      1/1 Ready
#   STACK SERVING in 27s
#
# `make up` reported serving with two of three nodes missing. The platform then
# rescheduled onto a schedulable cx23 and the control plane reached load average
# 32 with its API refusing connections.
#
# The count comes from terraform rather than from parsing tfvars, because the
# arithmetic (sum over both nodepool lists) belongs where the variables are.
EXPECTED_NODES="$(cd "$ROOT/infra/terraform/cluster" && terraform output -raw expected_node_count 2>/dev/null)"

# NO FALLBACK TO COUNTING THE CLUSTER. That is the bug, and a fallback would
# reintroduce it exactly when state is unreadable -- which is also when the
# cluster is least likely to be what you think it is.
if ! printf '%s' "$EXPECTED_NODES" | grep -qE '^[0-9]+$'; then
  echo "error: cannot read expected_node_count from terraform." >&2
  echo "       Without it this gate would compare the cluster to itself and" >&2
  echo "       pass on any number of nodes, including one (#293)." >&2
  echo "       run: source ~/.xenopsbase.env" >&2
  exit 1
fi

while :; do
  total=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')

  # `>=` on the declared count, not `==`. Autoscaled nodes are created outside
  # terraform and their number follows load, so extras are legitimate -- but
  # every one of them still has to be Ready, or the cluster is mid-something.
  if [ "${total:-0}" -ge "$EXPECTED_NODES" ] && [ "${ready:-0}" = "${total:-0}" ]; then
    say "nodes      $ready/$total Ready (declared $EXPECTED_NODES)"
    break
  fi
  say "nodes      ${ready:-0}/${total:-0} Ready, declared $EXPECTED_NODES"
  if deadline_passed; then
    echo "TIMED OUT waiting for nodes: $ready Ready of $total registered, $EXPECTED_NODES declared." >&2
    kc get nodes >&2 2>/dev/null
    exit 1
  fi
  sleep 15
done

# ------------------------------------------------------------- platform

# Healthy, not Synced. A CloudNativePG Cluster reports OutOfSync forever because
# the operator writes its own defaults back into the spec, so gating on Synced
# would wait for something that is never going to happen.
while :; do
  apps=$(kc get applications -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  healthy=$(kc get applications -A --no-headers 2>/dev/null | awk '$4=="Healthy"' | wc -l | tr -d ' ')

  # More than one, because immediately after the apply only the root exists and
  # it is briefly Healthy on its own -- which would pass this gate before any
  # child had been created.
  if [ "${apps:-0}" -gt 1 ] && [ "$healthy" = "$apps" ]; then
    say "platform   $healthy/$apps applications Healthy"
    break
  fi
  say "platform   ${healthy:-0}/${apps:-0} applications Healthy"
  if deadline_passed; then
    echo "" >&2
    echo "TIMED OUT after ${DEADLINE_SECONDS}s waiting for the platform. Not Healthy:" >&2
    kc get applications -A --no-headers 2>/dev/null | awk '$4!="Healthy"' >&2

    # WHICH OF THE TWO THIS IS (T-3.24, #279).
    #
    # The message used to stop at the list above, and a list of unhealthy
    # Applications reads identically whether the stack is three minutes from
    # converging or will never converge without a human. That is the shape this
    # repository keeps meeting: a control that cannot distinguish a problem from
    # normal operation gets ignored, and then it is not a control.
    #
    # A pod being restarted is not converging -- something starts, fails, and is
    # backed off, and waiting longer only repeats it. A pod that is pulling,
    # initialising or waiting on a dependency has not failed at all, and the
    # initContainer T-3.24 added makes that second state both common and
    # correct: Init:0/1 while Keycloak comes up is the fix working, not a fault.
    # Gathered ONCE, into a variable. Asking twice raced a cluster that changes
    # between calls and produced a count that disagreed with the list under it.
    #
    # No line continuations anywhere in here. The previous two attempts at this
    # block were both broken by an escape that did not survive being written
    # into the file -- first a newline inside the awk program, which killed awk
    # on an unterminated string, then a backslash-n where a continuation was
    # meant, which fed `n` to kubectl as an argument and produced nothing at
    # all. Both times the list was empty in the one run that needed it.
    notrunning=$(kc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed" {print sprintf("  %-14s %-44s %-28s restarts=%s", $1, $2, $4, $5)}')
    listed=$(printf '%s' "$notrunning" | grep -c '[^[:space:]]')
    failing=$(printf '%s' "$notrunning" | grep -Ec 'CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|CreateContainerConfigError')

    echo "" >&2
    if [ "${listed:-0}" -gt 0 ]; then
      echo "Pods that are not Running:" >&2
      echo "$notrunning" >&2
      echo "" >&2
    fi

    if [ "${failing:-0}" -gt 0 ]; then
      echo "NOT GOING TO FINISH: ${failing} pod(s) above are failing and being backed off." >&2
      echo "  Waiting longer repeats the same failure. Read them:" >&2
      echo "    kubectl logs -n <namespace> <pod> --previous" >&2
    elif [ "${listed:-0}" -eq 0 ]; then
      # THE CASE THAT READ AS SUCCESS (T-2.24, #327).
      #
      # An Application is unhealthy and yet every pod in the cluster is Running
      # or Completed. Nothing is failing, and -- the part that matters -- nothing
      # is PENDING either. So the workload the Application declares was never
      # created, which is a controller that has not reconciled rather than a slow
      # start, and no amount of waiting changes it.
      #
      # The first version of this classifier only looked at pod states, found
      # nothing wrong, and printed STILL CONVERGING about a cluster that never
      # would. That is the failure this whole message exists to prevent, so it is
      # worth stating plainly: an empty list is not evidence of health, it is
      # evidence that nothing is even trying.
      echo "NOTHING IS EVEN STARTING: no pod is failing, and none is pending either." >&2
      echo "  Every pod in the cluster is Running or Completed while an Application above is" >&2
      echo "  not Healthy, which means the workload it declares was never created. That is a" >&2
      echo "  controller or operator that has not reconciled, not a slow start." >&2
      echo "  Look at what the Application owns, and at whatever should have acted on it:" >&2
      echo "    kubectl -n argocd get app <name> -o json | jq .status.resources" >&2
      echo "  #327 is exactly this shape: a Prometheus CR carrying no status at all and no" >&2
      echo "  StatefulSet behind it, on a cluster where every single pod was healthy." >&2
    else
      echo "STILL CONVERGING: nothing is crash-looping or failing to pull." >&2
      echo "  Every pod above is pulling, initialising, or waiting on a dependency -- slow" >&2
      echo "  rather than broken. A cold rebuild reached SERVING in 442s when it was last" >&2
      echo "  measured (#289), against the ${DEADLINE_SECONDS}s allowed here." >&2
      echo "  If that has genuinely grown, raise UP_TIMEOUT rather than reading this as a" >&2
      echo "  failure -- but check first that it grew for a reason." >&2
    fi
    exit 1
  fi
  sleep 20
done

# ----------------------------------------------------------------- edge

if [ -z "$HOSTNAME_" ]; then
  say "edge       skipped, no hostname in $(basename "$HOSTVARS")"
else
  while :; do
    # 302 is success here: an unauthenticated browser request is redirected to
    # Keycloak, which means the tunnel, the ingress and the gateway are all
    # answering. Anything 5xx or a connection failure is not.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' --max-time 15 "https://${HOSTNAME_}/" 2>/dev/null || echo 000)
    case "$code" in
      2??|3??)
        say "edge       https://${HOSTNAME_} answers $code"
        break
        ;;
    esac
    say "edge       https://${HOSTNAME_} answers ${code}"
    if deadline_passed; then
      echo "TIMED OUT waiting for the public endpoint (last status ${code})." >&2
      exit 1
    fi
    sleep 15
  done
fi

echo
echo "STACK SERVING in $(elapsed)s"
