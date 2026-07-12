#!/usr/bin/env bash
# tests/test-scaffold.sh — structural smoke for `pf-app new`.
#
# Scaffolds both families to a temp dir and asserts: the expected files exist, the
# launch/build/sim/oci scripts are executable, no template token survives, and (if a
# platform checkout is reachable) the emitted app.toml validates through `pf app-validate`.
# No network, no docker, no device.
#
# Usage:
#   tests/test-scaffold.sh
#   PLATFORM_PF=/path/to/platform/pf tests/test-scaffold.sh   # also run app-validate
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PF_APP="$HERE/pf-app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0

# Resolve a platform `pf` for the optional validate step: explicit env, else a sibling checkout.
PLATFORM_PF="${PLATFORM_PF:-}"
if [ -z "$PLATFORM_PF" ]; then
    for c in "$HERE/../platform/pf" "$HOME/platform/pf" "/tmp/platform-ref/pf"; do
        [ -x "$c" ] && { PLATFORM_PF="$c"; break; }
    done
fi

for dev in a133 a523; do
    out="$TMP/$dev"
    "$PF_APP" new "Smoke $dev" --device "$dev" --id "com.example.smoke$dev" --dir "$out" >/dev/null

    for f in app.toml launch src/main.c build.sh Makefile pins.env \
             ci/run-under-sim.py oci/build-oci.sh README.md LICENSE .gitignore \
             .github/workflows/app-smoke.yml; do
        [ -f "$out/$f" ] || fail "$dev: missing $f"
    done
    for x in launch build.sh ci/run-under-sim.py oci/build-oci.sh; do
        [ -x "$out/$x" ] || fail "$dev: $x is not executable"
    done

    # No unsubstituted tokens survived anywhere.
    if grep -rlE '\{\{[A-Z0-9_]+\}\}' "$out" >/dev/null 2>&1; then
        grep -rnE '\{\{[A-Z0-9_]+\}\}' "$out" >&2
        fail "$dev: unsubstituted template token(s) survived"
    fi

    # Family pin matches the device.
    case "$dev" in
        a133) want="pocketforge/a133-powervr" ;;
        a523) want="pocketforge/a523-mali" ;;
    esac
    grep -q "family *= *\"$want\"" "$out/app.toml" || fail "$dev: app.toml family != $want"

    # Optional: validate through the platform static validator.
    if [ -n "$PLATFORM_PF" ]; then
        "$PLATFORM_PF" app-validate "$out/app.toml" >/dev/null \
            || fail "$dev: pf app-validate rejected the emitted app.toml"
        echo "  $dev: app.toml validates via $PLATFORM_PF"
    fi

    echo "OK: $dev scaffold structural check passed"
    pass=$((pass + 1))
done

[ -n "$PLATFORM_PF" ] || echo "NOTE: platform 'pf' not found — skipped app-validate (set PLATFORM_PF=...)"
echo "PASS: $pass/2 families"
