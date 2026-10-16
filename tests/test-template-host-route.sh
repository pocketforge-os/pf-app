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
# Hardened deny-model core, converged with the platform guard
# (pocketforge-os/platform#354 review rounds 1-3): literal token rules, a
# sensitive-option value deny model (cgroup rules, bind sources, env), fail-closed
# dynamic_route on shell indirection and whole-argv expansions in the Docker option
# region, attached-value short options (-v/dev:/dev, -eDISPLAY) and region-aware
# option/image/application splitting.
TOKEN_RULES = [
    ("host_uinput_device", re.compile(r"/dev/uinput")),
    ("host_input_bind", re.compile(r"/dev/input(?![A-Za-z0-9_.-])")),
    ("host_display_projection", re.compile(r"/tmp/\.X11-unix")),
    ("host_display_projection", re.compile(r"\.Xauthority")),
    ("host_display_projection", re.compile(r"(?:^|[/,=])wayland-\d")),
    ("host_display_projection", re.compile(r"/run/user/\d+/wayland")),
    ("host_display_projection", re.compile(r"(?:^|[,\s=])(?:DISPLAY|WAYLAND_DISPLAY|XAUTHORITY)(?:=|$)")),
]

# Sensitive docker options: their VALUE decides whether a host device, path or seat
# variable reaches the container. A dynamic (shell-expanded) value cannot be proven
# safe statically -> dynamic_route, fail closed (design-plan §3 pattern family).
SENSITIVE_VALUE_FLAGS = {
    "--device", "--device-cgroup-rule", "--cap-add",
    "-v", "--volume", "--mount", "-e", "--env",
}
BIND_FLAGS = {"-v", "--volume", "--mount"}
# Docker short options accept ATTACHED values (`-v/dev:/dev` == `-v /dev:/dev`,
# `-eDISPLAY` == `-e DISPLAY`). They must be split before the deny model runs.
SHORT_VALUE_FLAGS = ("-v", "-e")
WORKSPACE_PREFIXES = ("$PWD/", "${PWD}/")
WORKSPACE_EXACT = ("$PWD", "${PWD}")
ARRAY_EXPANSION = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}")
DYNAMIC = re.compile(r"[$`]")

# Static bind sources that are (or contain, or sit above) host device/seat paths.
PROTECTED_BIND_SOURCES = {
    "/", "/dev", "/dev/input", "/dev/uinput", "/etc", "/home", "/root",
    "/run", "/run/user", "/tmp", "/tmp/.X11-unix",
}
RUN_USER_RE = re.compile(r"^/run/user(?:/\d+)?(?:/.*)?$")

CGROUP_RULE = re.compile(r"^([abc]) (\*|\d+):(\*|\d+)(?: [a-z]+)?$")

# Text-level rules applied to every joined logical line (docker or not).
TEXT_RULES = [
    ("host_uinput_permission", re.compile(r"\bmodprobe\s+(?:-\S+\s+)*uinput\b")),
    ("host_uinput_permission", re.compile(r"\bsg\s+input\b")),
    ("host_uinput_permission", re.compile(r"\b(?:chmod|chgrp|chown|setfacl|install)\b[^|;&\n]*/dev/(?:uinput|input)")),
    ("host_uinput_permission", re.compile(r"modules-load\.d/uinput")),
    ("host_input_tool", re.compile(r"\b(?:xdotool|xclip|xsel|wl-copy|wl-paste|xhost)\b")),
    # Fail closed on dynamic module/group arguments: `mod=uinput; modprobe "$mod"`.
    ("dynamic_route", re.compile(r"\bmodprobe\b[^|;&\n]*[$`]")),
    ("dynamic_route", re.compile(r"\bsg\s+[^|;&\n]*[$`]")),
]

# Assignments whose VALUE names a protected path/tool: the literal-scan evasion
# `node=/dev/uinput; docker run --device "$node"` plants the literal HERE.
ASSIGN_RULE = re.compile(
    r"""(?:^|[\s;|&({])(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*=["']?"""
    r"(/dev/uinput\b|/dev/input\b|/tmp/\.X11-unix\b|/run/user/\d+/(?:wayland|bus)\S*"
    r"|xdotool\b|xclip\b|xsel\b|wl-copy\b|wl-paste\b|xhost\b|uinput\b)"
)
ASSIGN_VALUE_RULE = [
    (re.compile(r"^/dev/uinput\b"), "host_uinput_device"),
    (re.compile(r"^/dev/input\b"), "host_input_bind"),
    (re.compile(r"^/tmp/\.X11-unix\b|^/run/user/"), "host_display_projection"),
    (re.compile(r"^(?:xdotool|xclip|xsel|wl-copy|wl-paste|xhost)\b"), "host_input_tool"),
    (re.compile(r"^uinput\b"), "host_uinput_permission"),
]

