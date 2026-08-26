#!/usr/bin/env bash
#
# Answers "is this database actually recoverable right now" from the bucket,
# which is the only place that knows.
#
# WHY THIS EXISTS
#
# The Cluster resource cannot answer it. Under the barman-cloud PLUGIN backup
# method -- the one this project uses (ADR-0007) -- CloudNativePG never
# populates the fields an operator would read:
#
#   status.lastSuccessfulBackup       absent from the resource entirely
#   status.firstRecoverabilityPoint   absent
#   status.pluginStatus               capabilities and version only
#
# and the matching collector metrics are pinned at zero:
#
#   cnpg_collector_last_available_backup_timestamp   0
#   cnpg_collector_first_recoverability_point        0
#   cnpg_collector_last_failed_backup_timestamp      0
#
# Those fields belong to the deprecated in-tree barmanObjectStore path. The
# condition that IS maintained, LastBackupSucceeded, is derived from Backup
# resources and says nothing about age -- it reads True whether the last backup
# was an hour ago or never happened at all (#145).
#
# So the documented pre-destroy check -- "is the data recoverable" -- had no
# trustworthy source. This is that source. It reads objects, not claims.
#
# Read-only. Every call below is a list.
#
# Usage:
#   ./verify-backup.sh <env> [max_base_age_seconds] [max_wal_age_seconds]
#
set -uo pipefail

ENVIRONMENT="${1:-dev}"
# 30 hours. ScheduledBackup runs daily at 03:00, so anything beyond this means a
# run was missed or failed. Matches PostgresNoRecentBaseBackup.
MAX_BASE_AGE="${2:-108000}"
# 15 minutes: three archive_timeout periods (300s), so a single slow ship does
# not trip it but a stalled archiver does.
MAX_WAL_AGE="${3:-900}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_YAML="$ROOT/platform/envs/$ENVIRONMENT/database/cluster.yaml"
BUCKET="xenopsbase-$ENVIRONMENT-pg-backups"
ENDPOINT="${HETZNER_S3_ENDPOINT:-https://fsn1.your-objectstorage.com}"

fail=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
  fail=1
}

: "${TF_VAR_hetzner_s3_access_key:?TF_VAR_hetzner_s3_access_key is not set — run: source ~/.xenopsbase.env}"
: "${TF_VAR_hetzner_s3_secret_key:?TF_VAR_hetzner_s3_secret_key is not set}"
export AWS_ACCESS_KEY_ID="$TF_VAR_hetzner_s3_access_key"
export AWS_SECRET_ACCESS_KEY="$TF_VAR_hetzner_s3_secret_key"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-fsn1}"

# The lineage name lives in the manifest rather than here, so this cannot drift
# from what the cluster actually archives into. A wrong serverName would report
# an empty archive and read exactly like a total backup failure.
SERVER_NAME="$(sed -n 's/^[[:space:]]*serverName:[[:space:]]*\([A-Za-z0-9_-]*\).*/\1/p' "$CLUSTER_YAML" 2>/dev/null | head -1)"
if [ -z "$SERVER_NAME" ]; then
  echo "error: could not read serverName from $CLUSTER_YAML" >&2
  exit 2
fi

echo
echo "=================================================================="
echo " Backup recoverability: $ENVIRONMENT  ($BUCKET/$SERVER_NAME)"
echo "=================================================================="
echo

NOW="$(date -u +%s)"

# ---- base backups -----------------------------------------------------------
BASES="$(aws --endpoint-url "$ENDPOINT" s3 ls "s3://$BUCKET/$SERVER_NAME/base/" 2>/dev/null |
         awk '{print $2}' | tr -d '/' | grep -E '^[0-9]{8}T[0-9]{6}$' | sort)"
BASE_COUNT="$(printf '%s\n' "$BASES" | grep -c . || true)"
NEWEST_BASE="$(printf '%s\n' "$BASES" | tail -1)"

if [ "$BASE_COUNT" -eq 0 ] || [ -z "$NEWEST_BASE" ]; then
  bad "no base backup in the archive" \
      "WAL alone cannot restore anything — replay starts FROM a base backup"
else
  # 20260822T084633 -> 2026-08-22 08:46:33 UTC
  ISO="${NEWEST_BASE:0:4}-${NEWEST_BASE:4:2}-${NEWEST_BASE:6:2} ${NEWEST_BASE:9:2}:${NEWEST_BASE:11:2}:${NEWEST_BASE:13:2}"
  BASE_EPOCH="$(date -u -d "$ISO" +%s 2>/dev/null)"
  if [ -z "$BASE_EPOCH" ]; then
    bad "could not parse the newest base backup timestamp ($NEWEST_BASE)"
  else
    AGE=$(( NOW - BASE_EPOCH ))
    if [ "$AGE" -gt "$MAX_BASE_AGE" ]; then
      bad "newest base backup is $(( AGE / 3600 ))h old — $NEWEST_BASE" \
          "older than the $(( MAX_BASE_AGE / 3600 ))h limit; a scheduled run was missed or failed"
    else
      pass "base backups: $BASE_COUNT, newest $NEWEST_BASE ($(( AGE / 60 )) min old)"
    fi
  fi
