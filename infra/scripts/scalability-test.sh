#!/usr/bin/env bash
#
# Runs the scalability step-ramp inside the cluster and records what the cluster
# did while it ran (T-5.10).
#
# WHY THIS IS NOT JUST `load-test.sh` WITH A BIGGER NUMBER
#
# load-test.sh (T-5.6) submits a k6 Job, streams its log, and reads the Job's
# exit code. That is everything a latency gate needs and none of what a
# scalability test needs, because the interesting output of a scalability test
# is not in k6's log at all:
#
#   k6 knows            offered rate, achieved rate, latency, drops
#   only the cluster knows   replica counts, HPA utilisation and decisions,
#                            node count, which pod was on which node, whether
#                            anything went Pending
#
# A run that shows latency climbing at 1200 req/s means one thing if the HPA had
# already scaled to 4 replicas and something completely different if it never
# scaled at all. So this script samples the second list on a timer for the whole
# duration of the run, and the report joins the two timelines. Neither half is
# worth much alone.
#
# THE SAMPLER RUNS OUTSIDE THE CLUSTER, ON PURPOSE
#
# It is the only observer that survives the thing being observed. A sampler
# deployed as a pod competes for the CPU under test, and would be evicted or
# starved exactly when the data gets interesting.
#
# Usage:
#   ./scalability-test.sh [env]
#
# Environment:
#   CORE_STEPS, GW_STEPS, STEP_SEC, GW_STEP_SEC, GAP_SEC   passed to k6
#   NO_CONN_REUSE=true  disable HTTP keep-alive (T-5.14 diagnostic, not a default)
#   TOKEN_REFRESH_SEC   per-VU token refresh, default 120 (realm lifespan is 300)
#   SAMPLE_SEC      sampler interval, default 10
#   K6_IMAGE        default grafana/k6:0.55.0
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
NAMESPACE="${LOAD_NAMESPACE:-apps}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.55.0}"
SAMPLE_SEC="${SAMPLE_SEC:-10}"
STAMP="$(date -u +%Y%m%d%H%M%S)"
JOB="k6-scale-${STAMP}"
OUTDIR="${OUTDIR:-$ROOT/.scale-runs/${STAMP}}"

# This project's kubeconfig, unconditionally. An inherited KUBECONFIG points at
# whatever cluster the operator last used, and this one generates load.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

[ -f "$KUBECONFIG" ] || {
  echo "error: no kubeconfig at $KUBECONFIG - run: make up ENV=${ENVIRONMENT}" >&2
  exit 1
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "error: no ${NAMESPACE} namespace - is the cluster up?" >&2
  exit 1
}

# A scalability test whose HPA is missing measures a fixed replica count and
# reports it as a scaling result. Fail loudly instead.
hpa_count="$(kubectl -n "$NAMESPACE" get hpa --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${hpa_count:-0}" -ge 1 ] || {
  echo "error: no HorizontalPodAutoscaler in ${NAMESPACE}." >&2
  echo "       Without it this measures a fixed replica count. Is Argo synced?" >&2
  exit 1
}

# The HPA reads metrics-server. If it cannot, every HPA reports <unknown> and
# never scales -- which would look identical to "the load was not enough".
kubectl top pods -n "$NAMESPACE" >/dev/null 2>&1 || {
  echo "error: kubectl top does not work - metrics-server is not serving." >&2
  echo "       The HPA cannot scale without it, so this run would prove nothing." >&2
  exit 1
}

mkdir -p "$OUTDIR"
TIMELINE="$OUTDIR/timeline.tsv"
K6LOG="$OUTDIR/k6.log"

echo "=================================================================="
echo " Scalability test: ${ENVIRONMENT}"
echo " k6 ${K6_IMAGE}, in-cluster, open model (ramping-arrival-rate)"
echo " output: ${OUTDIR}"
echo "=================================================================="
echo ""

# ---------------------------------------------------------------------------
# EVERY RUN STARTS FROM THE SAME CLUSTER, OR THE NUMBERS ARE NOT COMPARABLE
# (T-5.15)
# ---------------------------------------------------------------------------
#
# This was learned the expensive way. Six runs were compared against each other
# and against a "baseline" as though they measured the same system:
#
#   fixed / bulkhead / bulkhead16   started at 3 nodes
#   t512                            started at 4
#   t513                            started at 4, peaked at 5
#
# A node is 3700m of schedulable CPU on this cluster, so t512 opened with 50%
# more hardware than the baseline it was reported against and t513 with more
# again. Part of every improvement in those tables is a server, not a change,
# and nothing in the output said so.
#
# It happens silently because the cluster-autoscaler's scale-down chain is long:
# the HPA's own stabilisation window (300s gateway, 600s core) has to expire
# before a node drops under the autoscaler's 50%-of-REQUESTS threshold, and only
# then does its 10-minute scale-down-unneeded-time start. A run launched twenty
# minutes after the previous one begins on the previous one's hardware.
#
# So: refuse to start above the floor rather than warn about it. A warning in a
# 900-line log is a warning nobody reads, and the cost of being wrong here is an
# entire run plus every conclusion drawn from it.
BASELINE_NODES="${BASELINE_NODES:-3}"

