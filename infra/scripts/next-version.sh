#!/usr/bin/env bash
#
# Derive the next semantic version from the conventional commits since the last
# tag (T-6.5, #52).
#
# WHY THIS IS POSSIBLE HERE AT ALL
#
# Because two earlier controls make the history trustworthy. Pull request
# titles are linted against Conventional Commits, and `squash_merge_commit_title`
# is PR_TITLE, so the string that was linted is the string that lands (T-0.10 --
# it was not, and the gap made the history unusable for exactly this).
# Measured on this repository: 20 of the last 20 commits on main parse.
#
# Without both, deriving a version from commit messages produces a number that
# looks authoritative and is arbitrary, which is worse than picking one by hand.
#
# THE RULES
#
#   BREAKING CHANGE in a body, or `!` before the colon   major
#   feat                                                 minor
#   fix, perf                                            patch
#   anything else                                        no release
#
# "Anything else" is deliberate. docs, test, ci, build, chore and refactor
# change nothing a consumer can observe, and cutting a release for them
# produces version numbers that carry no information -- at which point nobody
# reads them.
#
# PRE-1.0
#
# While the major version is 0, a breaking change bumps the MINOR, per semver
# clause 4: anything may change at any time and the public API is not stable.
# The move to 1.0.0 is a deliberate act, not something a commit message causes,
# and it is T-8.5's decision rather than this script's.
#
# Usage:
#   next-version.sh              print the next version, or nothing if no release
#   next-version.sh --explain    also print why, to stderr
#   next-version.sh --self-test  run the rule tests
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Reads commit records on stdin, one per line, with literal \n for newlines in
# the body. Prints major | minor | patch | none.
bump_from_commits() {
  local highest="none"
  local line type_and_scope

  while IFS= read -r line; do
    [ -n "$line" ] || continue

    # A breaking change wins immediately and cannot be downgraded by later lines.
    if printf '%s' "$line" | grep -q 'BREAKING CHANGE'; then
      echo "major"
      return 0
    fi

    # `feat!:` or `fix(scope)!:` -- the ! must be before the colon, which is
    # what distinguishes it from a subject that merely contains one.
    type_and_scope="${line%%:*}"
    if [ "$type_and_scope" != "$line" ] && printf '%s' "$type_and_scope" | grep -qE '^[a-z]+(\([^)]*\))?!$'; then
      echo "major"
      return 0
    fi

    case "$line" in
      feat:*|feat\(*\):*)
        highest="minor"
        ;;
      fix:*|fix\(*\):*|perf:*|perf\(*\):*)
        [ "$highest" = "minor" ] || highest="patch"
        ;;
    esac
  done

  echo "$highest"
}

# ---------------------------------------------------------------------------
apply_bump() {
  local current="$1" bump="$2"
  local major minor patch

  major="${current%%.*}"
  minor="${current#*.}"; minor="${minor%%.*}"
  patch="${current##*.}"

  case "$bump" in
    major)
      # Semver clause 4: while 0.y.z, nothing is stable, so a breaking change
      # is a minor bump rather than a 1.0.0 nobody decided to cut.
      if [ "$major" -eq 0 ]; then
        echo "0.$((minor + 1)).0"
      else
        echo "$((major + 1)).0.0"
      fi
      ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *)     return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
self_test() {
  local failures=0

  check_bump() {
    local name="$1" expected="$2" input="$3" actual
    actual="$(printf '%s\n' "$input" | bump_from_commits)"
    if [ "$actual" = "$expected" ]; then
      printf '  ok   %-44s -> %s\n' "$name" "$actual"
    else
      printf '  FAIL %-44s -> %s (expected %s)\n' "$name" "$actual" "$expected"
      failures=$((failures + 1))
    fi
  }

  check_version() {
    local name="$1" expected="$2" current="$3" bump="$4" actual
    actual="$(apply_bump "$current" "$bump")"
    if [ "$actual" = "$expected" ]; then
      printf '  ok   %-44s %s + %s -> %s\n' "$name" "$current" "$bump" "$actual"
    else
      printf '  FAIL %-44s %s + %s -> %s (expected %s)\n' "$name" "$current" "$bump" "$actual" "$expected"
      failures=$((failures + 1))
    fi
  }

  echo "bump derivation:"
  check_bump "a feature"                    minor "feat(core): add a thing"
  check_bump "a fix"                        patch "fix(gateway): stop doing a thing"
  check_bump "perf counts as a fix"         patch "perf(core): fewer allocations"
  check_bump "docs alone is not a release"  none  "docs: explain the thing"
  check_bump "chore alone is not a release" none  "chore(deps): bump jackson"
  check_bump "bang means breaking"          major "feat(core)!: rename the field"
  check_bump "bang without scope"           major "feat!: rename the field"
  check_bump "BREAKING CHANGE in body"      major "fix(core): tidy up BREAKING CHANGE: removed /api/x"
  check_bump "feature beats fix"            minor "$(printf 'fix: a\nfeat: b')"
  check_bump "breaking beats feature"       major "$(printf 'feat: a\nfeat!: b')"
  check_bump "a colon in prose is not a type" none "docs: note the ratio 3:1"
  check_bump "nothing at all"               none  ""

  echo ""
  echo "version arithmetic:"
  check_version "patch"                     1.2.4 1.2.3 patch
  check_version "minor resets patch"        1.3.0 1.2.3 minor
  check_version "major resets both"         2.0.0 1.2.3 major
  check_version "pre-1.0 breaking is minor" 0.4.0 0.3.7 major
  check_version "pre-1.0 feature"           0.4.0 0.3.7 minor

  echo ""
  if [ "$failures" -ne 0 ]; then
    echo "$failures self-test(s) FAILED"
    return 1
  fi
  echo "all self-tests passed"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  case "${1:-}" in
    --self-test) self_test; return $? ;;
  esac

  local explain=0
  [ "${1:-}" = "--explain" ] && explain=1

  local last_tag current range
  last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"

  if [ -z "$last_tag" ]; then
    # No release has ever been cut. Deriving "the next version" from an empty
    # baseline would be inventing one; the FIRST version is a decision (T-8.5).
    [ "$explain" -eq 1 ] && echo "no v* tag exists — the first version is a decision, not a derivation (T-8.5, #63)" >&2
    return 3
  fi

  current="${last_tag#v}"
  range="${last_tag}..HEAD"

  local bump
  bump="$(git log --format='%s %b' "$range" | bump_from_commits)"

  if [ "$bump" = "none" ]; then
    [ "$explain" -eq 1 ] && echo "no releasable commits since ${last_tag} — only docs/ci/chore/refactor" >&2
    return 4
  fi

  local next
  next="$(apply_bump "$current" "$bump")" || return 1

  [ "$explain" -eq 1 ] && echo "${last_tag} -> v${next} (${bump}, $(git rev-list --count "$range") commits)" >&2
  echo "v${next}"
}

main "$@"
