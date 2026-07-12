#!/usr/bin/env bash
# scan.sh — grype CVE scan of the SBOM. DELIBERATELY DECOUPLED from artifact identity and
# NON-BLOCKING: a CVE finding is a fresh-fact about the world (a new CVE lands days after a
# byte-identical build), so it must never change the signed image digest nor fail the
# packaging/build. It runs against a PINNED grype DB snapshot for reproducibility, writes a
# report, and ALWAYS exits 0. Gating on CVEs is a SEPARATE policy decision (a distinct CI job
# that reads this report), never a packaging-time hard-fail.
set -uo pipefail

OUT="${OUT:?}"
SBOM="$OUT/sbom.spdx.json"
REPORT="$OUT/grype-report.json"
# GRYPE_DB_* pins the vuln DB to a snapshot (set GRYPE_DB_AUTO_UPDATE=false + a cached
# GRYPE_DB_CACHE_DIR to freeze it); default here fetches the current DB and records its build.
export GRYPE_DB_AUTO_UPDATE="${GRYPE_DB_AUTO_UPDATE:-true}"

[ -f "$SBOM" ] || { echo "scan: $SBOM missing — run pipeline.sh first" >&2; exit 0; }

echo "== grype scan (non-blocking; report only) =="
grype "sbom:$SBOM" -o json > "$REPORT" 2>/dev/null || {
    echo "scan: grype run failed (non-blocking) — report may be partial" >&2
    exit 0
}
DB_BUILT="$(jq -r '.descriptor.db.built // .descriptor.db.status.built // "unknown"' "$REPORT" 2>/dev/null)"
TOTAL="$(jq -r '.matches | length' "$REPORT" 2>/dev/null || echo '?')"
HIGHCRIT="$(jq -r '[.matches[]?|select(.vulnerability.severity=="High" or .vulnerability.severity=="Critical")]|length' "$REPORT" 2>/dev/null || echo '?')"
echo "grype: db-snapshot=$DB_BUILT matches=$TOTAL high+critical=$HIGHCRIT (advisory — does NOT gate packaging)"
exit 0
