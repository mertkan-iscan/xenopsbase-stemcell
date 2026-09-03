#!/usr/bin/env bash
#
# The load baseline as a SERIES rather than a verdict (T-5.10, #207).
#
# WHY THIS EXISTS
#
# #387 put the baseline on a clock and keeps each run's output as an artifact.
# That satisfied three of T-5.10's four criteria and explicitly did not satisfy
# the fourth:
#
#   Successive runs are comparable -- a trend, not a single verdict
#
# What existed was comparison by opening two files. A threshold catches a
# regression that arrives all at once; it cannot catch the one that arrives at
# 3% a week, because every individual run passes. That slow decay is the failure
# mode this criterion is about, and it is only visible as a series.
#
# WHY THE ARTIFACTS AND NOT PROMETHEUS
#
# Prometheus's storage is a PVC inside the cluster and the cluster is destroyed
# most nights (ADR-0002), so a series there resets daily -- a trend across weeks
# cannot exist in it. Artifacts outlive the cluster, which is the property that
# matters.
#
# WHAT THIS DOES NOT CLAIM
#
# GitHub keeps these artifacts for 90 days, so this is a 90-day window and not a
# permanent record. Making it permanent means writing each run's numbers to the
# object storage ADR-0002 already uses for durable state -- a separate change,
# and one worth doing only if 90 days turns out to be too short. It is stated
# here rather than discovered later.
#
# WHY PARSING TEXT IS ACCEPTABLE HERE, WHICH IT USUALLY IS NOT
#
# k6 is pinned (`grafana/k6:0.55.0` in load-test.sh, and in three sibling
# scripts), so the summary format is a fixed input rather than whatever the
# latest release prints. The alternative -- a `handleSummary` in baseline.js
# emitting JSON -- needs k6's remote jslib for the text summary it would replace,
# which puts a network dependency inside the measurement.
#
# The parser fails LOUDLY on a log it cannot read rather than skipping it. A
# trend tool that silently drops the runs it does not understand reports an
# improving picture by discarding the evidence.
#
# Usage:
#   ./load-trend.sh [runs]     default 20, which is well past the 90-day window
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

RUNS="${1:-20}"

command -v gh >/dev/null 2>&1 || {
  echo "error: the GitHub CLI (gh) is required; the artifacts live there" >&2
  exit 1
}

# Test each candidate by RUNNING it. On Windows `python3` is a Store alias that
# satisfies `command -v` and then prints an advert and exits.
PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json,sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
[ -n "$PY_BIN" ] || {
  echo "error: a working python3 (or python) is required" >&2
  exit 1
}

echo "=================================================================="
echo " Load baseline trend — last ${RUNS} scheduled runs"
echo "=================================================================="
echo ""

WORK="$(mktemp -d)"

# The path handed to python, which is not always the path bash uses.
#
# Under Git Bash on Windows `mktemp -d` returns `/tmp/tmp.XXXX`, which bash
# resolves and a native python interpreter does not -- it looks for `C:	mp\...`
# and finds nothing. `cygpath -m` converts to the form both understand. Absent on
# Linux and CI, where the two already agree, so the fallback is the path itself.
if command -v cygpath >/dev/null 2>&1; then
  WORK_PY="$(cygpath -m "$WORK")"
else
  WORK_PY="$WORK"
fi
trap 'rm -rf "$WORK"' EXIT INT TERM

gh run list --workflow=load-regression.yml --limit "$RUNS" \
  --json databaseId,createdAt,conclusion,headSha,event > "$WORK/runs.json" 2>/dev/null || {
    echo "error: could not list runs of load-regression.yml" >&2
    exit 1
  }

# `</dev/null` on the gh call below is load bearing: without it gh reads the
# loop's OWN stdin -- the list of runs -- and the next `read` gets a mangled
# line. It surfaces as a parse error about field counts, naming nothing to do
# with downloading. The classic shape of bug for a command inside a while-read
# loop, and it cost two runs to find.
#
# Downloaded one at a time rather than in one call, because a run that took the
# no-cluster path has no artifact at all and `gh run download` fails on it.
# That is the normal overnight state (ADR-0002), not an error, so it is reported
# as "no cluster" and the series continues.
"$PY_BIN" - "$WORK_PY/runs.json" <<'PY' > "$WORK/ids.txt"
import json
import sys

# LF, even on Windows. A native python writes CRLF by default; the CR then sits
# mid-line in the file bash builds from this, and universal-newline translation
# later reads that lone CR as a LINE BREAK -- splitting one record into two and
# surfacing as a field-count error that names nothing useful.
sys.stdout.reconfigure(newline=chr(10))

with open(sys.argv[1], encoding="utf-8") as handle:
    for run in json.load(handle):
        print("%s\t%s\t%s\t%s" % (run["databaseId"], run["createdAt"], run["conclusion"], run["headSha"][:7]))
PY

while IFS=$'\t' read -r id created conclusion sha; do
  if gh run download "$id" -D "$WORK/$id" >/dev/null 2>&1 </dev/null; then
    printf '%s\t%s\t%s\t%s\tyes\n' "$id" "$created" "$conclusion" "$sha"
  else
    printf '%s\t%s\t%s\t%s\tno\n' "$id" "$created" "$conclusion" "$sha"
  fi
