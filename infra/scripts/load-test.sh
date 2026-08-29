#!/usr/bin/env bash
#
# Runs the k6 baseline inside the cluster (T-5.6).
#
# WHY IN-CLUSTER RATHER THAN FROM A LAPTOP OR A RUNNER
#
# The number this produces is an autoscaling threshold. An HPA scales on pod
# CPU, so the question is what the pods can serve -- and driving load from
# outside measures Cloudflare, the tunnel, ingress-nginx and whatever the
# operator's home connection is doing, all of which have more variance than the
# thing being measured.
#
# It also means k6 needs no credentials of its own: the gateway and Keycloak are
# both reachable by Service DNS, and the token comes from the same public
# smoke-tests client the smoke suite uses.
#
# HOW THE RESULT IS A GATE RATHER THAN A REPORT
#
# The thresholds live in the k6 script, and k6 exits non-zero when one is
# breached. This script propagates that. A load test whose result is a number
# somebody reads is a load test nobody reads.
#
# Usage:
#   ./load-test.sh [env]
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"

# Which scenario. Defaults to the baseline so every existing caller is
# unchanged; `make load-ratelimit` passes ratelimit.js (T-8.3, #61). Taking a
# script rather than copying this harness means one place knows how to run k6
# in-cluster, and a second scenario cannot drift from the first in how it is
# launched.
SCRIPT="${2:-baseline.js}"
NAMESPACE="${LOAD_NAMESPACE:-apps}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.55.0}"
JOB="k6-$(basename "$SCRIPT" .js)-$(date -u +%Y%m%d%H%M%S)"

if [ ! -f "infra/load/$SCRIPT" ]; then
  echo "error: no scenario at infra/load/$SCRIPT" >&2
  echo "  available:" >&2
  ls infra/load/*.js 2>/dev/null | sed 's|.*/|    |' >&2
  exit 1
fi

# This project's kubeconfig, unconditionally. An inherited KUBECONFIG points at
# whatever cluster the operator last used, and this one generates load.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

[ -f "$KUBECONFIG" ] || {
  echo "error: no kubeconfig at $KUBECONFIG — run: make up ENV=${ENVIRONMENT}" >&2
  exit 1
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "error: no ${NAMESPACE} namespace — is the cluster up?" >&2
  exit 1
}

echo "=================================================================="
echo " k6 ${SCRIPT}: ${ENVIRONMENT}"
echo " k6 ${K6_IMAGE}, in-cluster, against the gateway Service"
echo "=================================================================="

# The script goes in as a ConfigMap rather than baked into an image, so changing
# a scenario is a commit rather than a build.
CM="${JOB}-script"
kubectl -n "$NAMESPACE" create configmap "$CM" --from-file="${SCRIPT}=infra/load/${SCRIPT}" >/dev/null || {
  echo "error: could not create the script ConfigMap" >&2
  exit 1
}

cleanup() {
  kubectl -n "$NAMESPACE" delete configmap "$CM" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels: {app.kubernetes.io/name: k6-load}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels: {app.kubernetes.io/name: k6-load}
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          args: ["run", "/scripts/${SCRIPT}"]
          resources:
            requests: {cpu: 200m, memory: 256Mi}
            limits:   {memory: 512Mi}
          volumeMounts:
            - {name: scripts, mountPath: /scripts}
      volumes:
        - name: scripts
          configMap: {name: ${CM}}
EOF

echo "  job ${JOB} submitted; streaming…"
echo ""

# --timeout well past the scenario duration. The scenarios run about 3m15s
# together; a shorter wait here reports a failure that is only impatience.
kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "job-name=${JOB}" --timeout=180s >/dev/null 2>&1

kubectl -n "$NAMESPACE" logs -f "job/${JOB}" 2>/dev/null | tee "${JOB}.log"

# The exit code of `kubectl logs` says nothing about k6. Read the Job.
for _ in $(seq 1 30); do
  succeeded="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  failed="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  [ -n "$succeeded" ] || [ -n "$failed" ] && break
  sleep 2
done

echo ""
echo "=================================================================="
if [ "${succeeded:-0}" = "1" ]; then
  echo "PASSED — every threshold in infra/load/${SCRIPT} held."
  echo "  full output: ${JOB}.log"
  echo "=================================================================="
  exit 0
fi

echo "FAILED — a threshold in ${SCRIPT} was breached, or k6 could not run."
echo ""
echo "  k6 exits non-zero on a breached threshold, which is what makes this a"
echo "  gate. Read the THRESHOLDS block above: a line marked with a cross names"
echo "  the SLO that moved."
echo ""
echo "  If every threshold passed and this still failed, k6 did not start --"
echo "  usually the token fetch in setup(), which fails the whole run rather"
echo "  than silently measuring unauthenticated 401s."
echo "  full output: ${JOB}.log"
echo "=================================================================="
exit 1
