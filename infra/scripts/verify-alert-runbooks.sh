#!/usr/bin/env bash
#
# Every alert links to a runbook section, and the section exists (T-7.6, #58).
#
# WHY THE SECOND HALF IS THE POINT
#
# "Every alert has a runbook link" is a one-afternoon sweep and a permanent
# regression risk: the next alert is written without one, and nobody notices
# until it fires at 3am and the annotation nobody added is the thing that would
# have said what to do.
#
# So it is a check. And it does not stop at "an annotation is present": it
# resolves the file AND the anchor. A link to a heading somebody renamed is
# worse than no link, because it is followed.
#
# Anchors are matched the way GitHub generates them from a heading: lower-cased,
# spaces to hyphens, punctuation dropped. That is a reimplementation and it can
# disagree at the margins -- backticks and unicode are the usual culprits -- so
# the failure message prints the anchors it DID find in the target file rather
# than only saying no.
#
# WHY IT READS THE MANIFESTS AND NOT PROMETHEUS
#
# Same reason verify-resources.sh does: it runs in CI, where there is no
# cluster, and the question is about what is committed rather than what happens
# to be loaded.
#
# Usage:
#   ./verify-alert-runbooks.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

RULES_GLOB="platform/envs/*/observability/alerts-*.yaml"

PY_BIN=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import re,sys' >/dev/null 2>&1; then
    PY_BIN="$candidate"
    break
  fi
done
if [ -z "$PY_BIN" ]; then
  echo "error: a working python3 (or python) is required" >&2
  exit 1
fi

"$PY_BIN" - "$RULES_GLOB" <<'PY'
import glob
import re
import sys

pattern = sys.argv[1]
files = sorted(glob.glob(pattern))

if not files:
    print("error: no alert files matched %s -- the layout moved, or this check "
          "is now looking at nothing." % pattern)
    sys.exit(1)


def anchors(path):
    """The anchors GitHub would generate for a markdown file's headings."""
    found = set()
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if not line.startswith("#"):
                    continue
                text = line.lstrip("#").strip()
                slug = text.lower()
                slug = re.sub(r"[^\w\s-]", "", slug)
                slug = re.sub(r"\s+", "-", slug).strip("-")
                if slug:
                    found.add(slug)
    except OSError:
        return None
    return found


print("=" * 66)
print(" Every alert links to a runbook section that exists")
print("=" * 66)
print("")

failures = 0
checked = 0

for path in files:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    alert = None
    start = 0
    blocks = []
    for index, line in enumerate(lines):
        match = re.match(r"^\s*- alert:\s*(\S+)", line)
        if match:
            if alert:
                blocks.append((alert, start, index))
            alert, start = match.group(1), index
    if alert:
        blocks.append((alert, start, len(lines)))

    for name, begin, end in blocks:
        checked += 1
        body = "\n".join(lines[begin:end])
        link = re.search(r"^\s*runbook:\s*(\S+)\s*$", body, re.M)

        if not link:
            print("  FAIL  %-34s no runbook annotation" % name)
            print("        %s" % path)
            failures += 1
            continue

        target = link.group(1)
        doc, _, anchor = target.partition("#")
        available = anchors(doc)

        if available is None:
            print("  FAIL  %-34s runbook file does not exist" % name)
            print("        %s -> %s" % (path, doc))
            failures += 1
        elif anchor and anchor not in available:
            print("  FAIL  %-34s no such section in %s" % (name, doc))
            print("        wanted #%s" % anchor)
            print("        found  %s" % ", ".join("#" + a for a in sorted(available)[:8]))
            failures += 1
        else:
            print("  ok    %-34s %s" % (name, target))

print("")
print("=" * 66)
if failures:
    print(" FAILED - %d of %d alert(s) point nowhere." % (failures, checked))
    print("=" * 66)
    sys.exit(1)
print(" PASSED - %d alert(s), every runbook link resolves." % checked)
print("=" * 66)
PY