# Permission commands with dynamic arguments hide the target: `n=/dev/uinput; chmod "$n"`.
# The ownership-reclaim idiom ($(id -u)/$(id -g)) is the only provably-safe dynamic here.
PERM_CMD = re.compile(r"\b(?:chmod|chgrp|chown|setfacl|install)\b([^|;&\n]*)")
OWNERSHIP_IDIOMS = (
    "$(id -u):$(id -g)", "$(id -un):$(id -gn)", "$(id -u)", "$(id -g)",
    "$(id -un)", "$(id -gn)",
)

DOCKER_RUN = re.compile(r"\bdocker\s+run\b")

# Docker flags that never take a value. Any OTHER unknown `-flag` consumes the
# following non-dash word as its value (fail closed: a mis-parsed value could
# otherwise be mistaken for the image operand and end option parsing too early).
DOCKER_BOOL_FLAGS = {
    "--rm", "--privileged", "--init", "--read-only", "--detach", "-d",
    "--interactive", "-i", "--tty", "-t", "-it", "--publish-all", "-P",
    "--no-healthcheck", "--sig-proxy",
}

# Single-char boolean shorthands pflag may combine ahead of an attached value
# (`-tv/dev:/dev` == `-t -v /dev:/dev`).
SHORT_BOOL_FLAGS = frozenset(
    f for f in DOCKER_BOOL_FLAGS if len(f) == 2 and not f.startswith("--")
)

# Quoting prevents word splitting but NOT the single resulting word from being a
# complete Docker option (`FLAGS=--privileged; docker run "$FLAGS" img` runs
# privileged) or an option-shaped image. Every quoted expansion in the option
# region (including the image-slot candidate) therefore fails closed, EXCEPT a
# bare "$VAR"/"${VAR}" image operand whose name is allowlisted here AND whose
# every assignment in the same file folds to a safe static image reference.
PROVEN_IMAGE_VARS = {"SIM_IMG"}
# Runner-evaluated GitHub contexts proven to render numeric/hex text only.
SAFE_GH_EXPR = re.compile(
    r"\$\{\{\s*github\.(?:run_id|run_number|run_attempt|sha)\s*\}\}")
# pf-app scaffold tokens ({{APP_SLUG}} etc.) render to slug-safe literals.
SCAFFOLD_TOKEN_RE = re.compile(r"\{\{[A-Z0-9_]+\}\}")
IMAGE_REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:+-]*$")
SHELL_ASSIGN_RE = re.compile(
    r"""(?:^|[\s;|&({])(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)="""
    r"""(\"[^\"]*\"|'[^']*'|[^\s;|&]*)""")
PROVEN_VAR_TOKEN = re.compile(r"^\$(?:\{)?([A-Za-z_][A-Za-z0-9_]*)(?:\})?$")


def unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def safe_image_value(value):
    """True when an assigned value can only render as a static image reference:
    known-safe runner contexts and scaffold tokens fold to placeholders and the
    result is a plain reference (no whitespace, no leading dash, no residual
    expansion)."""
    folded = SCAFFOLD_TOKEN_RE.sub("0", SAFE_GH_EXPR.sub("0", value))
    return bool(IMAGE_REF_RE.match(folded))


def proven_image_vars(text):
    """Allowlisted image variables whose every assignment in this text folds to
    a safe static image reference. No assignment, or any unsafe assignment (or
    unsafe `${{ }}` context), leaves the variable UNPROVEN (fail closed)."""
    assignments = {}
    for _lineno, line in logical_lines(text):
        for m in SHELL_ASSIGN_RE.finditer(line):
            if m.group(1) in PROVEN_IMAGE_VARS:
                assignments.setdefault(m.group(1), []).append(unquote(m.group(2)))
        for name in PROVEN_IMAGE_VARS:
            m = re.match(r"^\s*-?\s*" + name + r":\s*(.+?)\s*$", line)
            if m:
                assignments.setdefault(name, []).append(unquote(m.group(1)))
    return {name for name, values in assignments.items()
            if values and all(safe_image_value(v) for v in values)}


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


def raw_word_flags(line):
    """One state per whitespace-separated shell word: "unquoted" when the word
    carries a `$` or backtick OUTSIDE any quotes (word-splits at runtime, so a
    single token like $FLAGS or $(route_args) can inject WHOLE docker options);
    "quoted" when it carries expansions only inside double quotes (stays one
    word, but that word can still evaluate to a complete option or an
    option-shaped image); else "static" (single-quoted or plain text). Aligned
    1:1 with the shlex.split() tokens of the same line (callers must verify the
    lengths)."""
    flags = []
    have_word = False
    unquoted_dyn = False
    quoted_dyn = False

    def state():
        return "unquoted" if unquoted_dyn else "quoted" if quoted_dyn else "static"

    in_single = in_double = esc = False
    for ch in line:
        if esc:
            esc = False
            continue
        if in_single:
            if ch == "'":
                in_single = False
            continue
        if in_double:
            if ch == "\\":
                esc = True
            elif ch == '"':
                in_double = False
            elif ch in "$`":
                quoted_dyn = True
            continue
        if ch == "\\":
            esc = True
            continue
        if ch == "'":
            have_word = True
            in_single = True
            continue
        if ch == '"':
            have_word = True
            in_double = True
            continue
        if ch.isspace():
            if have_word:
                flags.append(state())
            have_word = False
            unquoted_dyn = quoted_dyn = False
            continue
        have_word = True
        if ch in "$`":
            unquoted_dyn = True
    if have_word:
        flags.append(state())
    return flags


