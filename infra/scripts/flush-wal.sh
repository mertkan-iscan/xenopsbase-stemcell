#!/usr/bin/env bash
#
# Force every committed transaction into the WAL archive before the cluster is
# destroyed (T-7.2).
#
# THE DATA LOSS THIS EXISTS TO STOP
#
# WAL reaches the archive when a segment fills, or when `archive_timeout`
# expires -- 300 seconds here. A transaction committed inside that window is
# durable in Postgres and absent from the archive. Destroy the cluster and it
# is gone.
#
# Measured on the first cold-rebuild drill, 2026-08-23. Segments archived
# exactly on the timer:
#
#   ...92  14:46:19
#   ...93  14:51:18
#   ...94  14:56:18
#   ...95  15:01:19   <- last one
#
# A document was created at 15:01:38, nineteen seconds after that. The destroy
# began at ~15:03. Segment ...96 was due at ~15:06 and never happened. The
# document was uploaded successfully, the API returned 200, the row committed,
# and it did not survive the rebuild.
#
# WHY THE RPO NUMBER DID NOT COVER THIS
#
# docs/runbooks/disaster-recovery.md records a worst-case RPO of 301s and that
# number is correct -- for a DISASTER. It is what you lose when the cluster
# disappears without warning.
#
# `make down` is not a disaster. It is a planned, everyday operation, and
# losing five minutes of committed data to one is a choice nobody made. The
# distinction was never drawn, so the disaster number quietly became the
# everyday one.
#
# WHAT IT DOES
#
# pg_switch_wal() on the primary, then waits for the archiver to report the
# segment shipped. Cheap, and it makes a planned teardown lossless.
#
# Usage:
#   ./flush-wal.sh [env]
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

ENVIRONMENT="${1:-dev}"
NAMESPACE="${DB_NAMESPACE:-database}"
# LONGER THAN THE ARCHIVER'S OWN CADENCE (T-7.13, #295).
#
# This was 120s against an `archive_timeout` of 300s -- a window shorter than
# the thing it waits on. pg_switch_wal() closes the segment and the archiver
# normally ships it in seconds, so the short window usually worked; but an
# archiver that has just failed backs off, and then 120s cannot succeed on
# timing alone. `make down` refused to proceed while archiving was demonstrably
# healthy, with base backups 20 minutes old and WAL 4 minutes old in the same
# run.
#
# 420s is one full archive_timeout period (300s) plus the 120s this originally
# allowed, so a segment that has to wait out a complete cycle plus a retry still
# fits. It is a ceiling, not a delay: the wait exits as soon as the segment
# lands, which is usually within seconds.
TIMEOUT="${FLUSH_TIMEOUT:-420}"

# THE BUCKET IS THE FACT (T-7.13, #295).
#
# This used to watch `archived_count` increase, which is the archiver's claim
# about its own work rather than the thing being asked. verify-backup.sh gets
# this right one script over and says why: "The bucket is the fact; the
# Cluster's green condition is a claim about it." The question here is whether
# the switched segment reached object storage, and that is directly checkable.
#
# barman-cloud lays WAL out as <server>/wals/<first 16 chars>/<segment>.gz --
# verified against the live bucket rather than assumed.
BUCKET="xenopsbase-${ENVIRONMENT}-pg-backups"
ENDPOINT="${HETZNER_S3_ENDPOINT:-https://fsn1.your-objectstorage.com}"
CLUSTER_YAML="$ROOT/platform/envs/${ENVIRONMENT}/database/cluster.yaml"
SERVER_NAME="$(sed -n 's/^[[:space:]]*serverName:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$CLUSTER_YAML" 2>/dev/null | head -1)"

# Credentials are NOT required. flush-wal runs even under SKIP_BACKUP_CHECK=1 --
# which is exactly the half-destroyed recovery path T-7.10 (#291) recommends --
# so refusing to run without them would block the one command that unsticks a
# failed drill. When they are absent the counter check is used instead, and the
# output says which check actually ran rather than implying the stronger one.
CAN_READ_BUCKET=0
if [ -n "${TF_VAR_hetzner_s3_access_key:-}" ] && [ -n "${TF_VAR_hetzner_s3_secret_key:-}" ] && [ -n "$SERVER_NAME" ]; then
  export AWS_ACCESS_KEY_ID="$TF_VAR_hetzner_s3_access_key"
  export AWS_SECRET_ACCESS_KEY="$TF_VAR_hetzner_s3_secret_key"
  CAN_READ_BUCKET=1
