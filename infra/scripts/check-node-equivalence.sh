#!/usr/bin/env bash
#
# A static node and an autoscaled node must be the same node (T-1.19, #251).
#
# WHY THIS EXISTS -- AND WHAT CHANGED UNDER IT (T-1.23, #282)
#
# It was written when the two were built by genuinely different mechanisms:
# static agents came from kube-hetzner's cloud-init, which downloads and
# installs k3s at boot, and autoscaled nodes came from the golden image and a
# ~1.4KB bootstrap. Two paths that had to stay equivalent with nothing enforcing
# it, drifting on the next k3s bump or kubelet argument change -- and the
# symptom is one flaky node, not an error.
#
# That is no longer the shape of the risk. #282 moved static agents onto the
# same image and the same templates/node-bootstrap.yaml.tpl, so BOTH NODES ARE
# NOW BUILT THE SAME WAY, and this became a weaker check than the one it
# replaced. It is deliberately kept, because one thing still differs: HOW the
# same bootstrap reaches the node.
#
#   static      terraform renders the template and passes it as user_data,
#               on every apply
#   autoscaled  the SAME rendered bytes are base64'd into a Secret by bootstrap
#               stage 3, and the autoscaler passes them as cloudInit
#
# The second copy is applied once per apply and then lives in the cluster. A
# stage-3 apply that failed, or a Secret edited by hand, leaves the autoscaler
# creating nodes from a bootstrap the repository no longer describes -- and
# nothing else would notice, because the template it drifted from still renders
# correctly.
#
# So it does not check that the paths are the same; it checks that the NODES
# they produce are, which is the property that matters and the one that survived
# the paths converging.
#
# WHAT IS COMPARED, AND WHY EACH ONE
#
#   k3s version    a version skew between nodes is the classic silent cluster
#                  fault: it works until a feature gate differs.
#   SELinux mode   read from the kernel, not the config file. Trading
#                  enforcement away to save user_data bytes was considered and
#                  rejected on #22; this is what stops it returning by accident.
#   SELinux policy loaded modules, not files on disk. Both nodes get them
#                  compiled into the golden image at build time now; the check
#                  is that both actually LOADED them, which is a property of the
#                  boot and not of the image.
#   kubelet args   parsed from config.yaml as a SET, not grepped. These decide
#                  reserved capacity and the cloud provider, so a difference
#                  changes how much of a node is schedulable -- quietly.
#
# Usage:
#   ./check-node-equivalence.sh [env]
#
# Needs a cluster with at least one static agent and one autoscaled node. With
# no autoscaled node it says so and skips, rather than passing: "nothing to
# compare" and "they match" are different statements.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

export KUBECONFIG="infra/terraform/cluster/kubeconfig"
export MSYS_NO_PATHCONV=1

if [ ! -s "$KUBECONFIG" ]; then
  echo "error: no kubeconfig at $KUBECONFIG — is the cluster up?" >&2
  exit 1
fi

PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"

# Overridable so the comparison can be pointed at any two nodes. That is how
# this check was proved capable of FAILING -- run against a worker and the
# control plane, which genuinely differ, it reports the differences. A gate
# only ever seen passing is not known to be a gate.
STATIC="${NODE_A:-$(kubectl get nodes -o name 2>/dev/null | grep -- '-worker-' | head -1 | cut -d/ -f2)}"
AUTO="${NODE_B:-$(kubectl get nodes -o name 2>/dev/null | grep -- '-autoscaled-' | head -1 | cut -d/ -f2)}"

echo "=================================================================="
echo " Static vs autoscaled node"
echo "=================================================================="
echo "  static     : ${STATIC:-<none>}"
echo "  autoscaled : ${AUTO:-<none>}"
echo ""

# IT USED TO EXIT 0 HERE, AND THAT WAS THE PROBLEM (T-1.27, #288).
#
# An autoscaled node exists only while something needs one, and dev sits at
# min_nodes = 0. So on every healthy cluster this printed SKIPPED and returned
# success, and the check that was meant to catch two node classes drifting
# apart had never compared anything except when somebody forced a scale-up by
# hand. A green check that has never run is worse than a missing one: it
# occupies the place where a real check would be noticed as absent.
#
# So it now compares what it CAN and names what it cannot.
#
#   both workers present   compare them to each other. They are built by the
#                          same path since #282, so this is a weaker claim --
#                          but it is the claim that the path is DETERMINISTIC,
#                          and a bootstrap that renders differently per node is
#                          exactly the kind of thing nothing else would see.
#   an autoscaled node too  compare across the classes, which is the original
#                          and stronger claim: terraform creates one, the
#                          autoscaler creates the other, and they differ in how
#                          the network and the firewall are attached.
#
# Only a cluster with fewer than two comparable nodes skips, and that is a
# broken cluster rather than a normal one.
if [ -z "$AUTO" ]; then
  SECOND="$(kubectl get nodes -o name 2>/dev/null | grep -- '-worker-' | sed -n 2p | cut -d/ -f2)"
  if [ -n "$STATIC" ] && [ -n "$SECOND" ]; then
    AUTO="$SECOND"
    MODE="two static agents (no autoscaled node exists; see the note below)"
  fi
else
  MODE="static vs autoscaled"
fi

if [ -z "$STATIC" ] || [ -z "$AUTO" ]; then
  echo "FAILED — fewer than two worker nodes to compare."
  echo ""
  echo "  This is not the old SKIPPED. A cluster with fewer than two workers is"
  echo "  not a normal cluster, and reporting success about it is how #282's"
  echo "  builds looked healthy while one agent had never joined."
  exit 1