def attached_short_pair(tok):
    """Split docker's attached-value short-option spelling into (flag, value);
    None when tok is not one. `-v/dev:/dev` -> ("-v", "/dev:/dev"); pflag also
    accepts `-v=/dev:/dev` and combined shorthands (`-tv/dev:/dev`)."""
    if not tok.startswith("-") or tok.startswith("--"):
        return None
    body = tok[1:]
    while body:
        flag = "-" + body[0]
        if flag in SHORT_VALUE_FLAGS:
            if len(body) < 2:
                return None
            value = body[1:]
            if value.startswith("="):
                value = value[1:]
            return flag, value
        if flag in SHORT_BOOL_FLAGS:
            body = body[1:]
            continue
        return None
    return None


def docker_regions(tokens):
    """Split one `docker run` token list into (option_tokens, image_idx, app_tokens).
    The image is the first positional operand after `docker run`; everything after it
    is the container command + arguments (inert as far as Docker option parsing goes).
    image_idx is None when no positional operand exists."""
    try:
        start = tokens.index("run", tokens.index("docker"))
    except ValueError:
        return tokens, None, []
    i = start + 1
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if tok.startswith("-"):
            if tok in DOCKER_BOOL_FLAGS or "=" in tok or attached_short_pair(tok):
                i += 1  # self-contained (boolean, inline `=`, or attached value)
            elif i + 1 < n and not tokens[i + 1].startswith("-"):
                i += 2  # flag value (sensitive or unknown)
            else:
                i += 1
            continue
        return tokens[:i], i, tokens[i + 1:]
    return tokens, None, []


def bind_source_denied(src):
    """True when a STATIC bind source exposes protected host device/seat paths."""
    if src in PROTECTED_BIND_SOURCES:
        return True
    if RUN_USER_RE.match(src):
        return True
    norm = src.rstrip("/")
    if not norm:  # src == "/" (or "//")
        return True
    return any(p.startswith(norm + "/") for p in PROTECTED_BIND_SOURCES)


def workspace_bind_ok(src):
    return src in WORKSPACE_EXACT or src.startswith(WORKSPACE_PREFIXES)


def cgroup_rule_denied(value):
    """True when a --device-cgroup-rule value can reach an input/uinput node,
    including wildcard grants. Unparseable rules fail closed (denied)."""
    norm = " ".join(value.split())
    m = CGROUP_RULE.match(norm)
    if not m:
        return True
    _typ, major, minor = m.groups()
    if major in ("*", "13"):
        return True
    if major == "10" and minor in ("*", "223"):
        return True
    return False


def mount_src_of(value):
    """Extract the src= field of a --mount value (empty string when absent)."""
    for field in value.split(","):
        if field.startswith("src=") or field.startswith("source="):
            return field.split("=", 1)[1]
    return ""


def check_sensitive_value(flag, value, lineno, findings):
    """Deny model for one docker option value (both `--flag value` and `--flag=value`)."""
    if flag == "--device-cgroup-rule":
        if DYNAMIC.search(value):
            findings.append(("dynamic_route", lineno, f"{flag} {value!r}"))
        elif cgroup_rule_denied(value):
            findings.append(("input_major_wildcard", lineno, value))
        return
    if flag == "--device":
        if DYNAMIC.search(value):
            findings.append(("dynamic_route", lineno, f"{flag} {value!r}"))
        return
    if flag == "--cap-add":
        if DYNAMIC.search(value):
            findings.append(("dynamic_route", lineno, f"{flag} {value!r}"))
        return
    if flag in BIND_FLAGS:
        src = mount_src_of(value) if flag == "--mount" else value.split(":", 1)[0]
        if DYNAMIC.search(value):
            if not workspace_bind_ok(src):
                findings.append(("dynamic_route", lineno, f"{flag} {value!r}"))
            return
        if bind_source_denied(src):
            findings.append(("host_path_bind", lineno, value))
        return
    if flag in ("-e", "--env"):
        if DYNAMIC.search(value):
            findings.append(("dynamic_route", lineno, f"{flag} {value!r}"))
        # A static bare `-e NAME` passes the host env var through; a display
        # variable NAME is already caught by TOKEN_RULES on the literal token.
        return


def token_findings(tok, lineno):
    """Literal-token denials for one argv token (used for plain tokens AND for
    option values consumed positionally, so `--device /dev/uinput` is never skipped)."""
    out = []
    for rule, pat in TOKEN_RULES:
        if pat.search(tok):
            out.append((rule, lineno, tok))
    if ARRAY_EXPANSION.search(tok):
        out.append(("dynamic_route", lineno,
                    f"unprovable array expansion in docker argv: {tok}"))
    return out


