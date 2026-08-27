#!/usr/bin/env bash
#
# Runs the k6 write and mixed read/write load inside the cluster (T-5.15).
#
# WHY THIS IS NOT load-test.sh WITH A DIFFERENT FILENAME
#
# load-test.sh runs a read benchmark, which leaves nothing behind. This one
# writes rows, and a load test that leaves state in the database is a load test
# whose second run measures the first one. Everything below that is not in
# load-test.sh exists for that reason:
#
#   - it counts the rows before and after, so the run reports what it actually
#     committed rather than what the gateway said it committed;
#   - it deletes them afterwards, by SQL rather than through the API.
#
# WHY CLEANUP IS SQL AND NOT DELETE /api/documents/{id}
#
# DocumentService.delete() removes the row and then calls storage.delete() on
# the object key -- one network round trip to Hetzner per row, for objects that
# were never uploaded and do not exist. Tens of thousands of those to clean up
# after a test that deliberately excluded object storage is absurd, and slower
# than the test itself. The rows this writes have no objects, so nothing needs
# collecting; a DELETE on the table is the complete cleanup.
#
# The predicate is narrow on purpose: status = 'PENDING' AND filename LIKE
# 'k6-write-%'. A human's genuinely abandoned upload does not match it.
#
# Usage:
#   ./write-load-test.sh [env]
#
#   KEEP_ROWS=true ./write-load-test.sh dev   # leave the rows for inspection
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
NAMESPACE="${LOAD_NAMESPACE:-apps}"
DB_NAMESPACE="${DB_NAMESPACE:-database}"
DB_NAME="${DB_NAME:-core}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.55.0}"
KEEP_ROWS="${KEEP_ROWS:-false}"
JOB="k6-write-$(date -u +%Y%m%d%H%M%S)"

# This project's kubeconfig, unconditionally. An inherited KUBECONFIG points at
# whatever cluster the operator last used, and this one generates load AND
# deletes rows.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

[ -f "$KUBECONFIG" ] || {
  echo "error: no kubeconfig at $KUBECONFIG — run: make up ENV=${ENVIRONMENT}" >&2
  exit 1
}

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "error: no ${NAMESPACE} namespace — is the cluster up?" >&2
  exit 1
}

# The CNPG primary. Resolved once and reused: asking again after the run could
# land on a different pod if a failover happened mid-test, and then the two row
# counts would be from two instances.
PRIMARY="$(kubectl -n "$DB_NAMESPACE" get pods -l 'cnpg.io/instanceRole=primary' -o name 2>/dev/null | head -1)"
PRIMARY="${PRIMARY##*/}"

[ -n "$PRIMARY" ] || {
  echo "error: no Postgres primary in the ${DB_NAMESPACE} namespace" >&2
  echo "  this test needs one to count and to clean up the rows it writes." >&2
  exit 1
}

# The rows this test writes and the rows it must not touch, in one predicate
# used by every statement below. Defined once so the count and the delete can
# never drift apart -- a cleanup that deletes more than it counted is the
# failure mode worth designing out.
ROWS="status = 'PENDING' AND filename LIKE 'k6-write-%'"

psql_count() {
  kubectl -n "$DB_NAMESPACE" exec "$PRIMARY" -c postgres -- \
    psql -U postgres -d "$DB_NAME" -tAc "select count(*) from document where ${ROWS};" 2>/dev/null | tr -d '[:space:]'
}

# Total pages across the document table's indexes.
#
# WHY THIS IS MEASURED AT ALL. See the REINDEX below: deleting the rows
# returns the heap but not the indexes, and an index left bloated by one run
# is scanned by the next one. Printing the number is what makes that visible
# rather than something the reader has to already suspect.
index_pages() {
  kubectl -n "$DB_NAMESPACE" exec "$PRIMARY" -c postgres -- \
    psql -U postgres -d "$DB_NAME" -tAc "select coalesce(sum(pg_relation_size(indexrelid))/8192, 0) from pg_index where indrelid = 'document'::regclass;" 2>/dev/null | tr -d '[:space:]' 
}

echo "=================================================================="
echo " Write + mixed load: ${ENVIRONMENT}"
echo " k6 ${K6_IMAGE}, in-cluster, against the gateway Service"
echo "=================================================================="