fi

# Is this exact segment in object storage?
segment_archived() {
  aws --endpoint-url "$ENDPOINT" s3api head-object     --bucket "$BUCKET"     --key "${SERVER_NAME}/wals/${1:0:16}/${1}.gz" >/dev/null 2>&1
}

# This project's kubeconfig, unconditionally -- an inherited KUBECONFIG points
# at whatever cluster the developer last used, and this one issues a write.
export KUBECONFIG="$ROOT/infra/terraform/cluster/kubeconfig"

echo "  flushing WAL so nothing committed is lost to the destroy…"

if [ ! -f "$KUBECONFIG" ]; then
  echo "    no kubeconfig — cluster already gone, nothing to flush."
  exit 0
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "    no ${NAMESPACE} namespace — nothing to flush."
  exit 0
fi

# The PRIMARY. Writing to a replica fails, and pg_switch_wal() on the wrong
# instance would report success having archived nothing.
PRIMARY="$(kubectl -n "$NAMESPACE" get pods -l 'cnpg.io/instanceRole=primary' -o name 2>/dev/null | head -1)"
if [ -z "$PRIMARY" ]; then
  echo "    no primary found — the database is already down. Anything committed"
  echo "    in the last ${TIMEOUT}s may not have reached the archive." >&2
  exit 0
fi

before="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
  psql -U postgres -tAc "select archived_count from pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]')"

segment="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
  psql -U postgres -tAc "select pg_walfile_name(pg_switch_wal());" 2>/dev/null | tr -d '[:space:]')"

if [ -z "$segment" ]; then
  echo "    could not switch WAL — continuing, but the last few minutes of writes" >&2
  echo "    may not be in the archive." >&2
  exit 0
fi

echo "    switched at segment ${segment}"

# Waiting matters. pg_switch_wal() closes the segment; the archiver ships it
# afterwards, and destroying between the two loses exactly what this was meant
# to save.
deadline=$(( $(date +%s) + TIMEOUT ))
waited=0

while :; do
  if [ "$CAN_READ_BUCKET" = "1" ]; then
    # The question, asked directly.
    if segment_archived "$segment"; then
      echo "    ${segment}.gz is in ${BUCKET} (${waited}s) — nothing committed is at risk"
      exit 0
    fi
  else
    after="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
      psql -U postgres -tAc "select archived_count from pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$after" ] && [ -n "$before" ] && [ "$after" -gt "$before" ]; then
      echo "    archiver count rose ${before} -> ${after} (${waited}s)"
      echo "    NOTE: this is the archiver's claim, not the bucket. No object-storage"
      echo "    credentials in the environment, so the segment itself was not checked."
      echo "    source ~/.xenopsbase.env to get the stronger check."
      exit 0
    fi
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "    ${segment} did not reach the archive within ${TIMEOUT}s." >&2

    # ONLY A FAILURE THAT IS ACTUALLY CURRENT (T-7.13, #295).
    #
    # last_failed_wal is sticky in pg_stat_archiver: it keeps naming the last
    # segment that ever failed, long after it succeeded. This reported
    # `00000018.history` as the problem while that same file sat archived in
    # the bucket -- pointing the operator at a red herring while telling them
    # they were about to lose data. Comparing the two timestamps is the whole
    # fix: a failure older than the last success is history, not news.
    failed="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
      psql -U postgres -tAc "select case when last_failed_time > last_archived_time then last_failed_wal else '' end from pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$failed" ]; then
      echo "    the archiver is currently failing, most recently on: ${failed}" >&2
    else
      echo "    the archiver reports no failure more recent than its last success," >&2
      echo "    so this looks like a slow ship rather than a broken archive." >&2
    fi

    echo "    Destroying now would lose everything committed since the last" >&2
    echo "    successful archive. Check: make backup-status ENV=${ENVIRONMENT}" >&2
    exit 1
  fi

  sleep 3
  waited=$(( waited + 3 ))
done