def scan_text(text):
    """Return findings: list of (rule, lineno, detail)."""
    findings = []
    proven_vars = proven_image_vars(text)
    for lineno, line in logical_lines(text):
        for rule, pat in TEXT_RULES:
            m = pat.search(line)
            if m:
                findings.append((rule, lineno, m.group(0)))
        m = ASSIGN_RULE.search(line)
        if m:
            value = m.group(1)
            for pat, rule in ASSIGN_VALUE_RULE:
                if pat.match(value):
                    findings.append((rule, lineno, m.group(0).strip()))
                    break
        for pm in PERM_CMD.finditer(line):
            rest = pm.group(1)
            for idiom in OWNERSHIP_IDIOMS:
                rest = rest.replace(idiom, "")
            if DYNAMIC.search(rest):
                findings.append(("dynamic_route", lineno,
                                 "permission command with dynamic argument: "
                                 + pm.group(0).strip()[:60]))
        if not DOCKER_RUN.search(line):
            continue
        try:
            tokens = shlex.split(line, comments=False)
        except ValueError as exc:
            findings.append(("unparseable_command", lineno, str(exc)))
            continue
        raws = raw_word_flags(line)
        if len(raws) != len(tokens):
            # The quote-aware word walk and shlex disagree -> the argv cannot be
            # proven safe statically. Fail closed.
            findings.append(("unparseable_command", lineno,
                             "word/token misalignment in docker run line"))
            continue
        # The Docker option region starts AFTER the `docker run` tokens; a shell
        # prefix on the same logical line (`for suite ...; do`, `if`, `caps() {`)
        # is not part of the argv and must not be mistaken for the image operand.
        try:
            run_idx = tokens.index("run", tokens.index("docker"))
        except ValueError:
            run_idx = None
        i = 0
        n = len(tokens)
        image_seen = False
        while i < n:
            tok = tokens[i]
            findings.extend(token_findings(tok, lineno))
            if run_idx is None or i <= run_idx:
                i += 1
                continue
            if tok == "--privileged":
                findings.append(("host_device_wildcard", lineno, tok))
            if tok == "--env-file" or tok.startswith("--env-file="):
                findings.append(("host_env_file", lineno, tok))
            apair = attached_short_pair(tok)
            if apair is not None:
                # Attached short-option spelling (`-v/dev:/dev`, `-eDISPLAY`):
                # split, then run the SAME deny model as the spaced spelling.
                flag, value = apair
                findings.extend(token_findings(value, lineno))
                check_sensitive_value(flag, value, lineno, findings)
                if not image_seen and raws[i] == "unquoted":
                    findings.append(("dynamic_route", lineno,
                                     "unquoted expansion attached to "
                                     f"{flag} can word-split into extra docker "
                                     f"options: {tok}"))
                i += 1
                continue
            consumed = False
            for flag in SENSITIVE_VALUE_FLAGS:
                if tok == flag:
                    if i + 1 >= n:
                        findings.append(("unparseable_command", lineno, f"truncated {tok}"))
                    else:
                        value = tokens[i + 1]
                        # A consumed option value must still face the literal-token
                        # denials, else `--device /dev/uinput` hides in the value slot.
                        findings.extend(token_findings(value, lineno))
                        check_sensitive_value(flag, value, lineno, findings)
                        if not image_seen and raws[i + 1] == "unquoted":
                            findings.append(("dynamic_route", lineno,
                                             "unquoted expansion as the value of "
                                             f"{tok} can word-split into extra "
                                             f"docker options: {value}"))
                        i += 1
                        consumed = True
                    break
                if tok.startswith(flag + "="):
                    check_sensitive_value(flag, tok.split("=", 1)[1], lineno, findings)
                    consumed = True  # inline form carries its own value
                    break
            if consumed:
                i += 1
                continue
            if not image_seen:
                # Everything before the first positional operand is the Docker
                # OPTION region. An unquoted expansion here ($FLAGS, ${FLAGS},
                # $(cmd), `cmd`) word-splits at runtime and can inject ANY option
                # (--privileged, --device, binds, env) past this static scan.
                if raws[i] == "unquoted":
                    findings.append(("dynamic_route", lineno,
                                     "unquoted shell expansion in the docker option "
                                     "region can inject arbitrary options at runtime: "
                                     f"{tok}"))
                elif tok.startswith("-"):
                    if raws[i] == "quoted":
                        findings.append(("dynamic_route", lineno,
                                         "quoted expansion as a docker flag name can "
                                         "evaluate to an arbitrary option at runtime: "
                                         f"{tok}"))
                    elif ("=" not in tok and tok not in DOCKER_BOOL_FLAGS
                          and i + 1 < n and not tokens[i + 1].startswith("-")):
                        # Unknown non-boolean flag: its value is the next non-dash
                        # word. The flag is not in the audited sensitive set, so an
                        # unresolved value cannot be proven safe -> fail closed.
                        findings.extend(token_findings(tokens[i + 1], lineno))
                        if raws[i + 1] != "static":
                            findings.append(("dynamic_route", lineno,
                                             "unresolved expansion as the value of "
                                             f"unknown docker flag {tok} cannot be "
                                             f"proven safe: {tokens[i + 1]}"))
                        i += 1
                elif raws[i] == "quoted":
                    # Quoting prevents word splitting but NOT the single word from
                    # evaluating to a complete option (--privileged) or an
                    # option-shaped image. Only the explicit proven-image-variable
                    # allowlist passes; everything else fails closed.
                    m = PROVEN_VAR_TOKEN.match(tok)
                    if m and m.group(1) in proven_vars:
                        image_seen = True  # allowlisted, statically assigned image
                    else:
                        findings.append(("dynamic_route", lineno,
                                         "quoted shell expansion in the docker option "
                                         "region can evaluate to a complete docker "
                                         "option at runtime (not a proven image "
                                         f"variable): {tok}"))
                else:
                    image_seen = True  # first static positional operand = the image
            i += 1
    return findings


