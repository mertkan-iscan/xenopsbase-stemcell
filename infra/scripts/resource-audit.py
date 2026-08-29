#!/usr/bin/env python3
"""What every namespace BOOKS against what it USES, measured (T-2.26, #340).

WHY THIS IS A SCRIPT AND NOT A MEASUREMENT SOMEBODY TOOK ONCE

T-2.23 (#306) measured request-versus-actual per namespace by hand and recorded
the table in dev.tfvars. Two of its figures were wrong, in ways nobody could see
from the table:

  keycloak booked 2918Mi        1700Mi of that was a SUCCEEDED Job pod
  the apps booked 848 + 656Mi   both counted an initContainer twice

Neither number was a typo. Both came from summing what `kubectl get pods` prints
without applying the two rules the kubelet applies, and the resulting figure --
"the cluster over-declares by 3.3GB, and is 97% booked at HPA ceiling" -- was
then used to reason about node sizing.

So the arithmetic lives here, where it can be re-run and checked, rather than in
a comment nobody can re-derive.

THE TWO RULES, WHICH ARE WHAT MAKE A NAIVE SUM WRONG

1. A pod that is not Running or Pending reserves NOTHING. A Succeeded Job is
   still in `kubectl get pods` output; the scheduler released its reservation
   when it finished. keycloak's realm-import Job is the case that caused this:
   1700Mi of a 2918Mi namespace, held by a pod that exited.

2. A pod's memory request is
       max( sum(containers), max(each initContainer) )
   not the sum of everything. initContainers run to completion BEFORE the app
   containers start, so their requests overlap rather than add. Every core and
   gateway pod carries the wait-for-oidc initContainer (T-3.24, #279), so the
   naive sum overstates each of them.

CROSS-CHECKED, NOT TRUSTED

The kubelet publishes its own answer in `kubectl describe node` under Allocated
resources. This script computes the same figure from the pod specs and prints
both. If they disagree, the snapshot moved under it -- pods restart, DaemonSets
reschedule -- and the run should be repeated rather than reported. A measurement
that cannot be checked against the thing it is measuring is how #306's went
unnoticed. Related: the same trap in reverse cost a set of load-test comparisons
(see the cluster-autoscaler note in dev.tfvars).

WHAT `used` IS, AND WHAT IT IS NOT

`kubectl top` reports a short trailing window from metrics-server, so it is a
sample and not a steady state: a pod that restarted in the last minute reads low
and a JVM mid-GC reads high. It answers "roughly what is this holding right
now". Do not size a request from one run of it -- take a few, minutes apart, and
prefer the highest.

Usage:
    export KUBECONFIG="$PWD/infra/terraform/cluster/kubeconfig"   # NOT the env var
    ./resource-audit.py                # the table
    ./resource-audit.py --factor 1.25  # flag namespaces outside that factor
"""

import json
import re
import subprocess
import sys
from collections import Counter

MI = 1024 * 1024

# T-2.23 (#306) set Argo CD's requests at 1.25x measured steady state, rounded
# up, and wrote the factor down "because a number nobody can re-derive is a
# number nobody can check". Same factor here, so the two agree.
DEFAULT_FACTOR = 1.25

