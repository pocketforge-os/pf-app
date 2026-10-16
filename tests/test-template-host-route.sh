#!/usr/bin/env bash
# test-template-host-route.sh — static host-route guard for the scaffolded app template.
#
# Incident tsp-ihne1.56 (bead tsp-ihne1.56.5): the scaffolded app-smoke `sim` job used to
# require the runner host's /dev/uinput (`sg input`, a `[ -e /dev/uinput ]` skip guard) and
# slice.conf allowed the device node. uinput is host-global: anything holding it reaches
# every seat on the machine, so those routes are deleted, not guarded. The sim job now runs
# on the headless pf-builder-vm lane and the wrapper executes INSIDE the pocketforge-sim
# container, where the control surface feeds input through per-run private FIFOs
# (sim control/control_surface.py, FifoSynth).
#
# This test renders a real app (`pf-app new`), then inspects the template AND the rendered
# output:
#   * every `docker run` logical line (backslash continuations joined, shlex-tokenized —
#     a raw line regex would miss split-argument spellings) must carry no /dev/uinput
#     device, no /dev/input bind, no char-major-13 cgroup rule and no host display
#     variable (DISPLAY/XAUTHORITY/WAYLAND_DISPLAY/X11 or wayland socket binds);
#   * every systemd DeviceAllow line (continuations joined, whitespace around `=`
#     normalized) must not allow /dev/uinput or /dev/input* — the planted
#     whitespace/continuation spellings are seeded reds below;
#   * text rules catch runner-side `modprobe uinput`, `sg input`, chmod/chgrp/setfacl on
#     the input nodes, modules-load.d persistence and host input tools;
#   * structural asserts: the sim job runs on [self-hosted, pf-builder-vm] (the `lab`
#     label matches NO runner), the skip guard is gone (wave 1 forbids interim skips), no
#     host QEMU_TSP/ROOTFS env projection, and the wrapper invocation keeps the nesting
#     caps + --network none while still running run-under-sim.py (positive control).
#
# Usage:
#   tests/test-template-host-route.sh              # fixtures + render + scan (one invocation)
#   tests/test-template-host-route.sh --self-test  # seeded fixtures only
#
# Env: PF_APP_HOST_ROUTE_ROOT (template-root override — point at a pre-migration checkout
# to reproduce the RED), PF_APP_HOST_ROUTE_PYTHON (interpreter override).
# Scanner is stdlib-only; PyYAML is used solely to parse the rendered workflow (loud
# ImportError if missing).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${PF_APP_HOST_ROUTE_ROOT:-$HERE}"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-app-host-route.XXXXXX")"
cleanup() {
  find "$TMP" -mindepth 1 -delete
  rmdir "$TMP"
}
trap cleanup EXIT

PY="${PF_APP_HOST_ROUTE_PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FATAL: no python3 interpreter found (host-route guard)" >&2; exit 3; }

echo "rendering a smoke app from $ROOT ..."
"$ROOT/pf-app" new "Smoke a133" --device a133 --id com.example.smokea133 --dir "$TMP/app" >/dev/null

"$PY" - "$ROOT" "$TMP/app" "${1:-}" <<'PY'
import os
import re
import shlex
import sys

root = sys.argv[1]
app = sys.argv[2]
mode = sys.argv[3] if len(sys.argv) > 3 else ""

# ---------------------------------------------------------------- rule patterns
# Applied to the shlex tokens of a joined `docker run` logical line.
TOKEN_RULES = [
    ("host_uinput_device", re.compile(r"/dev/uinput")),
    ("host_input_bind", re.compile(r"/dev/input(?![A-Za-z0-9_.-])")),
    ("host_display_projection", re.compile(r"/tmp/\.X11-unix")),
    ("host_display_projection", re.compile(r"\.Xauthority")),
    ("host_display_projection", re.compile(r"(?:^|[/,=])wayland-\d")),
    ("host_display_projection", re.compile(r"/run/user/\d+/wayland")),
    ("host_display_projection", re.compile(r"(?:^|[,\s=])(?:DISPLAY|WAYLAND_DISPLAY|XAUTHORITY)(?:=|$)")),
]
PAIR_FLAGS = {
    "--device", "--device-cgroup-rule", "-v", "--volume", "--mount",
    "-e", "--env",
}
CGROUP_MAJOR13 = re.compile(r"^c\s+13\s*:")

