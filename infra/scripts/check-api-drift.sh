#!/usr/bin/env bash
#
# The committed API spec must describe the API the service actually serves (T-5.4, #43).
#
# WHY THIS EXISTS
#
# docs/api/core.json is a CONTRACT ARTIFACT, not documentation. clients/java is
# generated from it, and anything else consuming this API is entitled to treat
# it as true. Nothing verified that it was.
#
# The machinery was already almost all here. OpenApiSpecIT generates the spec
# from the running application and canonicalises it — sorted keys, LF endings —
# and its own comment says that canonicalisation exists because unstable
# ordering would be "fatal to the CI check that fails when the committed spec
# drifts". That check was never written. The canonicalisation has been
# protecting a gate that did not exist.
#
# So the failure mode was: change an endpoint, do not run `make api-spec`, and
# the committed contract silently describes an API that is gone. The generated
# client keeps compiling — against the old spec — and the first person to
# notice is a consumer at runtime.
#
# WHAT THIS IS NOT
#
# It is not a breaking-change check; that is check-api-breaking.py, and the two
# answer different questions. This one asks "is the committed artifact true?".
# Any change trips it, including a purely additive one, and that is deliberate:
# an API change should be visible in review, which is exactly what `make
# api-spec` prints when it updates the files.
#
# Usage:
#   check-api-drift.sh <generated-spec> <committed-spec>
#
set -uo pipefail

GENERATED="${1:?usage: check-api-drift.sh <generated-spec> <committed-spec>}"
COMMITTED="${2:?usage: check-api-drift.sh <generated-spec> <committed-spec>}"

if [ ! -f "$GENERATED" ]; then
  echo "error: $GENERATED does not exist."
  echo "       The spec is written by OpenApiSpecIT, so this usually means the"
  echo "       integration tests did not run. Check for -DskipITs."
  exit 1
fi

if [ ! -f "$COMMITTED" ]; then
  echo "error: $COMMITTED does not exist — the contract artifact is missing."
  echo "       run: make api-spec"
  exit 1
fi

if diff -u "$COMMITTED" "$GENERATED" > /tmp/api-drift.$$ 2>&1; then
  echo "OK  $COMMITTED matches the API the service serves."
  rm -f /tmp/api-drift.$$
  exit 0
fi

echo "=================================================================="
echo " API SPEC DRIFT"
echo "=================================================================="
echo ""
echo "  committed: $COMMITTED"
echo "  actual:    $GENERATED"
echo ""
echo "The committed contract does not describe the API this service serves."
echo "clients/java is generated from the committed file, so it is currently"
echo "being built against an API that does not exist."
echo ""
# Bounded on purpose. A whole-spec diff is thousands of lines and nobody reads
# the log; the first 60 lines are enough to see WHAT changed, and the fix does
# not depend on seeing all of it.
head -60 /tmp/api-drift.$$
total=$(wc -l < /tmp/api-drift.$$)
if [ "$total" -gt 60 ]; then
  echo ""
  echo "  ... $((total - 60)) more diff lines suppressed"
fi
rm -f /tmp/api-drift.$$
echo ""
echo "Fix: run `make api-spec` and commit the result. An API change is supposed"
echo "to be visible in review — that is the point of committing the artifact."
exit 1