echo "--- state before ---"
kubectl -n "$NAMESPACE" get hpa
kubectl -n "$NAMESPACE" get deploy -o wide 2>/dev/null | head -5
kubectl get nodes --no-headers | awk '{print "  node " $1 " " $2}'
echo ""

NODES_AT_START="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NODES_AT_START" -gt "$BASELINE_NODES" ]; then
  cat >&2 <<EOM
==================================================================
 REFUSING TO START: the cluster has not returned to its floor.

   nodes now       ${NODES_AT_START}
   baseline        ${BASELINE_NODES}

 ${NODES_AT_START} nodes is more hardware than the runs this one will be compared
 against, and the extra capacity would be read as an improvement. The
 autoscaled nodes from a previous run have not been reclaimed yet.

 What has to happen first, in order:

   1. the HPAs return to minReplicas   (stabilisation: 300s gateway,
                                        600s core, then 1 pod / 180s)
   2. the emptied nodes fall below the autoscaler's utilisation
      threshold, which is 50% of REQUESTS, not of usage
   3. scale-down-unneeded-time elapses  (10m, and no scale-down at all
                                        within 10m of the last scale-up)

 Typically 20-30 minutes after the last request. To start the clock now:

   kubectl -n ${NAMESPACE} scale deploy/gateway --replicas=2
   kubectl -n ${NAMESPACE} scale deploy/core --replicas=1

 Watch it with:

   kubectl get nodes -w

 If you genuinely mean to measure a larger cluster, say so explicitly and
 the comparison becomes your problem rather than a silent one:

   BASELINE_NODES=${NODES_AT_START} make scale-test ENV=${ENVIRONMENT}
==================================================================
EOM
  exit 1
fi
echo "  starting from ${NODES_AT_START} nodes (baseline ${BASELINE_NODES})"
echo ""

# ---------------------------------------------------------------------------
# THE SAMPLER
# ---------------------------------------------------------------------------
#
# Three kubectl calls per tick, no jq: `-o jsonpath` because jq is not something
# this repository has ever required and a load test is a poor place to start.
START_EPOCH="$(date +%s)"

printf 'elapsed_s\tgw_cur\tgw_desired\tgw_pct\tcore_cur\tcore_desired\tcore_pct\tnodes\tpending\tgw_cpu_m\tcore_cpu_m\tk6_cpu_m\n' > "$TIMELINE"

sample_once() {
  local now elapsed hpa nodes pending tops
  now="$(date +%s)"
  elapsed=$(( now - START_EPOCH ))

  hpa="$(kubectl -n "$NAMESPACE" get hpa -o jsonpath='{range .items[*]}{.metadata.name}|{.status.currentReplicas}|{.status.desiredReplicas}|{.status.currentMetrics[0].resource.current.averageUtilization}{"\n"}{end}' 2>/dev/null)"

  local gw_cur="" gw_des="" gw_pct="" core_cur="" core_des="" core_pct=""
  while IFS='|' read -r name cur des pct; do
    [ -n "$name" ] || continue
    case "$name" in
      gateway) gw_cur="$cur"; gw_des="$des"; gw_pct="$pct" ;;
      core)    core_cur="$cur"; core_des="$des"; core_pct="$pct" ;;
    esac
  done <<< "$hpa"

  nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  # A Pending app pod is the cluster-autoscaler's trigger. Recording it is how
  # the report can tell "the HPA asked for a replica and got one" apart from
  # "the HPA asked and nothing could seat it".
  pending="$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | awk '$3=="Pending"' | wc -l | tr -d ' ')"

  tops="$(kubectl top pods -n "$NAMESPACE" --no-headers 2>/dev/null)"
  local gw_cpu core_cpu k6_cpu
  gw_cpu="$(echo "$tops" | awk '$1 ~ /^gateway-/ {gsub(/m$/,"",$2); s+=$2} END {print s+0}')"
  core_cpu="$(echo "$tops" | awk '$1 ~ /^core-/ {gsub(/m$/,"",$2); s+=$2} END {print s+0}')"
  k6_cpu="$(echo "$tops" | awk '$1 ~ /^k6-scale-/ {gsub(/m$/,"",$2); s+=$2} END {print s+0}')"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$elapsed" "${gw_cur:--}" "${gw_des:--}" "${gw_pct:--}" \
    "${core_cur:--}" "${core_des:--}" "${core_pct:--}" \
    "${nodes:--}" "${pending:-0}" "${gw_cpu:-0}" "${core_cpu:-0}" "${k6_cpu:-0}" \
    >> "$TIMELINE"
}