BEFORE="$(psql_count)"
IDX_BEFORE="$(index_pages)"
[ -n "$BEFORE" ] || {
  echo "error: could not read the document table on ${PRIMARY}" >&2
  echo "  refusing to run: without a starting count the cleanup cannot be verified." >&2
  exit 1
}

if [ "$BEFORE" != "0" ]; then
  echo ""
  echo "  note: ${BEFORE} k6-write rows are ALREADY in the table. A previous run"
  echo "        left them, or KEEP_ROWS was set. They are counted out below, but"
  echo "        the table they grew is still under this run's numbers."
fi
echo ""

# The script goes in as a ConfigMap rather than baked into an image, so changing
# a scenario is a commit rather than a build.
CM="${JOB}-script"
kubectl -n "$NAMESPACE" create configmap "$CM" --from-file=write.js=infra/load/write.js >/dev/null || {
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
  labels: {app.kubernetes.io/name: k6-write}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels: {app.kubernetes.io/name: k6-write}
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          args: ["run", "/scripts/write.js"]
          resources:
            requests: {cpu: 200m, memory: 256Mi}
            limits:   {memory: 512Mi}
          volumeMounts:
            - {name: scripts, mountPath: /scripts}
      volumes:
        - name: scripts
          configMap: {name: ${CM}}
EOF

echo "  job ${JOB} submitted; 90s warm-up then four scenarios, about 8m55s total; streaming…"
echo ""

kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "job-name=${JOB}" --timeout=180s >/dev/null 2>&1

kubectl -n "$NAMESPACE" logs -f "job/${JOB}" 2>/dev/null | tee "${JOB}.log"

# The exit code of `kubectl logs` says nothing about k6. Read the Job.
for _ in $(seq 1 30); do
  succeeded="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  failed="$(kubectl -n "$NAMESPACE" get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  [ -n "$succeeded" ] || [ -n "$failed" ] && break
  sleep 2
done

# ---------------------------------------------------------------------------
# DID THE WRITES ACTUALLY LAND
# ---------------------------------------------------------------------------
#
# k6 counts 201s. Postgres counts rows. This project's recurring defect is a
# component reporting success while doing nothing (docs/testing.md), so the two
# are compared rather than one being trusted. They should match exactly: the
# route retries GET only, so no write is replayed, and nothing else writes rows
# with this filename prefix.
AFTER="$(psql_count)"
CLAIMED="$(grep -Eo 'rows_written[^0-9]+[0-9]+' "${JOB}.log" 2>/dev/null | grep -Eo '[0-9]+$' | tail -1)"
COMMITTED=$(( ${AFTER:-0} - BEFORE ))

echo ""
echo "=================================================================="
echo " ROWS"
echo "   k6 counted 201 responses:      ${CLAIMED:-unknown}"
echo "   Postgres gained PENDING rows:  ${COMMITTED}"
if [ -n "${CLAIMED:-}" ] && [ "${CLAIMED}" != "${COMMITTED}" ]; then
  echo ""
  echo "   THESE DISAGREE. A 201 without a row means the response was not what"
  echo "   it claimed; a row without a 201 means a commit whose response was"
  echo "   lost. Either is a finding about the application, not about the test."
fi

if [ "$KEEP_ROWS" = "true" ]; then
  echo ""
  echo "   KEEP_ROWS=true — ${AFTER} rows left in place. Remove them with:"
  echo "     kubectl -n ${DB_NAMESPACE} exec ${PRIMARY} -c postgres -- \\"
  echo "       psql -U postgres -d ${DB_NAME} -c \"delete from document where ${ROWS};\""
else
  deleted="$(kubectl -n "$DB_NAMESPACE" exec "$PRIMARY" -c postgres -- \
    psql -U postgres -d "$DB_NAME" -tAc "with d as (delete from document where ${ROWS} returning 1) select count(*) from d;" 2>/dev/null | tr -d '[:space:]')"
  echo "   cleaned up:                    ${deleted:-0} rows deleted"

  # DELETING THE ROWS IS NOT ENOUGH, AND THE 2026-08-27 RUNS ARE WHY.
  #
  # VACUUM returns the heap -- after the first run it was back to a single
  # page -- but a B-tree does not shrink. Its entries are removed and its
  # pages marked reusable; the page COUNT stays where the peak left it. After
  # one run of this test, ix_document_owner_created_at held 806 pages (6.4 MB)
  # for 18 live rows, and uk_document_object_key another 575.
  #
  # The next run's read_control then scans that. Same query, same 18 rows, and
  # it came out 34% slower on the second run than the first -- the control
  # drifting monotonically because of what the previous run left behind. A load
  # test whose own baseline degrades every time it runs cannot answer anything,
  # and the drift would eventually be read as a regression in the application.
  #
  # CONCURRENTLY so this never takes an ACCESS EXCLUSIVE lock on a table some
  # other environment might be serving from. It is slower, and nothing is
  # waiting on this script.
  reindexed="$(kubectl -n "$DB_NAMESPACE" exec "$PRIMARY" -c postgres -- psql -U postgres -d "$DB_NAME" -tAc "reindex table concurrently document;" 2>&1 | tr -d '[:space:]')"
  IDX_AFTER="$(index_pages)"
  echo "   index pages:                   ${IDX_BEFORE:-?} at start, ${IDX_AFTER:-?} after REINDEX"
  if [ -n "${IDX_AFTER:-}" ] && [ "${IDX_AFTER:-0}" -gt 100 ]; then
    echo ""
    echo "   The indexes did not shrink. REINDEX said: ${reindexed}"
    echo "   The next run's read_control will be measured against this."
  fi
  if [ -z "${deleted:-}" ]; then
    echo ""
    echo "   CLEANUP FAILED. The rows are still there and the next run's numbers"
    echo "   will include them. Delete them by hand:"
    echo "     kubectl -n ${DB_NAMESPACE} exec ${PRIMARY} -c postgres -- \\"
    echo "       psql -U postgres -d ${DB_NAME} -c \"delete from document where ${ROWS};\""
  fi
fi

echo "=================================================================="
if [ "${succeeded:-0}" = "1" ]; then
  echo "WRITE LOAD PASSED — no failures, no circuit-breaker fallbacks."
  echo ""
  echo "  The five trends, and what each is for:"
  echo ""
  echo "    latency_read_control    the read, small table, no writes — the floor"
  echo "    latency_write_only      the write, alone"
  echo "    latency_mixed_read      the read, grown table, writes in flight"
  echo "    latency_mixed_write     the write, with reads in flight"
  echo "    latency_read_after      the read, grown table, NO writes in flight"
  echo ""
  echo "  THE TWO SUBTRACTIONS THAT CARRY THE RESULT:"
  echo ""
  echo "    read_after - read_control   the cost of ROW COUNT. Should be near"
  echo "                                zero: V6 indexes (owner, status,"
  echo "                                created_at DESC), so a listing no longer"
  echo "                                walks past the PENDING rows. If this"
  echo "                                separates again, the index was dropped or"
  echo "                                the query stopped matching it."
  echo "    mixed_read - read_after     the cost of CONCURRENT WRITES to a"
  echo "                                reader. Measured at 1.5ms (~4%) at 36"
  echo "                                writes/s on 2026-08-27."
  echo ""
  echo "  The first 90s are warm-up and are not in any of these numbers."
  echo "  full output: ${JOB}.log"
  echo "=================================================================="
  exit 0
fi

echo "WRITE LOAD FAILED — a threshold was breached, or k6 could not run."
echo ""
echo "  The thresholds here are correctness, not speed:"
echo "    http_req_failed   a request errored"
echo "    checks            a read was not 200, or a write was not 201"
echo "    fallback_503      the circuit breaker OPENED"
echo ""
echo "  fallback_503 is the one to read first. An open breaker answers in about"
echo "  a millisecond, so latency IMPROVES while nothing is being served — every"
echo "  trend after that point describes the fallback, not the database."
echo ""
echo "  If every threshold passed and this still failed, k6 did not start —"
echo "  usually the token fetch in setup(), which fails the whole run rather"
echo "  than silently measuring unauthenticated 401s."
echo "  full output: ${JOB}.log"
echo "=================================================================="
exit 1
