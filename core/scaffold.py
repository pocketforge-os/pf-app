#!/usr/bin/env python3
"""core/scaffold.py — the `pf-app new` generator (E8 / tsp-ziac.2).

Renders `templates/app/` into a new app project, substituting a small, explicit token
set. Templates whose name ends in `.in` have the suffix stripped on output; every other
file is copied verbatim (bit-for-bit). Executable bits are preserved.

Design invariants (the ethos: the platform holds authority; one descriptor, three
consumers; honest off-hardware proof):
  * The emitted `app.toml` is THE canonical app descriptor (schema: platform
    `abi/app.schema.json`) and validates through platform `pf app-validate`.
  * The emitted skeleton links SDL3 via SDL3_DYNAMIC_API (public headers + a launch-time
    env swap to `libSDL3-pocketforge.so.0`), talks to hardware only through the
    `libpocketforge` facade, and never reintroduces the tsp-osr renderer footgun.
  * No network, no device: the generator is pure stdlib file I/O.

Usage:
  scaffold.py new <name> --device <a133|a523> [--id <app-id>] [--dir <path>] [--force]
"""
from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
TEMPLATE_ROOT = ROOT / "templates" / "app"

# device id -> canonical per-SoC-family Platform ABI id (platform abi/families.toml).
FAMILY_BY_DEVICE = {
    "a133": "pocketforge/a133-powervr",
    "a523": "pocketforge/a523-mali",
}

# Frozen contract + platform pin the emitted app.toml declares. `abi` is the E2 frozen
# libpocketforge/PFW1 contract version (runtime STABILITY.md); `platform-version` is the
# per-family SHA-set freeze (platform abi/platform-abi.json). Both are "1" today.
ABI = "1"
PLATFORM_VERSION = "1"

TOKEN_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")


def slugify(name: str) -> str:
    """A filesystem/id-safe slug: lowercase, non-alnum -> '-', collapsed, trimmed."""
    s = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return s or "app"


def default_app_id(slug: str) -> str:
    """A reverse-DNS-ish default id under the reserved-for-examples com.example.* space.
    Matches the app.schema.json [app].id pattern ^[a-z0-9][a-z0-9._-]*$."""
    return f"com.example.{slug.replace('-', '')}"


def render_text(text: str, tokens: dict[str, str], rel: str) -> str:
    def repl(m: re.Match) -> str:
        key = m.group(1)
        if key not in tokens:
            raise SystemExit(f"[pf-app] template {rel}: unknown token {{{{{key}}}}}")
        return tokens[key]
    return TOKEN_RE.sub(repl, text)


def is_probably_text(path: Path) -> bool:
    """Only `.in` files are token-substituted; everything else is copied byte-for-byte."""
    return path.name.endswith(".in")


def scaffold(name: str, device: str, app_id: str | None, out_dir: Path | None,
             force: bool) -> Path:
    if device not in FAMILY_BY_DEVICE:
        raise SystemExit(f"[pf-app] --device must be one of {', '.join(FAMILY_BY_DEVICE)} "
                         f"(got {device!r})")
    if not TEMPLATE_ROOT.is_dir():
        raise SystemExit(f"[pf-app] template root missing: {TEMPLATE_ROOT}")

    slug = slugify(name)
    app_id = app_id or default_app_id(slug)
    if not re.match(r"^[a-z0-9][a-z0-9._-]*$", app_id):
        raise SystemExit(f"[pf-app] --id {app_id!r} is not a valid app id "
                         f"(schema pattern ^[a-z0-9][a-z0-9._-]*$)")

    dest = (out_dir or Path.cwd() / slug).resolve()
    if dest.exists() and any(dest.iterdir()) and not force:
        raise SystemExit(f"[pf-app] {dest} exists and is not empty (use --force to overwrite)")

    tokens = {
        "APP_ID": app_id,
        "APP_NAME": name,
        "APP_SLUG": slug,
        "BIN_NAME": slug,               # native/on-device binary basename
        "DEVICE": device,
        "FAMILY": FAMILY_BY_DEVICE[device],
        "ABI": ABI,
        "PLATFORM_VERSION": PLATFORM_VERSION,
    }

    n = 0
    for src in sorted(TEMPLATE_ROOT.rglob("*")):
        rel = src.relative_to(TEMPLATE_ROOT)
        if src.is_dir():
            continue
        out_rel = rel.with_name(rel.name[:-3]) if rel.name.endswith(".in") else rel
        out_path = dest / out_rel
        out_path.parent.mkdir(parents=True, exist_ok=True)
        if is_probably_text(src):
            text = src.read_text(encoding="utf-8")
            out_path.write_text(render_text(text, tokens, str(rel)), encoding="utf-8")
        else:
            out_path.write_bytes(src.read_bytes())
        # Preserve the source mode (keeps launch/build.sh/run-under-sim.py executable).
        os.chmod(out_path, stat.S_IMODE(src.stat().st_mode))
        n += 1

    print(f"[pf-app] scaffolded {app_id} ({tokens['FAMILY']}) -> {dest}  ({n} files)")
    print(f"[pf-app] next:")
    print(f"  cd {dest}")
    print(f"  ./build.sh                       # hermetic aarch64 cross-build (needs docker)")
    print(f"  ./ci/run-under-sim.py --device {device} ...   # off-hardware proof (see README.md)")
    print(f"  # validate the descriptor against the platform schema:")
    print(f"  pf app-validate app.toml         # from a pocketforge-os/platform checkout")
    return dest


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="pf-app", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p_new = sub.add_parser("new", help="scaffold a new PocketForge app project")
    p_new.add_argument("name", help="human-readable app name (also the default dir slug)")
    p_new.add_argument("--device", required=True, choices=sorted(FAMILY_BY_DEVICE),
                       help="target SoC family: a133 (Smart Pro) | a523 (Smart Pro S)")
    p_new.add_argument("--id", default=None, dest="app_id",
                       help="reverse-DNS app id (default com.example.<slug>)")
    p_new.add_argument("--dir", default=None, type=Path,
                       help="output directory (default ./<slug>)")
    p_new.add_argument("--force", action="store_true",
                       help="overwrite a non-empty output directory")
    args = ap.parse_args(argv)

    if args.cmd == "new":
        scaffold(args.name, args.device, args.app_id, args.dir, args.force)
        return 0
    ap.error(f"unknown command {args.cmd!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
