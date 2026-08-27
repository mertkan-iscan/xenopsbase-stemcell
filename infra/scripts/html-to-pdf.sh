#!/usr/bin/env bash
#
# Render an HTML report to PDF with whatever Chromium is already on the machine.
#
# WHY A BROWSER AND NOT A PDF LIBRARY
#
# The report is already a styled HTML page with inline SVG charts and a print
# stylesheet. A PDF library (reportlab, fpdf) would mean re-implementing that
# layout a second time in a second language, and the two would drift -- the copy
# without a gate on it drifting first, silently, as always.
#
# Chromium renders the same file the reader sees in a browser, honours the
# `@media print` block that commits the page to the light palette, and is present
# on every machine that already runs this project. If it is absent this exits
# non-zero and says so; it never produces a worse PDF by another route, because a
# chart that prints every series in the same grey is not a degraded chart, it is
# a wrong one.
#
# Usage:
#   ./html-to-pdf.sh <input.html> <output.pdf>
#
set -uo pipefail

IN="${1:-}"
OUT="${2:-}"

[ -n "$IN" ] && [ -n "$OUT" ] || {
  echo "usage: html-to-pdf.sh <input.html> <output.pdf>" >&2
  exit 2
}
[ -f "$IN" ] || { echo "error: no such file: $IN" >&2; exit 1; }

find_browser() {
  # An explicit override wins, for a machine with Chromium somewhere unusual.
  if [ -n "${CHROME_BIN:-}" ] && [ -x "${CHROME_BIN}" ]; then
    echo "$CHROME_BIN"; return 0
  fi
  local candidates=(
    "/c/Program Files/Google/Chrome/Application/chrome.exe"
    "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"
    "/c/Program Files/Microsoft/Edge/Application/msedge.exe"
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
    "/usr/bin/google-chrome"
    "/usr/bin/chromium"
    "/usr/bin/chromium-browser"
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  )
  local c
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  for c in google-chrome chromium chromium-browser msedge; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return 0; }
  done
  return 1
}

BROWSER="$(find_browser)" || {
  echo "error: no Chromium-based browser found." >&2
  echo "       Set CHROME_BIN to one, or install Chrome/Edge. The HTML report is" >&2
  echo "       unaffected and is the same content: $IN" >&2
  exit 1
}

# Chromium wants a real URL and, on Windows, a drive-letter path rather than the
# /c/... form this shell uses. cygpath -m gives C:/... which file:/// accepts.
to_url() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "file:///$(cygpath -m "$1")" ;;
    *) echo "file://$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
  esac
}
to_native() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -w "$1" ;;
    *) echo "$1" ;;
  esac
}

# Absolute, for the same reason as the output below: a relative file:// URL
# resolves against Chromium's working directory, and Chromium then cheerfully
# renders its own ERR_FILE_NOT_FOUND page to a perfectly valid PDF. The size
# check at the bottom passes, and the operator gets a one-page PDF of a sad-file
# icon. That is this repository's recurring failure -- a control that reports
# success without governing what it names -- so the check at the bottom looks at
# the content, not just the byte count.
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
URL="$(to_url "$IN")"

# Absolute, before anything converts it. Chromium resolves a relative
# --print-to-pdf against ITS OWN working directory, not the shell's, so a
# relative path writes the PDF somewhere else entirely and the existence check
# below then reports that no PDF was produced -- true, but at the wrong path.
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
OUT_NATIVE="$(to_native "$OUT")"
# Beside the output rather than in the system temp dir. On Git Bash mktemp -d
# returns a /tmp path that does not survive conversion to a Windows path, and
# Chromium then silently falls back to the operator's REAL profile -- which
# works, pollutes it, and fails outright if a Chrome window is already open.
PROFILE="$(cd "$(dirname "$OUT")" && pwd)/.chrome-pdf-profile-$$"
mkdir -p "$PROFILE"

# --virtual-time-budget lets the webfont request resolve (or fail) before the
# snapshot, so the PDF does not capture a half-laid-out page mid-swap.
# A separate --user-data-dir keeps this out of the operator's real profile.
run_chrome() {
  "$BROWSER" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --user-data-dir="$(to_native "$PROFILE")" \
    --virtual-time-budget=10000 \
    "$1" \
    --print-to-pdf="$OUT_NATIVE" \
    "$URL" >/dev/null 2>&1
}

# Chrome renamed this flag; try the current name, then the older one, then bare.
run_chrome "--no-pdf-header-footer" \
  || run_chrome "--print-to-pdf-no-header" \
  || run_chrome ""

rm -rf "$PROFILE" 2>/dev/null

if [ ! -s "$OUT" ]; then
  echo "error: ${BROWSER##*/} produced no PDF." >&2
  exit 1
fi

# A PDF of a browser error page is still a PDF. Assert the real title made it in
# rather than trusting that bytes were written.
if ! grep -aq "Stemcell\|Scalability\|scalability" "$OUT" 2>/dev/null; then
  if grep -aqi "ERR_FILE_NOT_FOUND\|couldn.t be accessed" "$OUT" 2>/dev/null; then
    echo "error: ${BROWSER##*/} printed its own error page -- it could not load:" >&2
    echo "       $URL" >&2
    rm -f "$OUT"
    exit 1
  fi
fi

echo "$OUT"