TEXT_RULES = [
    ("host_uinput_permission", re.compile(r"\bmodprobe\s+(?:-\S+\s+)*uinput\b")),
    ("host_uinput_permission", re.compile(r"\bsg\s+input\b")),
    ("host_uinput_permission", re.compile(r"\b(?:chmod|chgrp|chown|setfacl|install)\b[^|;&\n]*/dev/(?:uinput|input)")),
    ("host_uinput_permission", re.compile(r"modules-load\.d/uinput")),
    ("host_input_tool", re.compile(r"\b(?:xdotool|xclip|xsel|wl-copy|wl-paste|xhost)\b")),
]

DOCKER_RUN = re.compile(r"\bdocker\s+run\b")

# systemd unit files DO support backslash continuation and whitespace around `=`,
# so DeviceAllow lines are matched after continuation-joining with a tolerant head.
DEVICE_ALLOW = re.compile(r"\s*DeviceAllow\s*=\s*(.*)$")
DEVICE_ALLOW_UINPUT = re.compile(r"/dev/uinput")
DEVICE_ALLOW_INPUT = re.compile(r"/dev/input(?![A-Za-z0-9_.-])")


def logical_lines(text):
    """Yield (start_lineno_1based, joined_line) with backslash continuations joined."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        start = i + 1
        joined = lines[i]
        while joined.rstrip().endswith("\\") and i + 1 < len(lines):
            joined = joined.rstrip()[:-1] + " " + lines[i + 1].strip()
            i += 1
        yield start, joined
        i += 1


def scan_text(text):
    """argv + text scan; returns list of (rule, lineno, detail)."""
    findings = []
    for lineno, line in logical_lines(text):
        for rule, pat in TEXT_RULES:
            m = pat.search(line)
            if m:
                findings.append((rule, lineno, m.group(0)))
        if not DOCKER_RUN.search(line):
            continue
        try:
            tokens = shlex.split(line, comments=False)
        except ValueError as exc:
            findings.append(("unparseable_command", lineno, str(exc)))
            continue
        i = 0
        n = len(tokens)
        while i < n:
            tok = tokens[i]
            for rule, pat in TOKEN_RULES:
                if pat.search(tok):
                    findings.append((rule, lineno, tok))
            if tok == "--device-cgroup-rule":
                if i + 1 >= n:
                    findings.append(("unparseable_command", lineno, "truncated --device-cgroup-rule"))
                elif CGROUP_MAJOR13.match(tokens[i + 1]):
                    findings.append(("input_major_wildcard", lineno, tokens[i + 1]))
            elif tok.startswith("--device-cgroup-rule="):
                value = tok.split("=", 1)[1]
                if CGROUP_MAJOR13.match(value):
                    findings.append(("input_major_wildcard", lineno, value))
            if tok in PAIR_FLAGS and i + 1 >= n:
                findings.append(("unparseable_command", lineno, f"truncated {tok}"))
            i += 1
    return findings


def scan_device_allow(text):
    """systemd DeviceAllow scan; returns list of (rule, lineno, detail)."""
    findings = []
    for lineno, line in logical_lines(text):
        m = DEVICE_ALLOW.match(line)
        if not m:
            continue
        value = m.group(1)
        if DEVICE_ALLOW_UINPUT.search(value):
            findings.append(("host_uinput_permission", lineno, value.strip()))
        elif DEVICE_ALLOW_INPUT.search(value):
            findings.append(("host_input_bind", lineno, value.strip()))
    return findings


def docker_run_commands(text):
    cmds = []
    for _lineno, line in logical_lines(text):
        if not DOCKER_RUN.search(line):
            continue
        try:
            cmds.append(shlex.split(line, comments=False))
        except ValueError:
            cmds.append(None)
    return cmds


def structural_checks(text, label):
    """Wave-1 shape of the scaffolded app-smoke workflow. Returns problem strings."""
    problems = []
    if "pf-builder-vm" not in text:
        problems.append(f"{label}: sim job does not run on the pf-builder-vm lane")
    if re.search(r"runs-on:\s*\[self-hosted,\s*lab\]", text):
        problems.append(f"{label}: dead `[self-hosted, lab]` runs-on survived (matches no runner)")
    if re.search(r"id:\s*guard\b", text) or "Skip if lab sim prereqs" in text:
        problems.append(f"{label}: prereq skip guard survived (wave 1 forbids interim skips)")
    if re.search(r"^\s*QEMU_TSP:", text, re.M) or re.search(r"^\s*ROOTFS:", text, re.M):
        problems.append(f"{label}: host QEMU_TSP/ROOTFS env projection survived")
    if not re.search(r"docker build -t", text):
        problems.append(f"{label}: sim image build step missing")
    if "./build.sh" not in text:
        problems.append(f"{label}: build step missing")
    if "upload-artifact" not in text:
        problems.append(f"{label}: evidence upload missing")
    wrapper_runs = [t for t in docker_run_commands(text)
                    if t and any("run-under-sim.py" in tok for tok in t)]
    if not wrapper_runs:
        problems.append(f"{label}: no docker run invokes run-under-sim.py (positive control)")
    for tokens in wrapper_runs:
        if "--cap-add" not in tokens or "SYS_ADMIN" not in tokens:
            problems.append(f"{label}: wrapper run lost the nesting caps (SYS_ADMIN)")
        if "--network" not in tokens or "none" not in tokens:
            problems.append(f"{label}: wrapper run lost --network none")
    return problems


def yaml_checks(path):
    """Parse the rendered workflow and assert the migrated shape."""
    problems = []
    try:
        import yaml
    except ImportError:
        raise SystemExit(
            f"FATAL: PyYAML is required to parse {path} but is not installed for "
            f"interpreter {sys.executable} on {os.uname().nodename}")
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    jobs = doc.get("jobs") or {}
    sim = jobs.get("sim") or {}
    if sim.get("runs-on") != ["self-hosted", "pf-builder-vm"]:
        problems.append(f"rendered-yaml: sim runs-on is {sim.get('runs-on')!r}, "
                        "expected ['self-hosted', 'pf-builder-vm']")
    if sim.get("timeout-minutes") != 60:
        problems.append(f"rendered-yaml: sim timeout-minutes is {sim.get('timeout-minutes')!r}, "
                        "expected 60 (never raise a CI time budget)")
    steps = sim.get("steps") or []
    for step in steps:
        if step.get("id") == "guard":
            problems.append("rendered-yaml: skip guard step survived")
    if "build" not in jobs:
        problems.append("rendered-yaml: build job missing")
    return problems


# ---------------------------------------------------------------- self-test fixtures
SELF_TEST_FIXTURES = [
    # (name, text, expect_rule_or_None) — argv/text scanner.
    ("red_device_split_continuation",
     "run: |\n  docker run --rm --device \\\n    /dev/uinput \"$SIM_IMG\" shell -lc 'true'\n",
     "host_uinput_device"),
    ("red_device_equals_form",
     "run: docker run --rm --device=/dev/uinput img cmd\n",
     "host_uinput_device"),
    ("red_input_bind_v",
     "run: docker run --rm -v /dev/input:/dev/input img cmd\n",
     "host_input_bind"),
    ("red_input_mount_long",
     "run: docker run --rm --mount type=bind,src=/dev/input,dst=/dev/input img cmd\n",
     "host_input_bind"),
    ("red_cgroup_major13",
     'run: docker run --rm --device-cgroup-rule "c 13:* rmw" img cmd\n',
     "input_major_wildcard"),
    ("red_cgroup_major13_spacing",
     "run: docker run --rm --device-cgroup-rule 'c  13:*  rmw' img cmd\n",
     "input_major_wildcard"),
    ("red_display_env",
     'run: docker run --rm -e DISPLAY="$DISPLAY" img cmd\n',
     "host_display_projection"),
    ("red_wayland_env",
     "run: docker run --rm -e WAYLAND_DISPLAY=wayland-0 img cmd\n",
     "host_display_projection"),
    ("red_x11_socket_bind",
     "run: docker run --rm -v /tmp/.X11-unix:/tmp/.X11-unix img cmd\n",
     "host_display_projection"),
    ("red_xauthority_bind",
     "run: docker run --rm -v /home/mm/.Xauthority:/root/.Xauthority:ro img cmd\n",
     "host_display_projection"),
    ("red_wayland_socket_bind",
     "run: docker run --rm -v /run/user/1000/wayland-0:/tmp/wayland-0 img cmd\n",
     "host_display_projection"),
    ("red_modprobe",
     "run: sudo modprobe uinput || true\n",
     "host_uinput_permission"),
    ("red_sg_input",
     'run: sg input -c "./ci/run-under-sim.py --device a133"\n',
     "host_uinput_permission"),
    ("red_chmod_node",
     "run: sudo chmod 0666 /dev/uinput\n",
     "host_uinput_permission"),
    ("red_modules_load_persistence",
     "run: echo uinput | sudo tee /etc/modules-load.d/uinput.conf\n",
     "host_uinput_permission"),
    ("red_xdotool",
     "run: xdotool key --clearmodifiers space\n",
     "host_input_tool"),
    ("red_unparseable_fail_closed",
     "run: docker run --rm --device 'unbalanced img cmd\n",
     "unparseable_command"),
    ("green_migrated_wrapper_argv",
     "run: |\n"
     '  mkdir -p "evidence/a133"\n'
     "  docker run --rm --network none \\\n"
     "    --cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined \\\n"
     '    -v "$PWD/build:/app-build:ro" \\\n'
     '    -v "$PWD/ci:/app-ci:ro" \\\n'
     '    -v "$PWD/evidence:/evidence" \\\n'
     "    \"$SIM_IMG\" shell -lc 'python3 /app-ci/run-under-sim.py \\\n"
     "      --device a133 \\\n"
     "      --binary \"/app-build/smoke-a133.arm64\" \\\n"
     "      --sim /opt/sim \\\n"
     "      --platform \"$PLATFORM\" \\\n"
     "      --qemu-tsp \"$QEMU_TSP\" \\\n"
     "      --rootfs \"$ROOTFS\" \\\n"
     "      --outdir \"/evidence/a133\"'\n",
     None),
    ("green_doc_only_prose",
     "# input rides the sim's private per-run FIFOs; the host kernel node is never opened,\n"
     "# bound, or module-loaded, and no seat variable is projected (incident tsp-ihne1.56.5).\n",
     None),
    ("green_workspace_chown_reclaim",
     'run: docker run --rm -v "$PWD:/w" debian:bookworm chown -R "$(id -u):$(id -g)" /w || true\n',
     None),
]

DEVICE_ALLOW_FIXTURES = [
    # (name, text, expect_rule_or_None) — DeviceAllow scanner (planted spellings).
    ("red_da_exact", "DeviceAllow=/dev/uinput rw\n", "host_uinput_permission"),
    ("red_da_spaces_around_equals", "DeviceAllow = /dev/uinput rw\n", "host_uinput_permission"),
    ("red_da_backslash_continuation", "DeviceAllow=\\\n    /dev/uinput rw\n",
     "host_uinput_permission"),
    ("red_da_tab_input_glob", "DeviceAllow\t=\t/dev/input/event* rw\n", "host_input_bind"),
    ("green_da_migrated_block",
     "[Slice]\nDevicePolicy=strict\nDeviceAllow=/dev/fb0 rw\n"
     "DeviceAllow=/dev/dri/renderD128 rw\nDeviceAllow=/dev/snd/ rw\n",
     None),
]


def run_self_test():
    failures = []
    for name, text, expect in SELF_TEST_FIXTURES:
        found = scan_text(text)
        rules = {rule for rule, _ln, _d in found}
        if expect is None:
            if found:
                failures.append(f"{name}: expected PASS, got findings {sorted(rules)}")
            else:
                print(f"self-test {name}: PASS (green control clean)")
        else:
            if expect in rules:
                print(f"self-test {name}: PASS (caught {expect})")
            else:
                failures.append(f"{name}: expected rule {expect}, got {sorted(rules) or 'no findings'}")
    for name, text, expect in DEVICE_ALLOW_FIXTURES:
        found = scan_device_allow(text)
        rules = {rule for rule, _ln, _d in found}
        if expect is None:
            if found:
                failures.append(f"{name}: expected PASS, got findings {sorted(rules)}")
            else:
                print(f"self-test {name}: PASS (green control clean)")
        else:
            if expect in rules:
                print(f"self-test {name}: PASS (caught {expect})")
            else:
                failures.append(f"{name}: expected rule {expect}, got {sorted(rules) or 'no findings'}")
    total = len(SELF_TEST_FIXTURES) + len(DEVICE_ALLOW_FIXTURES)
    if failures:
        for f in failures:
            print(f"host_route_guard=FAIL reason=self_test path=<fixture> line=0 rule=self_test detail={f}")
        print(f"SELF-TEST FAIL ({len(failures)} fixture(s) misbehaved)")
        return 1
    reds = sum(1 for _n, _t, e in SELF_TEST_FIXTURES + [(n, t, e) for n, t, e in DEVICE_ALLOW_FIXTURES] if e)
    print(f"SELF-TEST PASS ({total} fixtures: {reds} reds caught, {total - reds} greens clean)")
    return 0


# ---------------------------------------------------------------- full scan
def run_full_scan():
    failures = 0

    def report(path, findings, problems=()):
        nonlocal failures
        for rule, lineno, detail in findings:
            failures += 1
            print(f"host_route_guard=FAIL reason={rule} path={path} line={lineno} "
                  f"rule={rule} detail={detail!r}")
        for problem in problems:
            failures += 1
            print(f"host_route_guard=FAIL reason=structural path={path} line=0 "
                  f"rule=structural detail={problem!r}")
        if not findings and not problems:
            print(f"host_route_guard=PASS path={path}")

    wf_tpl = os.path.join(root, "templates/app/.github/workflows/app-smoke.yml.in")
    wf_rend = os.path.join(app, ".github/workflows/app-smoke.yml")
    wrapper_tpl = os.path.join(root, "templates/app/ci/run-under-sim.py.in")
    wrapper_rend = os.path.join(app, "ci/run-under-sim.py")
    slice_tpl = os.path.join(root, "templates/app/oci/slice.conf")
    slice_rend = os.path.join(app, "oci/slice.conf")
    for path in (wf_tpl, wf_rend, wrapper_tpl, wrapper_rend, slice_tpl, slice_rend):
        if not os.path.isfile(path):
            failures += 1
            print(f"host_route_guard=FAIL reason=missing_file path={path} line=0 rule=meta")

    for path in (wf_tpl, wf_rend):
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            report(path, scan_text(text), structural_checks(text, os.path.basename(path)))
    for path in (wrapper_tpl, wrapper_rend):
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            report(path, scan_text(text))
    for path in (slice_tpl, slice_rend):
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            report(path, scan_device_allow(text))
    if os.path.isfile(wf_rend):
        problems = yaml_checks(wf_rend)
        for problem in problems:
            failures += 1
            print(f"host_route_guard=FAIL reason=rendered_yaml path={wf_rend} line=0 "
                  f"rule=rendered_yaml detail={problem!r}")
        if not problems:
            print(f"host_route_guard=PASS path={wf_rend} rendered-yaml "
                  "(parses; sim runs-on [self-hosted, pf-builder-vm]; timeout 60; no guard step)")

    if failures:
        print(f"FAIL: {failures} host-route finding(s)")
        return 1
    print("PASS: template + rendered app carry no host input/display route (6 targets)")
    return 0


rc_self = run_self_test()
if mode == "--self-test":
    sys.exit(rc_self)
rc_full = run_full_scan()
sys.exit(rc_self | rc_full)
PY
