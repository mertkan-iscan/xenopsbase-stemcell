#!/usr/bin/env bash
#
# Generate the changelog section for a release, from conventional commits
# (T-6.5, #52).
#
# WHAT THIS DOES NOT DO, AND WHY
#
# It does not replace CHANGELOG.md. That file opens by saying it "records
# decisions that a fork inherits and would otherwise have to reverse-engineer",
# and its Unreleased section is hand-written prose explaining WHY the project
# left the generator, what is unrecoverable, and what a fork must know. No
# commit-message generator produces that, and overwriting it with a bulleted
# list of subjects would trade the only genuinely valuable part of the file for
# something anybody can get from `git log`.
#
# So this APPENDS a generated section and leaves the prose alone. The two coexist
# deliberately: generated lists answer "what changed", the hand-written parts
# answer "what does that mean for me".
#
# Usage:
#   release-notes.sh <version> [<since-ref>]
#
set -uo pipefail

VERSION="${1:?usage: release-notes.sh <version> [<since-ref>]}"
SINCE="${2:-}"

if [ -z "$SINCE" ]; then
  SINCE="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
fi

if [ -n "$SINCE" ]; then
  RANGE="${SINCE}..HEAD"
else
  RANGE="HEAD"
fi

emit_section() {
  local heading="$1" pattern="$2" found=0 line subject

  while IFS= read -r line; do
    subject="${line#* }"
    if printf '%s' "$subject" | grep -qE "$pattern"; then
      if [ "$found" -eq 0 ]; then
        printf '\n### %s\n\n' "$heading"
        found=1
      fi
      # Drop the type prefix: the heading already says what kind of change it
      # is, and repeating "fix(core):" on every line under "Fixed" is noise.
      printf -- '- %s (%s)\n' "$(printf '%s' "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //')" "${line%% *}"
    fi
  done < <(git log --format='%h %s' "$RANGE" --no-merges)
}

printf '## %s — %s\n' "$VERSION" "$(date -u +%Y-%m-%d)"

emit_section "Breaking"  '^[a-z]+(\([^)]*\))?!:'
emit_section "Added"     '^feat(\([^)]*\))?:'
emit_section "Fixed"     '^(fix|perf)(\([^)]*\))?:'
emit_section "Internal"  '^(build|ci|refactor|test|chore)(\([^)]*\))?:'
emit_section "Documentation" '^docs(\([^)]*\))?:'

printf '\n'
if [ -n "$SINCE" ]; then
  printf '_%s commits since %s._\n' "$(git rev-list --count "$RANGE")" "$SINCE"
else
  printf '_%s commits._\n' "$(git rev-list --count "$RANGE")"
fi