sampler_loop() {
  while :; do
    sample_once
    sleep "$SAMPLE_SEC"
  done
}

sampler_loop &
SAMPLER_PID=$!

CM="${JOB}-script"
kubectl -n "$NAMESPACE" create configmap "$CM" --from-file=scalability.js=infra/load/scalability.js >/dev/null || {
  kill "$SAMPLER_PID" 2>/dev/null
  echo "error: could not create the script ConfigMap" >&2
  exit 1
}

cleanup() {
  kill "$SAMPLER_PID" 2>/dev/null
  kubectl -n "$NAMESPACE" delete configmap "$CM" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# k6 requests 1000m and carries no CPU limit, matching every other workload here
# (T-2.15). The request is a scheduling floor; the report prints what it actually
# burned, because a generator that saturates before the application does is
# measuring itself and the reader has to be able to see that.
kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  labels: {app.kubernetes.io/name: k6-scale}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: {app.kubernetes.io/name: k6-scale}
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          args: ["run", "/scripts/scalability.js"]
          env:
            - {name: CORE_STEPS,  value: "${CORE_STEPS:-}"}
            - {name: GW_STEPS,    value: "${GW_STEPS:-}"}
            - {name: STEP_SEC,    value: "${STEP_SEC:-}"}
            - {name: GW_STEP_SEC, value: "${GW_STEP_SEC:-}"}
            - {name: GAP_SEC,     value: "${GAP_SEC:-}"}
            # T-5.14. Turns off HTTP keep-alive so the Service balances per
            # request instead of per connection. Diagnostic only -- see the long
            # note in scalability.js.
            - {name: NO_CONN_REUSE, value: "${NO_CONN_REUSE:-}"}
            - {name: TOKEN_REFRESH_SEC, value: "${TOKEN_REFRESH_SEC:-}"}
          resources:
            requests: {cpu: 1000m, memory: 512Mi}
            limits:   {memory: 1Gi}
          volumeMounts:
            - {name: scripts, mountPath: /scripts}
      volumes:
        - name: scripts
          configMap: {name: ${CM}}
EOF

echo "  job ${JOB} submitted; sampling every ${SAMPLE_SEC}s"
echo "  this is a long run by design - the steps are sized to let an HPA react"
echo ""

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "job-name=${JOB}" --timeout=180s >/dev/null 2>&1

kubectl -n "$NAMESPACE" logs -f "job/${JOB}" 2>/dev/null | tee "$K6LOG"

# The exit code of `kubectl logs` says nothing about k6. Read the Job.
succeeded=""; failed=""
for _ in $(seq 1 30); do
  succeeded="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  failed="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  [ -n "$succeeded" ] || [ -n "$failed" ] && break
  sleep 2
done

# One last sample so the timeline covers the end of the run, then stop.
sample_once
kill "$SAMPLER_PID" 2>/dev/null
wait "$SAMPLER_PID" 2>/dev/null

# The HPA's own account of what it decided and why. This is the only place the
# reason string lives, and it is what distinguishes "did not scale because load
# was low" from "wanted to and could not".
kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null \
  | awk 'NR==1 || /HorizontalPodAutoscaler|Scaled|FailedScheduling|TriggeredScaleUp|Evicted|OOMKill/' \
  > "$OUTDIR/events.txt"

echo ""
if [ "${succeeded:-0}" != "1" ]; then
  echo "=================================================================="
  echo "THE RUN DID NOT COMPLETE - k6 exited non-zero or could not start."
  echo "  Most often the token fetch in setup(), which fails the whole run"
  echo "  rather than silently measuring unauthenticated 401s."
  echo "  k6 log:   ${K6LOG}"
  echo "  timeline: ${TIMELINE}"
  echo "=================================================================="
  exit 1
fi

PY_BIN="$(python3 -c '' >/dev/null 2>&1 && echo python3 || echo python)"
"$PY_BIN" "$ROOT/infra/scripts/scalability-report.py" "$K6LOG" "$TIMELINE" "$OUTDIR/events.txt" | tee "$OUTDIR/report.txt"

# The same run as charts. The text report is what a terminal reads; the curve is
# what a person reads, and the knee is a shape rather than a number in a column.
if "$PY_BIN" "$ROOT/infra/scripts/scalability-charts.py" "$K6LOG" "$TIMELINE" "$OUTDIR/report.html" "$OUTDIR/events.txt" >/dev/null 2>&1; then
  echo "  charts:    ${OUTDIR}/report.html"
  # PDF is best-effort: it needs a Chromium on the machine, and a run that
  # produced a report should not report failure because the operator has no
  # browser installed.
  if bash "$ROOT/infra/scripts/html-to-pdf.sh" "$OUTDIR/report.html" "$OUTDIR/report.pdf" >/dev/null 2>&1; then
    echo "  pdf:       ${OUTDIR}/report.pdf"
  else
    echo "  (no PDF: no Chromium found, or it could not render. The HTML is the same content.)"
  fi
else
  echo "  (charts could not be rendered; the text report above is unaffected)"
fi

echo ""
echo "  artifacts: ${OUTDIR}"

# ---------------------------------------------------------------------------
# PUT THE CLUSTER BACK ON ITS FLOOR (T-5.16)
# ---------------------------------------------------------------------------
#
# The preflight above refuses to start above BASELINE_NODES. That check is only
# useful if something actually gets the cluster back down, and left alone it
# takes roughly twenty-five minutes -- long enough that the next run is launched
# on the last one's hardware, which is exactly the mistake the preflight exists
# to prevent.
#
# WHAT IS ACTUALLY BEING WAITED ON, because it is not the autoscaler:
#
#   gateway HPA   300s stabilisation, then 1 pod / 120s   -> 2 replicas at ~420s
#   core HPA      600s stabilisation, then 1 pod / 180s   -> 1 replica  at ~780s
#   autoscaler    node unneeded (< 50% of REQUESTS) for scale-down-unneeded-time
#
# Core's thirteen minutes dominate, and that number is deliberate: hpa.yaml
# explains that scaling core down discards a warm Hibernate cache and JIT
# profile, which T-5.6 measured at 35% worse p95 cold against warm. It is part
# of what the test measures and it is NOT shortened here for convenience.
#
# Scaling the Deployments by hand does not help either, and it is worth writing
# down why: an HPA's scale-down stabilisation takes the MAXIMUM recommendation
# over its window, so for those first 300/600 seconds the HPA's desired count is
# still the scaled-out one and it restores whatever you set. The wait is real.
#
# So this reports rather than hurries. It names which of the three things it is
# still waiting for, so an operator watching the tail of a run knows whether to
# wait or to go and do something else.
RESET_AFTER="${RESET_AFTER:-true}"
RESET_TIMEOUT_SEC="${RESET_TIMEOUT_SEC:-1800}"

if [ "$RESET_AFTER" != "true" ]; then
  echo ""
  echo "  RESET_AFTER=false: leaving the cluster as the run left it."
  echo "  The next run will refuse to start until it is back to ${BASELINE_NODES} nodes."
  exit 0
fi

echo ""
echo "--- returning to the floor ---"
echo "  waiting for ${BASELINE_NODES} nodes; the binding constraint is core's HPA (~13 min)"

reset_deadline=$(( $(date +%s) + RESET_TIMEOUT_SEC ))
while :; do
  now_nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  now_gw="$(kubectl -n "$NAMESPACE" get deploy gateway -o jsonpath='{.status.replicas}' 2>/dev/null)"
  now_core="$(kubectl -n "$NAMESPACE" get deploy core -o jsonpath='{.status.replicas}' 2>/dev/null)"

  if [ "${now_nodes:-0}" -le "$BASELINE_NODES" ]; then
    echo "  at the floor: ${now_nodes} nodes, gateway ${now_gw}, core ${now_core}"
    break
  fi

  if [ "$(date +%s)" -ge "$reset_deadline" ]; then
    echo "  TIMED OUT after ${RESET_TIMEOUT_SEC}s at ${now_nodes} nodes (gateway ${now_gw}, core ${now_core})." >&2
    echo "  Something is holding a node that the autoscaler cannot drain -- check:" >&2
    echo "    kubectl -n kube-system logs deploy/cluster-autoscaler --tail=50 | grep -i unremovable" >&2
    echo "  The next run will refuse to start until this is resolved." >&2
    exit 1
  fi

  # Which of the three is it? Saying "waiting" without saying what for is how an
  # operator ends up staring at a terminal for thirteen minutes.
  if [ "${now_gw:-0}" -gt 2 ] || [ "${now_core:-0}" -gt 1 ]; then
    waiting_on="HPAs (gateway ${now_gw}/2, core ${now_core}/1)"
  else
    waiting_on="autoscaler's scale-down timer; pods are already at minimum"
  fi
  echo "  ${now_nodes} nodes, waiting on ${waiting_on}"
  sleep 30
done