def docker_run_commands(text):
    """Return the shlex token lists of every joined `docker run` logical line."""
    cmds = []
    for _lineno, line in logical_lines(text):
        if not DOCKER_RUN.search(line):
            continue
        try:
            cmds.append(shlex.split(line, comments=False))
        except ValueError:
            cmds.append(None)  # unparseable: scan_text already reported it
    return cmds


def pair_ok(tokens, flag, value):
    """True when `value` is the option value of `flag` (adjacent or --flag=value),
    not merely present somewhere in the argv."""
    for i, tok in enumerate(tokens):
        if tok == flag and i + 1 < len(tokens) and tokens[i + 1] == value:
            return True
        if tok == f"{flag}={value}":
            return True
    return False


CHECK_SUITE_TOKEN = re.compile(r"check-(?:\$suite|\$?\{?suite\}?|control|sensor|skin)")


# ---------------------------------------------------------------- DeviceAllow
# systemd unit files DO support backslash continuation and whitespace around `=`,
# so DeviceAllow lines are matched after continuation-joining with a tolerant head.
DEVICE_ALLOW = re.compile(r"\s*DeviceAllow\s*=\s*(.*)$")
DEVICE_ALLOW_UINPUT = re.compile(r"/dev/uinput")
DEVICE_ALLOW_INPUT = re.compile(r"/dev/input(?![A-Za-z0-9_.-])")


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
    wrapper_runs = []
    for tokens in docker_run_commands(text):
        if tokens is None:
            continue
        opts, image_idx, application = docker_regions(tokens)
        if image_idx is not None and any("run-under-sim.py" in tok for tok in application):
            wrapper_runs.append((opts, application))
    if not wrapper_runs:
        problems.append(f"{label}: no docker run invokes run-under-sim.py in the "
                        "container-argument region (positive control)")
    for opts, _application in wrapper_runs:
        # Docker-side requirements must be OPTION/VALUE PAIRS before the image;
        # the same strings after the image are inert application arguments.
        if not pair_ok(opts, "--cap-add", "SYS_ADMIN"):
            problems.append(f"{label}: wrapper run lost the paired --cap-add SYS_ADMIN "
                            "nesting cap as a Docker option before the image")
        if not pair_ok(opts, "--network", "none"):
            problems.append(f"{label}: wrapper run lost the paired --network none "
                            "isolation as a Docker option before the image")
        if "--rm" not in opts:
            problems.append(f"{label}: wrapper run lost --rm from the Docker option region")
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
    # (name, text, expect_rules) - argv/text scanner. expect_rules is the SET of
    # rules that must fire (empty set = must scan clean). Hardened fixtures are
    # converged verbatim with the platform guard (pocketforge-os/platform#354).
    ("red_device_split_continuation",
     "run: |\n  docker run --rm --device \\\n    /dev/uinput \"$IMG\" check-control a133\n",
     {"host_uinput_device"}),
    ("red_device_equals_form",
     "run: docker run --rm --device=/dev/uinput img cmd\n",
     {"host_uinput_device"}),
    ("red_input_bind_v",
     "run: docker run --rm -v /dev/input:/dev/input img cmd\n",
     {"host_input_bind"}),
    ("red_input_mount_long",
     "run: docker run --rm --mount type=bind,src=/dev/input,dst=/dev/input img cmd\n",
     {"host_input_bind"}),
    ("red_cgroup_major13",
     'run: docker run --rm --device-cgroup-rule "c 13:* rmw" img cmd\n',
     {"input_major_wildcard"}),
    ("red_cgroup_major13_spacing",
     "run: docker run --rm --device-cgroup-rule 'c  13:*  rmw' img cmd\n",
     {"input_major_wildcard"}),
    ("red_cgroup_misc_uinput_10_223",
     'run: docker run --rm --device-cgroup-rule "c 10:223 rmw" img cmd\n',
     {"input_major_wildcard"}),
    ("red_cgroup_wildcard_major",
     'run: docker run --rm --device-cgroup-rule "c *:* rmw" img cmd\n',
     {"input_major_wildcard"}),
    ("red_cgroup_wildcard_all",
     'run: docker run --rm --device-cgroup-rule "a *:* rmw" img cmd\n',
     {"input_major_wildcard"}),
    ("red_privileged",
     "run: docker run --rm --privileged img cmd\n",
     {"host_device_wildcard"}),
    ("red_parent_bind_dev",
     "run: docker run --rm -v /dev:/dev img cmd\n",
     {"host_path_bind"}),
    ("red_parent_bind_tmp",
     "run: docker run --rm -v /tmp:/tmp img cmd\n",
     {"host_path_bind"}),
    ("red_parent_bind_run_user",
     "run: docker run --rm -v /run/user/1000:/run/user/1000 img cmd\n",
     {"host_path_bind"}),
    ("red_env_file",
     "run: docker run --rm --env-file /etc/host.env img cmd\n",
     {"host_env_file"}),
    ("red_display_env",
     'run: docker run --rm -e DISPLAY="$DISPLAY" img cmd\n',
     {"host_display_projection"}),
    ("red_wayland_env",
     "run: docker run --rm -e WAYLAND_DISPLAY=wayland-0 img cmd\n",
     {"host_display_projection"}),
    ("red_x11_socket_bind",
     "run: docker run --rm -v /tmp/.X11-unix:/tmp/.X11-unix img cmd\n",
     {"host_display_projection"}),
    ("red_xauthority_bind",
     "run: docker run --rm -v /home/mm/.Xauthority:/root/.Xauthority:ro img cmd\n",
     {"host_display_projection"}),
    ("red_wayland_socket_bind",
     "run: docker run --rm -v /run/user/1000/wayland-0:/tmp/wayland-0 img cmd\n",
     {"host_display_projection"}),
    ("red_modprobe",
     "run: sudo modprobe uinput || true\n",
     {"host_uinput_permission"}),
    ("red_sg_input",
     'run: sg input -c "./ci/run-under-sim.py --device a133"\n',
     {"host_uinput_permission"}),
    ("red_chmod_node",
     "run: sudo chmod 0666 /dev/uinput\n",
     {"host_uinput_permission"}),
    ("red_modules_load_persistence",
     "run: echo uinput | sudo tee /etc/modules-load.d/uinput.conf\n",
     {"host_uinput_permission"}),
    ("red_xdotool",
     "run: xdotool key --clearmodifiers space\n",
     {"host_input_tool"}),
    ("red_unparseable_fail_closed",
     "run: docker run --rm --device 'unbalanced img cmd\n",
     {"unparseable_command"}),
    # ---- shell-expansion / indirection reds: every protected class via a variable
    ("red_dynamic_device_via_var",
     'run: |\n  node=/dev/uinput\n  docker run --rm --device "$node" "$IMG" cmd\n',
     {"host_uinput_device", "dynamic_route"}),
    ("red_dynamic_input_bind_via_var",
     'run: |\n  dst=/dev/input\n  docker run --rm -v "$dst:/x" "$IMG" cmd\n',
     {"host_input_bind", "dynamic_route"}),
    ("red_dynamic_cgroup_rule_via_var",
     'run: |\n  rule="c 13:* rmw"\n  docker run --rm --device-cgroup-rule "$rule" "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_dynamic_display_env_via_var",
     'run: |\n  d=DISPLAY\n  docker run --rm -e "$d=:0" "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_dynamic_x11_socket_via_var",
     'run: |\n  XSOCK=/tmp/.X11-unix\n  docker run --rm -v "$XSOCK:/tmp/.X11-unix" "$IMG" cmd\n',
     {"host_display_projection", "dynamic_route"}),
    ("red_dynamic_modprobe_via_var",
     'run: modprobe "$mod" || true\n',
     {"dynamic_route"}),
    ("red_dynamic_chmod_via_var",
     'run: |\n  n=/dev/uinput\n  chmod 0666 "$n"\n',
     {"host_uinput_device", "dynamic_route"}),
    ("red_dynamic_tool_via_assign",
     'run: |\n  t=xdotool\n  "$t" key space\n',
     {"host_input_tool"}),
    ("red_array_indirection",
     'run: |\n  CAPS=(--device /dev/uinput)\n  docker run --rm "${CAPS[@]}" "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_dynamic_bind_non_workspace",
     'run: |\n  SRC=/opt/pf\n  docker run --rm -v "$SRC/data:/data" "$IMG" cmd\n',
     {"dynamic_route"}),
    # ---- whole-argv expansion reds: an UNQUOTED expansion in the Docker option
    # region word-splits at runtime and can inject any option past the static scan.
    ("red_scalar_expansion_option_region",
     'run: |\n  FLAGS=\'--privileged --device /dev/uinput\'\n'
     '  docker run --rm $FLAGS "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_braced_scalar_expansion_option_region",
     'run: docker run --rm ${FLAGS} "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_cmdsub_option_region",
     'run: docker run --rm $(route_args) "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_backtick_option_region",
     'run: docker run --rm `route_args` "$IMG" cmd\n',
     {"dynamic_route"}),
    ("red_unquoted_dynamic_image_slot",
     "run: docker run --rm $IMG_VAR cmd\n",
     {"dynamic_route"}),
     ("red_unquoted_expansion_as_unknown_flag_value",
      'run: docker run --rm --security-opt $OPT "$IMG" cmd\n',
      {"dynamic_route"}),
     # ---- attached-value short-option reds: docker accepts `-vVALUE` / `-eVALUE`
     # as equivalent to the spaced spelling; they must face the same deny model.
     ("red_attached_short_bind_parent_dev",
      "run: docker run --rm -v/dev:/dev alpine true\n",
      {"host_path_bind"}),
     ("red_attached_short_bind_run_user",
      "run: docker run --rm -v/run/user/1000:/run/user/1000 alpine true\n",
      {"host_path_bind"}),
     ("red_attached_short_bind_combined_bools",
      "run: docker run -it -tv/tmp:/tmp alpine true\n",
      {"host_path_bind"}),
     ("red_attached_short_env_display_passthrough",
      "run: docker run --rm -eDISPLAY alpine true\n",
      {"host_display_projection"}),
     ("red_attached_short_env_display_assign",
      "run: docker run --rm -eWAYLAND_DISPLAY=wayland-0 alpine true\n",
      {"host_display_projection"}),
    # ---- quoted expansions in the option region: quoting prevents word
    # splitting but NOT the single word from evaluating to a complete option
    # (--privileged, --device=/dev/uinput) or an option-shaped image.
    ("red_quoted_scalar_option_region",
     'run: |\n  FLAGS=--privileged\n  docker run --rm "$FLAGS" pocketforge-sim:x check-control\n',
     {"dynamic_route"}),
    ("red_quoted_braced_option_region",
     'run: docker run --rm "${FLAGS}" pocketforge-sim:x cmd\n',
     {"dynamic_route"}),
    ("red_quoted_cmdsub_option_region",
     'run: docker run --rm "$(route_args)" pocketforge-sim:x cmd\n',
     {"dynamic_route"}),
    ("red_quoted_backtick_option_region",
     'run: docker run --rm "`route_args`" pocketforge-sim:x cmd\n',
     {"dynamic_route"}),
    ("red_quoted_image_slot_unproven_var",
     'run: docker run --rm --network none "$SOME_IMG" check-control a133\n',
     {"dynamic_route"}),
    ("red_quoted_image_var_unsafe_value",
     'run: |\n  SIM_IMG=--device=/dev/uinput\n  docker run --rm "$SIM_IMG" cmd\n',
     {"dynamic_route"}),
    ("red_quoted_flag_name_option_region",
     'run: docker run --rm "--$OPT" pocketforge-sim:x cmd\n',
     {"dynamic_route"}),
    ("red_image_var_unsafe_gh_context",
     'env:\n  SIM_IMG: pocketforge-${{ github.event.pull_request.title }}\n'
     'run: docker run --rm "$SIM_IMG" cmd\n',
     {"dynamic_route"}),
    # ---- greens
    ("green_proven_image_variable",
     'env:\n  SIM_IMG: pocketforge-sim:{{APP_SLUG}}-smoke-${{ github.run_id }}\n'
     'run: docker run --rm --network none "$SIM_IMG" shell -lc "python3 /app-ci/run-under-sim.py"\n',
     set()),
    ("green_migrated_argv",
     "run: |\n"
     "  SIM_IMG=pocketforge-sim:smoke-a133-smoke-0\n"
     "  docker run --rm --network none \\\n"
     "    --cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined \\\n"
     '    "$SIM_IMG" "check-control" $BLOCKING\n',
     set()),
    ("green_doc_only_prose",
     "# input rides the sim's private per-run FIFOs; the host kernel node is never opened,\n"
     "# bound, or module-loaded, and no seat variable is projected (incident tsp-ihne1.56.5).\n",
     set()),
    ("green_workspace_chown_reclaim",
     'run: docker run --rm -v "$PWD:/w" debian:bookworm chown -R "$(id -u):$(id -g)" /w || true\n',
     set()),
     ("green_workspace_child_binds",
      'run: |\n  SIM_IMG=pocketforge-sim:smoke-a133-smoke-0\n'
      '  docker run --rm --network none -v "$PWD/build:/app-build:ro" '
      '-v "$PWD/evidence:/evidence" "$SIM_IMG" shell -lc \'python3 /app-ci/run.py --platform "$PLATFORM"\'\n',
      set()),
     ("green_attached_workspace_bind",
      'run: |\n  SIM_IMG: pocketforge-sim:smoke-a133-smoke-1\n'
      '  docker run --rm "-v$PWD/build:/app-build:ro" "$SIM_IMG" shell -lc "python3 /app-ci/run.py"\n',
      set()),
    ("green_static_benign_bind",
     "run: docker run --rm -v /opt/pf/platform:/platform:ro img cmd\n",
     set()),
    ("green_cgroup_benign_rule",
     'run: docker run --rm --device-cgroup-rule "c 1:3 rw" img cmd\n',
     set()),
    # ---- pf-app-specific green: the exact migrated wrapper invocation.
    ("green_migrated_wrapper_argv",
     "run: |\n"
     "  SIM_IMG=pocketforge-sim:smoke-a133-smoke-0\n"
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
     set()),
]

