#!/usr/bin/env bash
#
# The list of services, read from the one place that already has to be right.
#
# WHY THIS EXISTS. Before the parent pom there were six copies of `core gateway`
# in this repository -- two in .github/workflows/services.yml, one in codeql.yml,
# one in security.yml, and four Makefile loops. Adding a third service meant
# finding all of them. The ones that got missed would not fail: a workflow that
# never builds a service is a green workflow.
#
# services/pom.xml's <modules> is the list Maven itself uses, so it cannot be
# stale without the build breaking. Everything else derives from it.
#
# Usage:
#   service-modules.sh            deployable services, space-separated  -> "gateway core"
#   service-modules.sh --all      every module, in build order          -> "platform-common ... core"
#   service-modules.sh --json     deployable services as a JSON array, for a GitHub Actions matrix
#
# "Deployable" means everything except the shared libraries, which are named by
# convention: platform-common and platform-common-web. A module is a service if
# it is not one of those -- so a new library must follow the naming, and a new
# service needs no edit here at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POM="$ROOT/services/pom.xml"

if [ ! -f "$POM" ]; then
  echo "service-modules.sh: no $POM" >&2
  exit 1
fi

# Only the <modules> block, so a <module> mentioned in a comment or a profile
# elsewhere in the file cannot leak into the list.
all_modules() {
  sed -n '/<modules>/,/<\/modules>/p' "$POM" \
    | grep -oE '<module>[^<]+</module>' \
    | sed -e 's|<module>||' -e 's|</module>||'
}

services() {
  all_modules | grep -vE '^platform-common(-web)?$' || true
}

case "${1:-}" in
  --all)
    all_modules | tr '\n' ' ' | sed 's/ $//'
    echo
    ;;
  --json)
    # Built in the shell rather than piped through python3: on Windows `python3`
    # is a Microsoft Store stub that satisfies `command -v` and then refuses to
    # run, so a python one-liner here works in CI and fails on a developer
    # machine -- the worst of the two places to find out.
    printf '['
    sep=''
    while read -r m; do
      [ -n "$m" ] || continue
      printf '%s"%s"' "$sep" "$m"
      sep=', '
    done < <(services)
    printf ']
'
    ;;
  "")
    services | tr '\n' ' ' | sed 's/ $//'
    echo
    ;;
  *)
    echo "service-modules.sh: unknown option $1" >&2
    exit 2
    ;;
esac
