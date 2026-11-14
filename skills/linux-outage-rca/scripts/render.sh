#!/usr/bin/env bash
# render.sh — validate (Phase 2) and render a phase report XML to HTML with xsltproc.
# Usage: bash render.sh REPORT.xml [OUT.html]
# Browsers block XSLT on local files, so render to HTML instead of opening the XML.
set -euo pipefail
X=${1:?usage: render.sh REPORT.xml [OUT.html]}
OUT=${2:-${X%.xml}.html}
T="$(cd "$(dirname "$0")/../templates" && pwd)"
command -v xsltproc >/dev/null || { echo "xsltproc not found (libxslt / xsltproc package)"; exit 1; }
case $(grep -o -m1 '<rca-phase[12]-[a-z]*' "$X") in
  "<rca-phase1-report")   XSL=$T/phase1.xsl ;;
  "<rca-phase2-analysis")
    XSL=$T/phase2.xsl
    if command -v xmllint >/dev/null; then xmllint --noout --schema "$T/phase2.xsd" "$X"; fi ;;
  *) echo "unknown report type: $X"; exit 1 ;;
esac
xsltproc "$XSL" "$X" > "$OUT"
echo "rendered: $OUT"
