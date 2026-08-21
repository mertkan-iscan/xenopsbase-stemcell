#!/usr/bin/env bash
#
# Prints the path of a JDK that can actually build this project, or explains why
# there is not one. Nothing else -- the path goes to stdout so a caller can do:
#
#   JH="$(bash infra/scripts/java-home.sh)" && JAVA_HOME="$JH" ./mvnw verify
#
# WHY THIS EXISTS
#
# A machine can easily have three JDKs and none of them selected. This one had
# Java 8 first on PATH, JAVA_HOME pointing at 21, and the 25 the build needs
# installed but unreferenced. The build failed with:
#
#   error: release version 25 not supported
#
# which names neither the JDK it used, nor where that JDK came from, nor the
# correct one sitting on the same disk.
#
# Scoped to the invocation rather than rewriting the user's JAVA_HOME, for the
# same reason TF_GIT in the Makefile is scoped: JAVA_HOME is global, other
# projects on the machine depend on it, and changing it to fix one repository is
# not this repository's call to make.
#
# DELIBERATELY NOT A TOOLCHAIN
#
# Maven toolchains are the "proper" mechanism and were considered. They need a
# ~/.m2/toolchains.xml written per machine with absolute paths in it, which is
# precisely the setup step a template is trying to remove. This finds the JDK
# instead of requiring someone to have already declared it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Read from the pom rather than passed in or hardcoded, so this check cannot
# disagree with what the build actually targets. A duplicated version constant
# is a version constant that will eventually be wrong in one of its two homes.
REQUIRED="${1:-}"
FROM_POM=0
if [ -z "$REQUIRED" ]; then
  REQUIRED="$(grep -oE '<java\.version>[0-9]+</java\.version>' "$ROOT/services/core/pom.xml" \
    | head -1 | grep -oE '[0-9]+')"
  FROM_POM=1
fi

if [ -z "$REQUIRED" ]; then
  echo "java-home.sh: could not read <java.version> from services/core/pom.xml" >&2
  exit 1
fi

# The major version a JDK compiles as. Uses java.specification.version rather
# than parsing `java -version` text: the text format differs across vendors and
# across the 1.8 / 9+ naming change, and this property is just "25".
major_of() {
  local home="$1"
  local out
  out="$("$home/bin/java" -XshowSettings:properties -version 2>&1 \
    | grep -E '^\s*java\.specification\.version' | head -1)" || return 1
  out="${out##*= }"
  out="${out%%.*}"       # 1.8 -> 1, then corrected below
  case "$out" in
    1) echo 8 ;;
    ''|*[!0-9]*) return 1 ;;
    *) echo "$out" ;;
  esac
}

# Prefer what the environment already selected. If JAVA_HOME is correct there is
# nothing to fix, and silently substituting a different JDK would hide a real
# difference between what the developer runs by hand and what make runs.
if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
  if [ "$(major_of "$JAVA_HOME" 2>/dev/null)" = "$REQUIRED" ]; then
    echo "$JAVA_HOME"
    exit 0
  fi
fi

# Everywhere a JDK plausibly lives, on the three platforms this template is
# expected to be developed on.
CANDIDATES=()
while IFS= read -r d; do [ -n "$d" ] && CANDIDATES+=("$d"); done <<EOF
$(ls -d "$HOME"/scoop/apps/*jdk*/current 2>/dev/null)
$(ls -d "/c/Program Files/Amazon Corretto"/jdk* 2>/dev/null)
$(ls -d "/c/Program Files/Eclipse Adoptium"/jdk* 2>/dev/null)
$(ls -d "/c/Program Files/Java"/jdk* 2>/dev/null)
$(ls -d "$HOME"/.sdkman/candidates/java/* 2>/dev/null)
$(ls -d /usr/lib/jvm/* 2>/dev/null)
$(ls -d /Library/Java/JavaVirtualMachines/*/Contents/Home 2>/dev/null)
EOF

FOUND=""
SEEN=""
for c in "${CANDIDATES[@]}"; do
  [ -x "$c/bin/java" ] || continue
  m="$(major_of "$c" 2>/dev/null)" || continue
  SEEN="${SEEN}
    ${m}  ${c}"
  if [ "$m" = "$REQUIRED" ] && [ -z "$FOUND" ]; then
    FOUND="$c"
  fi
done

if [ -n "$FOUND" ]; then
  echo "$FOUND"
  exit 0
fi

# Failing loudly, and naming the thing to fix. The compiler's own message for
# this condition says only "release version N not supported".
{
  echo
  echo "No JDK $REQUIRED found, and this project cannot be built without one."
  if [ "$FROM_POM" = "1" ]; then
    echo "  services/core/pom.xml sets <java.version>$REQUIRED</java.version>."
  else
    echo "  Version $REQUIRED was requested on the command line."
  fi
  echo
  if [ -n "${JAVA_HOME:-}" ]; then
    echo "  JAVA_HOME currently points at:"
    echo "    $JAVA_HOME  (Java $(major_of "$JAVA_HOME" 2>/dev/null || echo 'unreadable'))"
    echo
  fi
  if [ -n "$SEEN" ]; then
    echo "  JDKs found on this machine:$SEEN"
  else
    echo "  No JDK was found in any of the usual locations."
  fi
  echo
  echo "  Install one, e.g.:  scoop install corretto${REQUIRED}-jdk"
  echo "                      sdk install java ${REQUIRED}-amzn"
  echo
} >&2
exit 1