fi

echo "  comparing  : ${MODE}"
if [ "${MODE#two static}" != "$MODE" ]; then
  echo ""
  echo "  The stronger comparison needs an autoscaled node, and they exist only"
  echo "  while something needs one. To force one:"
  echo "    kubectl create deployment scale-probe --image=registry.k8s.io/pause:3.9"
  echo "    kubectl set resources deployment scale-probe --requests=cpu=3000m"
  echo "  and delete it afterwards."
fi
echo ""

# Facts are collected on the node itself, through a privileged debug pod, because
# the k3s API reports what a node ADVERTISES and this needs what it actually has.
probe() {
  node="$1"
  kubectl debug "node/$node" --image=busybox:1.36 -q --profile=sysadmin -- \
    chroot /host sh -c '
      /usr/local/bin/k3s --version | head -1 | awk "{print \"k3s=\" \$3}"
      echo "selinux_enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
      echo "policies=$(semodule -l 2>/dev/null | grep -cE "^(kube_hetzner_selinux|k8s_custom_policies)$")"
      echo "--- config ---"
      cat /etc/rancher/k3s/config.yaml 2>/dev/null
    ' >/dev/null 2>&1
  pod="$(kubectl get pods -o name --sort-by=.metadata.creationTimestamp | tail -1)"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "$pod" --timeout=150s >/dev/null 2>&1
  kubectl logs "$pod" 2>/dev/null
  kubectl delete "$pod" --wait=false >/dev/null 2>&1
}

A_RAW="$(probe "$STATIC")"
B_RAW="$(probe "$AUTO")"

if [ -z "$A_RAW" ] || [ -z "$B_RAW" ]; then
  echo "error: could not read one of the nodes." >&2
  exit 1
fi

# Via files, not a pipe. `python - <<'PY'` takes the SCRIPT from stdin, so
# piping the data there as well leaves sys.stdin.read() empty and the parse
# fails with an unpack error that says nothing about the real cause.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$A_RAW" > "$WORK/static"
printf '%s\n' "$B_RAW" > "$WORK/auto"

# Git Bash's /tmp is an MSYS mount that a native Windows python cannot open, so
# the path python is given is not the path the shell just wrote to. The failure
# is a FileNotFoundError naming a file that visibly exists.
if command -v cygpath >/dev/null 2>&1; then
  WORK_PY="$(cygpath -m "$WORK")"
else
  WORK_PY="$WORK"
fi

"$PY_BIN" - "$STATIC" "$AUTO" "$WORK_PY/static" "$WORK_PY/auto" <<'PY'
import io
import re
import sys

static_name, auto_name, a_path, b_path = sys.argv[1:5]
a_raw = io.open(a_path, encoding="utf-8", errors="replace").read()
b_raw = io.open(b_path, encoding="utf-8", errors="replace").read()


def parse(raw):
    head, _, cfg = raw.partition("--- config ---")
    facts = dict(
        line.split("=", 1) for line in head.strip().splitlines() if "=" in line
    )
    # kubelet-arg is a YAML list; take it as a SET so ordering is not a
    # difference. Parsed rather than grepped: `grep -A6 kubelet-arg` also
    # catches whatever key follows it, which on the autoscaled node is
    # node-label -- and reports a difference that is not there. That mistake
    # was made once already while writing this.
    args = set()
    in_block = False
    for line in cfg.splitlines():
        if re.match(r'^"?kubelet-arg"?\s*:', line):
            in_block = True
            continue
        if in_block:
            m = re.match(r'^\s*-\s*"?([^"]+)"?\s*$', line)
            if m:
                args.add(m.group(1))
            else:
                in_block = False
    facts["kubelet_args"] = args
    facts["selinux_cfg"] = "true" if re.search(r'"?selinux"?\s*:\s*true', cfg) else "false"
    return facts


a, b = parse(a_raw), parse(b_raw)

CHECKS = [
    ("k3s version", "k3s"),
    ("SELinux enforcing (kernel)", "selinux_enforce"),
    ("SELinux requested (config)", "selinux_cfg"),
    ("SELinux policies loaded", "policies"),
    ("kubelet arguments", "kubelet_args"),
]

fails = 0
for label, key in CHECKS:
    av, bv = a.get(key), b.get(key)
    same = av == bv
    if not same:
        fails += 1
    print("  %-5s %-28s" % ("ok" if same else "FAIL", label))
    if not same:
        if isinstance(av, set):
            print("          only on %s: %s" % (static_name, sorted(av - bv) or "-"))
            print("          only on %s: %s" % (auto_name, sorted(bv - av) or "-"))
        else:
            print("          %s: %r" % (static_name, av))
            print("          %s: %r" % (auto_name, bv))

print("")
if fails:
    print("=" * 66)
    print(" %d DIFFERENCE(S) — the two bootstrap paths have drifted" % fails)
    print("=" * 66)
    print("  A node built one way is not a node built the other. Fix the")
    print("  golden image or the bootstrap template, not this check.")
    raise SystemExit(1)

print("=" * 66)
print(" EQUIVALENT — %d properties match" % len(CHECKS))
print("=" * 66)
print("  k3s %s, SELinux enforcing, %s policies, %d kubelet args"
      % (a["k3s"], a["policies"], len(a["kubelet_args"])))
PY