SUFFIX = {"": 1, "k": 10**3, "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12,
          "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4}


def quantity(text):
    """Kubernetes quantity to bytes. '512Mi', '1Gi', '2000k', '' -> int."""
    if not text:
        return 0
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([EPTGMK]i?|[kmg])?", str(text).strip())
    if not match:
        raise ValueError("cannot parse quantity %r" % text)
    return int(float(match.group(1)) * SUFFIX[match.group(2) or ""])


def kubectl(*args):
    result = subprocess.run(
        ["kubectl", *args], capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        print("error: kubectl %s failed:\n%s" % (" ".join(args), result.stderr.strip()),
              file=sys.stderr)
        print("\nIs KUBECONFIG pointing at the dev cluster? The shell's value is\n"
              "usually a stale local k3d config; this cluster's is\n"
              "  infra/terraform/cluster/kubeconfig  (written by `make kubeconfig`).",
              file=sys.stderr)
        sys.exit(1)
    return result.stdout


def effective_request(pod):
    """Rule 2: init containers overlap with app containers, they do not add."""
    containers = sum(
        quantity(c.get("resources", {}).get("requests", {}).get("memory"))
        for c in pod["spec"].get("containers", [])
    )
    inits = [
        quantity(c.get("resources", {}).get("requests", {}).get("memory"))
        for c in pod["spec"].get("initContainers", [])
    ]
    return max([containers] + inits)


def main():
    factor = DEFAULT_FACTOR
    if "--factor" in sys.argv:
        factor = float(sys.argv[sys.argv.index("--factor") + 1])

    pods = json.loads(kubectl("get", "pods", "-A", "-o", "json"))["items"]

    booked, used, count, per_node = Counter(), Counter(), Counter(), Counter()
    released = 0

    for pod in pods:
        namespace = pod["metadata"]["namespace"]
        request = effective_request(pod)

        # Rule 1.
        if pod["status"].get("phase") not in ("Running", "Pending"):
            released += request
            continue

        booked[namespace] += request
        count[namespace] += 1
        per_node[pod["spec"].get("nodeName") or "(unscheduled)"] += request

    for line in kubectl("top", "pods", "-A", "--no-headers").splitlines():
        fields = line.split()
        if len(fields) >= 4:
            used[fields[0]] += quantity(fields[3])

    print("Memory: what each namespace books against what it is using.")
    print("Booked counts Running and Pending pods only, at the pod's effective request.\n")
    print("%-16s%5s%10s%10s%8s   %s" % ("namespace", "pods", "booked", "used", "ratio", ""))

    total_booked = total_used = 0
    for namespace in sorted(booked):
        b, u = booked[namespace] / MI, used[namespace] / MI
        total_booked += b
        total_used += u
        ratio = (u / b) if b else 0
        # Three states, because "wrong" has two directions and they are not
        # equally bad. Booking less than a pod uses is what gets it evicted;
        # booking more only wastes capacity the scheduler then refuses to
        # anyone else.
        note = ""
        if not b:
            note = "declares nothing (BestEffort - T-2.25, #339)"
        elif u > b:
            note = "UNDER by %.0fMi - using more than it books" % (u - b)
        elif b < u * factor:
            note = "tight - under the %.2fx target by %.0fMi" % (factor, u * factor - b)
        else:
            note = "over by %.0fMi against %.2fx" % (b - u * factor, factor)
        print("%-16s%5d%9.0fMi%9.0fMi%8.2f   %s"
              % (namespace, count[namespace], b, u, ratio, note))

    print("%-16s%5d%9.0fMi%9.0fMi%8.2f" % ("TOTAL", sum(count.values()),
                                           total_booked, total_used,
                                           total_used / total_booked))
    if released:
        print("\n%.0fMi is held by pods that are neither Running nor Pending and is "
              "NOT counted.\nA naive sum would have added it. See rule 1 in this "
              "file's header." % (released / MI))

    # ---------------------------------------------------------------------
    # The cross-check. The kubelet already knows the answer; this asserts that
    # the arithmetic above reproduces it rather than assuming it does.
    print("\nAgainst the kubelet's own view (kubectl describe node):\n")
    drift = False
    for node in sorted(per_node):
        if node == "(unscheduled)":
            continue
        described = kubectl("describe", "node", node)
        found = re.search(r"Allocated resources:.*?\n\s+memory\s+(\S+)\s",
                          described, re.S)
        theirs = quantity(found.group(1)) if found else 0
        ours = per_node[node]
        agree = abs(theirs - ours) < MI
        drift = drift or not agree
        print("  %-38s%7.0fMi computed   %7.0fMi kubelet   %s"
              % (node, ours / MI, theirs / MI, "ok" if agree else "DRIFTED"))

    if drift:
        print("\nThe snapshot moved while it was being read -- a pod restarted or a\n"
              "DaemonSet rescheduled between the two calls. Run it again; do not\n"
              "report figures from a run that says DRIFTED.")
        return 1

    print("\nAgreed. These figures are the kubelet's, arrived at independently.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