# Structural positive-control fixtures for the wrapper invocation:
# (name, text, expect_problems). Degraded spellings relocate a Docker-side
# requirement after the image (inert application argument) or delete it.
WRAPPER_CONTROL_GREEN = (
    "jobs:\n"
    "  sim:\n"
    "    runs-on: [self-hosted, pf-builder-vm]\n"
    "    steps:\n"
    "      - run: ./build.sh\n"
    '      - run: docker build -t "$SIM_IMG" .cache/sim\n'
    "      - run: |\n"
    "          docker run --rm --network none \\\n"
    "            --cap-add SYS_ADMIN --security-opt apparmor=unconfined --security-opt seccomp=unconfined \\\n"
    '            -v "$PWD/build:/app-build:ro" -v "$PWD/ci:/app-ci:ro" -v "$PWD/evidence:/evidence" \\\n'
    "            \"$SIM_IMG\" shell -lc 'python3 /app-ci/run-under-sim.py --device a133 \\\n"
    '              --binary /app-build/smoke-a133.arm64 --sim /opt/sim --platform "$PLATFORM" \\\n'
    "              --qemu-tsp \"$QEMU_TSP\" --rootfs \"$ROOTFS\" --outdir /evidence/a133'\n"
    "      - uses: actions/upload-artifact@v4\n"
)
WRAPPER_CONTROL_FIXTURES = [
    ("ctrl_green_wrapper", WRAPPER_CONTROL_GREEN, False),
    ("ctrl_red_wrapper_cap_spoofed_after_image",
     WRAPPER_CONTROL_GREEN.replace("--cap-add SYS_ADMIN ", "")
     .replace("run-under-sim.py", "run-under-sim.py --cap-add SYS_ADMIN"), True),
    ("ctrl_red_wrapper_network_spoofed_after_image",
     WRAPPER_CONTROL_GREEN.replace("--network none ", "")
     .replace("run-under-sim.py", "run-under-sim.py --network none"), True),
    ("ctrl_red_wrapper_rm_missing",
     WRAPPER_CONTROL_GREEN.replace("docker run --rm", "docker run"), True),
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
        if not expect:
            if found:
                failures.append(f"{name}: expected PASS, got findings {sorted(rules)}")
            else:
                print(f"self-test {name}: PASS (green control clean)")
        else:
            missing = expect - rules
            if missing:
                failures.append(f"{name}: expected rules {sorted(expect)}, "
                                f"got {sorted(rules) or 'no findings'}")
            else:
                print(f"self-test {name}: PASS (caught {sorted(expect & rules)})")
    for name, text, expect_problems in WRAPPER_CONTROL_FIXTURES:
        problems = structural_checks(text, name)
        if bool(problems) != expect_problems:
            failures.append(f"{name}: expected problems={expect_problems}, "
                            f"got {problems or 'none'}")
        elif expect_problems:
            print(f"self-test {name}: PASS (controls rejected: {problems[0][:70]}...)")
        else:
            print(f"self-test {name}: PASS (positive controls clean)")
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
    total = (len(SELF_TEST_FIXTURES) + len(DEVICE_ALLOW_FIXTURES)
             + len(WRAPPER_CONTROL_FIXTURES))
    if failures:
        for f in failures:
            print(f"host_route_guard=FAIL reason=self_test path=<fixture> line=0 rule=self_test detail={f}")
        print(f"SELF-TEST FAIL ({len(failures)} fixture(s) misbehaved)")
        return 1
    reds = (sum(1 for _n, _t, e in SELF_TEST_FIXTURES if e)
            + sum(1 for _n, _t, e in DEVICE_ALLOW_FIXTURES if e)
            + sum(1 for _n, _t, e in WRAPPER_CONTROL_FIXTURES if e))
    greens = (sum(1 for _n, _t, e in SELF_TEST_FIXTURES if not e)
              + sum(1 for _n, _t, e in DEVICE_ALLOW_FIXTURES if not e)
              + sum(1 for _n, _t, e in WRAPPER_CONTROL_FIXTURES if not e))
    print(f"SELF-TEST PASS ({total} fixtures: {reds} reds caught, {greens} greens/controls clean)")
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