fi

# ---- WAL continuity ---------------------------------------------------------
# The base backup is a floor; WAL is what carries recoverability forward from it.
# A recent base with a stalled archiver still loses everything since the base.
# s3api rather than `s3 ls`: it returns LastModified as ISO-8601 in UTC. The
# `s3 ls` output is rendered in the CALLER's local timezone, and parsing that as
# UTC skews the age by the local offset -- on the machine this was written on
# (UTC+3) a segment thirty seconds old reported as -177 minutes. The error runs
# in the dangerous direction: it UNDERSTATES staleness, so a stalled archiver
# would have read as healthy and this check would have passed a database that
# had stopped being recoverable hours earlier.
# ONE LINE PER PAGE, not one line. --query is applied to each page of results
# separately, so once the archive passes 1000 objects this returns the newest
# segment OF EACH PAGE. The extra lines then flowed into `date -d` as a single
# argument and it failed to parse:
#
#   could not parse the newest WAL timestamp (2026-08-26T12:45:00.968000+00:00
#   2026-08-26T13:36:45.909000+00:00)
#
# which reads as a broken archive and stops a teardown. It is the gate that
# protects the data calling a healthy backup unrecoverable -- the direction the
# comment above worried about, arrived at differently. It appeared the first
# time the WAL archive grew past a page, so it was always going to show up
# eventually and always as a refusal to destroy.
#
# Sorting across the pages and taking the last is correct for any number of
# them, including one.
NEWEST_WAL_LINE="$(aws --endpoint-url "$ENDPOINT" s3api list-objects-v2 \
                     --bucket "$BUCKET" --prefix "$SERVER_NAME/wals/" \
                     --query 'sort_by(Contents,&LastModified)[-1].[Key,LastModified]' \
                     --output text 2>/dev/null | sort -k2 | tail -1)"
if [ -z "$NEWEST_WAL_LINE" ] || [ "$NEWEST_WAL_LINE" = "None" ]; then
  bad "no WAL segments in the archive" \
      "recoverability cannot advance past the newest base backup"
else
  WAL_NAME="$(echo "$NEWEST_WAL_LINE" | awk '{print $1}')"
  WAL_DATE="$(echo "$NEWEST_WAL_LINE" | awk '{print $2}')"
  WAL_EPOCH="$(date -u -d "$WAL_DATE" +%s 2>/dev/null)"
  if [ -z "$WAL_EPOCH" ]; then
    bad "could not parse the newest WAL timestamp ($WAL_DATE)"
  else
    WAL_AGE=$(( NOW - WAL_EPOCH ))
    if [ "$WAL_AGE" -gt "$MAX_WAL_AGE" ]; then
      bad "newest WAL segment is $(( WAL_AGE / 60 )) min old" \
          "archiving has stalled; everything since is unrecoverable — check the plugin-barman-cloud sidecar"
    else
      pass "WAL: newest $(basename "$WAL_NAME") ($(( WAL_AGE / 60 )) min old)"
    fi
  fi
fi

# ---- what the cluster claims, for contrast ----------------------------------
# Advisory only. Printed so the difference between the claim and the fact is
# visible at the moment somebody is deciding whether to destroy a cluster.
if command -v kubectl >/dev/null 2>&1 && kubectl get cluster postgres -n database >/dev/null 2>&1; then
  COND="$(kubectl get cluster postgres -n database \
          -o jsonpath='{range .status.conditions[?(@.type=="LastBackupSucceeded")]}{.status}{end}' 2>/dev/null)"
  LSB="$(kubectl get cluster postgres -n database -o jsonpath='{.status.lastSuccessfulBackup}' 2>/dev/null)"
  echo
  echo "  for contrast, what the Cluster resource says:"
  echo "      LastBackupSucceeded condition : ${COND:-<absent>}"
  echo "      status.lastSuccessfulBackup   : ${LSB:-<absent — see #145>}"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "BACKUP CHECK FAILED — this database may not be recoverable."
  echo "Do not destroy the cluster until this passes. The bucket is the fact;"
  echo "the Cluster's green condition is a claim about it."
  exit 1
fi

echo "BACKUP CHECK PASSED — a base backup and current WAL are both present."
exit 0
