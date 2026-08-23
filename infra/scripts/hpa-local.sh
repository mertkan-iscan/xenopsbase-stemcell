#!/usr/bin/env bash
#
# Rehearses the gateway HPA on a throwaway local k3s cluster (T-2.8).
#
# WHY REHEARSE IT LOCALLY AT ALL
#
# T-2.8 has two halves and they cost very different things. HPAs are free to get
# wrong locally and awkward to get wrong on a cluster somebody is using;
# cluster-autoscaler cannot be rehearsed at all, because it provisions real
# Hetzner servers through their API and a local stand-in would be a test of a
# fake.
#
# So this covers the half that is coverable: does the HPA scale up under load,
# does it scale back down afterwards, and how long does a new JVM replica take
# to be worth having. k3d runs k3s, which is the same distribution as the
# Hetzner cluster, so this is not an approximation of a different thing.
#
# It leaves nothing behind: the cluster is created and destroyed by this script.
#
# Usage:
#   ./hpa-local.sh
#   KEEP=1 ./hpa-local.sh     # leave the cluster up to poke at afterwards
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

CLUSTER="${CLUSTER_NAME:-hpa-test}"
KEEP="${KEEP:-0}"
IMAGE="${GATEWAY_IMAGE:-}"

for tool in k3d kubectl docker python; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required." >&2; exit 1; }
done

# The image the cluster actually runs, so the rehearsal uses what is deployed
# rather than whatever `main` happens to be.
if [ -z "$IMAGE" ]; then
  IMAGE="$(
    python - <<'PY'
import re
text = open('platform/envs/dev/services/kustomization.yaml', encoding='utf-8').read()
block = text.split('- name: ghcr.io/mertkan-iscan/xenopsbase-stemcell/gateway', 1)[1]
print('ghcr.io/mertkan-iscan/xenopsbase-stemcell/gateway@' + re.search(r'digest:\s*(sha256:[0-9a-f]+)', block).group(1))
PY
  )" || { echo "error: could not read the pinned gateway digest." >&2; exit 1; }
fi

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo ""
    echo "  cluster '${CLUSTER}' left running (KEEP=1). Remove it with:"
    echo "    k3d cluster delete ${CLUSTER}"
  else
    echo ""
    echo "  removing the local cluster…"
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1
  fi
}
trap cleanup EXIT INT TERM

echo "=================================================================="
echo " HPA rehearsal, local k3s"
echo " ${IMAGE}"
echo "=================================================================="

k3d cluster delete "$CLUSTER" >/dev/null 2>&1
echo "  creating cluster…"
k3d cluster create "$CLUSTER" --agents 1 --wait --timeout 240s >/dev/null 2>&1 || {
  echo "error: could not create the k3d cluster." >&2
  exit 1
}

KUBECONFIG="$(k3d kubeconfig write "$CLUSTER")"
export KUBECONFIG

# k3s ships metrics-server, and an HPA with no metrics source reports
# <unknown>/70% forever rather than failing, so wait for it explicitly.
echo "  waiting for metrics-server…"
for _ in $(seq 1 40); do
  kubectl top nodes >/dev/null 2>&1 && break
  sleep 5
done
kubectl top nodes >/dev/null 2>&1 || {
  echo "error: the metrics API never came up; an HPA cannot read CPU without it." >&2
  exit 1
}

# The same realm the cluster runs, rendered to JSON the way KeycloakTestcontainer
# does. A hand-written local realm would drift from the deployed one, and the
# gateway would be starting against something nobody runs.
echo "  rendering the deployed realm…"
python - > "${ROOT}/.hpa-realm.json" <<'PY'
import yaml, json
doc = yaml.safe_load(open('platform/envs/dev/keycloak/realm-import.yaml', encoding='utf-8'))
realm = doc['spec']['realm']
print(json.dumps(realm).replace('${GATEWAY_CLIENT_SECRET}', 'local-hpa-test-secret'))
PY

kubectl create namespace apps >/dev/null 2>&1
kubectl -n apps create configmap keycloak-realm --from-file=realm.json="${ROOT}/.hpa-realm.json" >/dev/null
rm -f "${ROOT}/.hpa-realm.json"

echo "  applying gateway, Valkey, Keycloak and the HPA…"
sed "s|GATEWAY_IMAGE_PLACEHOLDER|${IMAGE}|" infra/load/hpa-local/manifests.yaml | kubectl apply -f - >/dev/null

