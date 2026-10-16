#!/usr/bin/env bash
# test-run-under-sim-fake.sh — hermetic unit proof of the scaffolded ci/run-under-sim.py
# against a FAKE private sim Device (design §7 acceptance: "run its generated
# ci/run-under-sim unit tests against a fake/private Device").
#
# Nothing here touches qemu, a kernel input node, a FIFO, docker or a display: the fake
# control surface writes uniform PPM frames straight to the outdir, exactly the contract
# sim's control_surface.Device exposes (boot/snapshot/inputs/press/shutdown). The REAL
# route — the sim's per-run private FIFOs (FifoSynth, incident tsp-ihne1.56.5) inside the
# pocketforge-sim container — is what CI executes via app-smoke's `sim` job.
#
# Cases, all in ONE invocation (positive + negative controls):
#   FAKE_MODE=happy       rest grey -> press -> green: wrapper exits 0, prints PASS,
#                         stages the descriptor + both frames (positive control)
#   FAKE_MODE=dead-press  pressed frame stays grey:  wrapper exits non-zero, "not green"
#   FAKE_MODE=no-button   descriptor has no button:  wrapper exits non-zero, "no button"
#
# Usage: tests/test-run-under-sim-fake.sh
# Env:   PF_APP_RUN_UNDER_SIM_ROOT (template-root override), PF_APP_RUN_UNDER_SIM_PYTHON.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${PF_APP_RUN_UNDER_SIM_ROOT:-$HERE}"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-app-rus-fake.XXXXXX")"
cleanup() {
  find "$TMP" -mindepth 1 -delete
  rmdir "$TMP"
}
trap cleanup EXIT

PY="${PF_APP_RUN_UNDER_SIM_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FATAL: no python3 interpreter found" >&2; exit 3; }

APP="$TMP/app"
"$ROOT/pf-app" new "Smoke a133" --device a133 --id com.example.smokea133 --dir "$APP" >/dev/null

FAKE="$TMP/fake"
mkdir -p "$FAKE/sim/control" "$FAKE/sim/fb" "$FAKE/platform/devices/a133" "$FAKE/rootfs"
printf '[device]\nid = "a133"\n' > "$FAKE/platform/devices/a133/capabilities.toml"
printf 'fake-binary' > "$FAKE/app.arm64"
printf 'fake-qemu' > "$FAKE/qemu-tsp"

cat > "$FAKE/sim/control/control_surface.py" <<'FAKEPY'
"""Fake of sim's control_surface.Device for the wrapper's hermetic test.

Same call contract (boot/snapshot/inputs/press/shutdown; frames land at
<outdir>/frames/<name>.ppm; snapshot returns the frame name), but it writes
uniform PPMs straight to disk — no qemu, no FIFOs, no kernel nodes.
FAKE_MODE: happy | dead-press | no-button.
"""
import os
from pathlib import Path

_MODE = os.environ.get("FAKE_MODE", "happy")


def _ppm(path, rgb):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(b"P6\n2 2\n255\n")
        fh.write(bytes(rgb) * 4)


class Device:
    def __init__(self, device, platform, launcher=None, outdir=None,
                 app_arm64=None, qemu_tsp=None, rootfs=None):
        self.device = device
        self.outdir = Path(outdir)
        self._pressed = False

    def boot(self):
        pass

    def inputs(self):
        if _MODE == "no-button":
            return [{"kind": "stick", "id": "left_stick"}]
        return [{"kind": "button", "id": "btn_south"}]

    def press(self, button_id):
        self._pressed = True

    def snapshot(self, name):
        green = (name == "pressed" and self._pressed and _MODE != "dead-press")
        _ppm(self.outdir / "frames" / f"{name}.ppm",
             (0, 255, 0) if green else (128, 128, 128))
        return name

    def shutdown(self):
        pass
FAKEPY

cat > "$FAKE/sim/fb/ppm2png.py" <<'FAKEPY'
"""Fake of sim's ppm2png: raw P6 reader (no PNG dependency needed here)."""


def read_ppm(path):
    with open(path, "rb") as fh:
        data = fh.read()
    parts = data.split(b"\n", 3)
    w, h = parts[1].split()
    return int(w), int(h), parts[3]
FAKEPY

failures=0

run_case() {
  # run_case <mode> <outdir> — echoes combined output, returns wrapper exit status.
  local mode="$1" outdir="$2"
  mkdir -p "$outdir"
  FAKE_MODE="$mode" "$PY" "$APP/ci/run-under-sim.py" \
    --device a133 \
    --binary "$FAKE/app.arm64" \
    --sim "$FAKE/sim" \
    --platform "$FAKE/platform" \
    --qemu-tsp "$FAKE/qemu-tsp" \
    --rootfs "$FAKE/rootfs" \
    --outdir "$outdir" 2>&1
}

check() {
  local name="$1" ok="$2" detail="$3"
  if [ "$ok" = "1" ]; then
    echo "case $name: PASS ($detail)"
  else
    echo "case $name: FAIL ($detail)"
    failures=$((failures + 1))
  fi
}

set +e
out_happy="$(run_case happy "$TMP/out-happy")"; rc_happy=$?
out_dead="$(run_case dead-press "$TMP/out-dead")"; rc_dead=$?
out_nob="$(run_case no-button "$TMP/out-nobutton")"; rc_nob=$?
set -e

ok=0
if [ "$rc_happy" -eq 0 ]; then
  case "$out_happy" in *"PASS (draws + reads a button"*) ok=1;; esac
fi
[ -f "$TMP/out-happy/capabilities.toml" ] || ok=0
[ -f "$TMP/out-happy/frames/rest.ppm" ] || ok=0
[ -f "$TMP/out-happy/frames/pressed.ppm" ] || ok=0
check happy "$ok" "rc=$rc_happy, descriptor staged + rest/pressed frames written"

ok=0
if [ "$rc_dead" -ne 0 ]; then
  case "$out_dead" in *"not green"*) ok=1;; esac
fi
check dead-press "$ok" "rc=$rc_dead, pressed frame stayed grey -> non-zero + 'not green'"

ok=0
if [ "$rc_nob" -ne 0 ]; then
  case "$out_nob" in *"no button input"*) ok=1;; esac
fi
check no-button "$ok" "rc=$rc_nob, descriptor without a button -> non-zero + 'no button input'"

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures case(s) misbehaved"
  echo "--- happy output ---"; echo "$out_happy"
  echo "--- dead-press output ---"; echo "$out_dead"
  echo "--- no-button output ---"; echo "$out_nob"
  exit 1
fi
echo "PASS: run-under-sim.py proven against a fake private Device (1 positive + 2 negative controls)"
