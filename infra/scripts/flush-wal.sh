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
TIMEOUT="${FLUSH_TIMEOUT:-120}"

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
while :; do
  after="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
    psql -U postgres -tAc "select archived_count from pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]')"
  failed="$(kubectl -n "$NAMESPACE" exec "${PRIMARY##*/}" -c postgres -- \
    psql -U postgres -tAc "select last_failed_wal from pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]')"

  if [ -n "$after" ] && [ -n "$before" ] && [ "$after" -gt "$before" ]; then
    echo "    archived (count ${before} -> ${after})"
    exit 0
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "    WAL did not archive within ${TIMEOUT}s." >&2
    [ -n "$failed" ] && echo "    last failed segment: ${failed}" >&2
    echo "    Destroying now would lose everything committed since the last" >&2
    echo "    successful archive. Check: make backup-status ENV=${ENVIRONMENT}" >&2
    exit 1
  fi

  sleep 3
done