echo "  waiting for the gateway to be ready (JVM start plus OIDC discovery)…"
kubectl -n apps rollout status deploy/keycloak --timeout=300s >/dev/null 2>&1
if ! kubectl -n apps rollout status deploy/gateway --timeout=420s; then
  echo ""
  echo "error: the gateway never became ready." >&2
  echo "" >&2
  # A crash-looping pod's CURRENT container has no logs -- the useful output is
  # in the previous one. Printing only the current container is how the first
  # version of this reported a blank failure.
  echo "  pods:" >&2
  kubectl -n apps get pods -l app.kubernetes.io/name=gateway -o wide 2>&1 | sed 's/^/    /' >&2
  echo "" >&2
  echo "  waiting/terminated reasons:" >&2
  kubectl -n apps get pods -l app.kubernetes.io/name=gateway     -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[0].state}{"
"}{end}' 2>&1 | sed 's/^/    /' >&2
  echo "" >&2
  for pod in $(kubectl -n apps get pods -l app.kubernetes.io/name=gateway -o name 2>/dev/null); do
    echo "  --- ${pod} (previous container) ---" >&2
    kubectl -n apps logs "$pod" --previous --tail=40 2>/dev/null | sed 's/^/    /' >&2
    echo "  --- ${pod} (current container) ---" >&2
    kubectl -n apps logs "$pod" --tail=40 2>/dev/null | sed 's/^/    /' >&2
  done
  exit 1
fi

hpa_line() {
  kubectl -n apps get hpa gateway --no-headers 2>/dev/null | awk '{printf "targets=%-12s replicas=%s\n", $4, $7}'
}

echo ""
echo "  baseline, before load:"
echo "    $(hpa_line)"

# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Scale UP — load on"
echo "=================================================================="
kubectl -n apps delete job hpa-load --ignore-not-found >/dev/null 2>&1

# 40 VUs against the one endpoint that needs nothing downstream, so the CPU the
# HPA reacts to is the gateway's own rather than Keycloak's or Valkey's.
kubectl -n apps create job hpa-load --image=grafana/k6:0.55.0 -- \
  sh -c 'echo "import http from \"k6/http\"; export const options={vus:40,duration:\"5m\"}; export default function(){ http.get(\"http://gateway.apps.svc.cluster.local:8080/api/auth-info\"); }" > /tmp/s.js && k6 run /tmp/s.js' >/dev/null

MAX_REPLICAS=2
for i in $(seq 1 24); do
  sleep 15
  line="$(hpa_line)"
  reps="$(echo "$line" | sed -n 's/.*replicas=\([0-9]*\).*/\1/p')"
  [ -n "$reps" ] && [ "$reps" -gt "$MAX_REPLICAS" ] && MAX_REPLICAS="$reps"
  printf "    %3ds  %s\n" "$((i * 15))" "$line"
done

echo ""
echo "  peak replicas under load: ${MAX_REPLICAS}"

# ---------------------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Scale DOWN — load off"
echo "=================================================================="
kubectl -n apps delete job hpa-load --ignore-not-found >/dev/null 2>&1
echo "  stabilizationWindowSeconds is 300, so nothing should move for ~5 minutes."

FINAL=0
for i in $(seq 1 32); do
  sleep 15
  line="$(hpa_line)"
  reps="$(echo "$line" | sed -n 's/.*replicas=\([0-9]*\).*/\1/p')"
  printf "    %3ds  %s\n" "$((i * 15))" "$line"
  if [ "${reps:-9}" -le 2 ]; then
    FINAL="$i"
    break
  fi
done

echo ""
echo "=================================================================="
echo " Result"
echo "=================================================================="
printf "  %-34s %s\n" "replicas before load" "2"
printf "  %-34s %s\n" "peak replicas under load" "${MAX_REPLICAS}"
if [ "$FINAL" != "0" ]; then
  printf "  %-34s %ss after load stopped\n" "scaled back to 2" "$((FINAL * 15))"
else
  printf "  %-34s %s\n" "scaled back to 2" "NOT within 8 minutes"
fi
echo ""
if [ "$MAX_REPLICAS" -gt 2 ] && [ "$FINAL" != "0" ]; then
  echo "HPA REHEARSAL PASSED — it scaled up under load and gave the replicas back."
  RESULT=0
else
  echo "HPA REHEARSAL FAILED — see above."
  [ "$MAX_REPLICAS" -le 2 ] && echo "  It never scaled up. Check the HPA targets column for <unknown>."
  [ "$FINAL" = "0" ] && echo "  It never scaled back down, which costs money on a real cluster."
  RESULT=1
fi
echo ""
echo "  Not covered here: cluster-autoscaler. It provisions real Hetzner"
echo "  servers and has no local equivalent — that half needs the real cluster."
echo "=================================================================="

exit "$RESULT"