done < "$WORK/ids.txt" > "$WORK/downloaded.txt"

"$PY_BIN" - "$WORK_PY" "$WORK_PY/downloaded.txt" <<'PY'
import os
import re
import sys

work, index = sys.argv[1], sys.argv[2]

# k6 0.55.0's summary lines. Anchored on the metric name so a reordered summary
# still parses, and on the exact `p(95)=` spelling so a format change fails
# rather than silently matching something else.
TREND = r"%s\.*:\s*avg=(\S+)\s+min=(\S+)\s+med=(\S+)\s+p\(95\)=(\S+)\s+p\(99\)=(\S+)"
FAILED = re.compile(r"http_req_failed\.*:\s*([0-9.]+)%")
REQS = re.compile(r"http_reqs\.*:\s*(\d+)\s+([0-9.]+)/s")


def ms(value):
    """k6 prints 1.21s, 72.38ms, 459.08µs. Normalised to milliseconds."""
    value = value.strip()
    for suffix, factor in (("µs", 0.001), ("us", 0.001), ("ms", 1.0), ("s", 1000.0)):
        if value.endswith(suffix):
            return float(value[: -len(suffix)]) * factor
    raise ValueError("unrecognised duration %r" % value)


def parse(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()

    out = {}
    for name in ("latency_gateway_only", "latency_through_core"):
        match = re.search(TREND % name, text, re.M)
        if not match:
            raise ValueError("no %s line in %s" % (name, os.path.basename(path)))
        out[name] = (ms(match.group(4)), ms(match.group(5)))

    failed = FAILED.search(text)
    reqs = REQS.search(text)
    if not failed or not reqs:
        raise ValueError("no http_req_failed / http_reqs line in %s" % os.path.basename(path))
    out["failed"] = float(failed.group(1))
    out["reqs"] = int(reqs.group(1))
    out["rate"] = float(reqs.group(2))
    return out


rows = []
skipped = []
with open(index, encoding="utf-8") as handle:
    for line in handle:
        run_id, created, conclusion, sha, has_artifact = line.rstrip("\n").split("\t")
        if has_artifact != "yes":
            skipped.append((created[:16], sha, conclusion))
            continue
        logs = []
        for root, _dirs, files in os.walk(os.path.join(work, run_id)):
            logs.extend(os.path.join(root, f) for f in files if f.endswith(".log"))
        if not logs:
            skipped.append((created[:16], sha, conclusion))
            continue
        # Fails loudly. A trend that drops what it cannot read reports an
        # improving picture by discarding the evidence.
        rows.append((created[:16], sha, conclusion, parse(sorted(logs)[-1])))

rows.sort(key=lambda r: r[0])

if not rows:
    print("  No runs with artifacts in the window.")
    print("  That is the normal state if the cluster has been down: the job succeeds")
    print("  with a notice and produces nothing to compare.")
    sys.exit(0)

print("  %-16s %-8s %-9s %9s %9s %9s %9s %8s %9s" % ("when (UTC)", "commit", "result", "gw p95", "gw p99", "core p95", "core p99", "failed", "req/s"))
for created, sha, conclusion, m in rows:
    print(
        "  %-16s %-8s %-9s %8.2fms %8.2fms %8.2fms %8.2fms %7.2f%% %9.0f"
        % (
            created.replace("T", " "),
            sha,
            conclusion,
            m["latency_gateway_only"][0],
            m["latency_gateway_only"][1],
            m["latency_through_core"][0],
            m["latency_through_core"][1],
            m["failed"],
            m["rate"],
        )
    )

if skipped:
    print("")
    print("  Runs that measured nothing (listed after the table, so the series above stays in order):")
for created, sha, conclusion in skipped:
    print("  %-16s %-8s %-9s   no cluster - nothing measured" % (created.replace("T", " "), sha, conclusion))

# THE DRIFT CHECK, WHICH IS THE WHOLE POINT.
#
# Thresholds catch a regression that arrives at once. This catches the one that
# arrives gradually: the newest run against the MEDIAN of the others, so a
# single noisy run neither triggers it nor hides it.
#
# Reported, never gated. The load baseline's own thresholds are the gate
# (T-5.6); a second gate here with a number nobody measured would be a threshold
# picked in advance, which T-2.20 argues against for the same reason.
if len(rows) >= 3:
    print("")
    latest = rows[-1][3]
    for label, key in (("gateway", "latency_gateway_only"), ("core", "latency_through_core")):
        history = sorted(r[3][key][0] for r in rows[:-1])
        median = history[len(history) // 2]
        current = latest[key][0]
        change = (current - median) / median * 100 if median else 0.0
        verdict = "  drifting" if change > 50 else ""
        print("  %-8s p95 latest %7.2fms vs median %7.2fms of %d runs   %+6.1f%%%s" % (label, current, median, len(history), change, verdict))
else:
    print("")
    print("  (%d run(s) with numbers; drift needs at least 3 to have a median worth comparing to)" % len(rows))
PY
