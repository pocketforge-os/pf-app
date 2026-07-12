# Build your own PocketForge app

This guide takes you from nothing to a running app **without any hardware** — scaffold →
build → run under the E5 simulator. A clean author needs no tribal knowledge: everything
below runs off the committed pins.

> **On-device is a separate phase.** Everything here is off-hardware and CI-able. Running on
> a real TrimUI is a distinct, owner-gated hardware step (`SDL_DYNAMIC_API` swap, panel
> bring-up); it is intentionally *not* part of this loop.

## 0. What a PocketForge app is

An app is a small binary that talks to the device **only through the capability facade** and
draws with **SDL3**:

```
capabilities.toml (the device descriptor, platform-provided)
  -> the E2 capability facade   (libpocketforge C ABI: pf_connect / pf_acquire / ...)
  -> SDL3                        (libSDL3-pocketforge.so.0, bound via SDL3_DYNAMIC_API)
  -> the panel (a framebuffer)
```

Three rules the platform — not the app — enforces:

1. **No ambient authority.** You never `open("/dev/input/...")` by scanning. You call
   `pf_acquire("input")` and the platform hands you the fd. Same for every capability.
2. **One descriptor, three consumers.** Your `app.toml` is read by the on-device broker at
   launch, by the packaging path at sign time, and by the SDK at scaffold. Author it once.
3. **The platform owns SDL3.** You build against SDL3's *public headers* and let
   `SDL3_DYNAMIC_API` bind the device's SDL3 at launch. You never ship a device SDL3.

## 1. Scaffold

```sh
git clone https://github.com/pocketforge-os/pf-app
./pf-app/pf-app new "My App" --device a523      # or --device a133
cd my-app
```

`--device` selects the **SoC family** you target:

| `--device` | family (`app.toml` `[runtime].family`) | board |
|---|---|---|
| `a133` | `pocketforge/a133-powervr` | TrimUI Smart Pro |
| `a523` | `pocketforge/a523-mali` | TrimUI Smart Pro S |

One app source → **one build per family** it supports (divergent kernel + GPU + SDL backend).
The scaffold emits:

```
my-app/
├── app.toml               # THE descriptor — [app]/[runtime]/[launch] (validate below)
├── launch                 # the SDL3_DYNAMIC_API on-device shim
├── src/main.c             # a rectangle that turns green while a button is held
├── build.sh  Makefile  pins.env    # hermetic aarch64 cross-build
├── ci/run-under-sim.py    # the off-hardware proof (grey -> green on a button press)
├── oci/build-oci.sh       # packaging stub (handed to the E8 packaging path)
├── .github/workflows/app-smoke.yml   # advisory CI (build + sim)
└── README.md  LICENSE  .gitignore
```

## 2. Validate the descriptor

The `app.toml` is checked by the platform's static validator (it needs `platform.lock`, so
it lives in the platform repo, not your app):

```sh
git clone https://github.com/pocketforge-os/platform
./platform/pf app-validate my-app/app.toml
# OK    my-app/app.toml: app descriptor valid ([runtime] pin resolves; use=[] well-formed)
```

It rejects an unknown `family`, an out-of-lock `platform-version`, an unsupported `abi`, and
a malformed `use=[]` token. The **capability semantics** (is `vibration` a real cap? does the
device back a required cap?) are the on-device broker's authoritative check at launch — the
static validator deliberately doesn't re-implement that across the language boundary. Full
contract: `platform/docs/PLATFORM-ABI-CONTRACT.md`.

### The `use=[]` capability graph

`use` is the **ceiling** of what your app may ever acquire — the broker refuses anything
outside it. A trailing `?` marks a capability **optional**: if the device can't back it you
get a graceful `HardwareAbsent`, not a failure. The starter declares:

```toml
use = ["input", "vibration?"]
```

It *requires* `input` and *optionally* uses `vibration` (the code calls `pf_rumble_pulse`,
which returns a tri-state — it never crashes on a device with no rumble). Add a capability by
adding its token here **and** acquiring it in code — the two must agree.

## 3. Build (hermetic, off-hardware)

```sh
./build.sh          # -> build/my-app.arm64
```

Needs `docker` + `aarch64-linux-gnu-gcc`. It clones the pinned runtime (E2), sim (E5), and
platform (E1) from `pins.env`, cross-builds `libpocketforge.a` and a stock software-render
`libSDL3.a`, and static-links the binary. Reproducible: the same pins give the same bytes.

## 4. Run under the E5 simulator

The sim runs the **identical arm64 binary** under `qemu-tsp` + bubblewrap, synthesizes the
device's uinput nodes from the descriptor, and drives your app over a FIFO. `run-under-sim.py`
boots it, snapshots the rest frame (**grey**), injects a real button press, and snapshots
again (**green**):

```sh
sg input -c "./ci/run-under-sim.py \
    --device a523 \
    --binary   ./build/my-app.arm64 \
    --sim      ./.cache/sim \
    --platform ./.cache/platform \
    --qemu-tsp /home/mm/qemu-tsp/build/qemu-tsp/qemu-aarch64 \
    --rootfs   /home/mm/sim-build/harness/rootfs-arm64 \
    --outdir   ./evidence/a523"
# ... run-under-sim] a523: PASS (draws + reads a button, off-hardware)
```

`sg input -c` (or `sudo`) is needed for the root-only `/dev/uinput` node. Run host:
**modelmaker** (`mm@10.0.40.90`) or any host with the sim prereqs. Evidence frames land under
`evidence/<device>/frames/*.ppm`.

That's the whole loop: **scaffold → validate → build → run**, no device touched.

## 5. Understand the skeleton (`src/main.c`)

- **`connect_runtime()`** — `pf_connect_descriptor(<io-dir>/capabilities.toml)` (or
  `pf_connect()` from the environment). Gives you a `PfSession*`.
- **`acquire_input()`** — the two-step capability seam:
  1. `pf_acquire(session, "input")` must return `PF_OK` (authorization through the facade).
  2. `input_fd_for()` is the **single swappable seam**: under the sim it opens the
     platform-provided node path from `layout.txt`; on-device you swap its body to the frozen
     facade export `pf_acquire_input_fd(session)` — no other code changes.
- **`render_frame()`** — a software-rendered rectangle: grey at rest, green while any button
  is down. Software render is inherently **tsp-osr-safe**.
- **`pin_tsp_osr_recipe()`** — documents the safe on-device renderer recipe (create the
  window so its EGL surface is valid, then `SDL_CreateRenderer(win, NULL)`). The owned-source
  fix (`libsdl3-sunxifb` "Fix A") is already merged; you just link the fixed lib.
- **FIFO loop** — `ready` / `snap <ppm>` / `quit`, the E5 sim's contract.

## 6. Grow it

- **More controls / real UI** — read more of `layout.txt`, draw more. The reference app
  `pocketforge-os/pf-hwprobe` shows the **data-driven, per-control-class** pattern: one module
  per control class (`widget_stick`, `widget_trigger`, `widget_hat`, ...), and **missing
  hardware is a descriptor-row omission, never a stub error**.
- **More capabilities** — add the token to `use=[]`, acquire it in code (`pf_rumble_pulse`,
  `pf_entropy_fill`, the IMU seam). Keep code and manifest in agreement.
- **CI** — `.github/workflows/app-smoke.yml` builds on every PR (portable) and runs the sim
  proof on the lab runner (advisory). Promote it to a required check once it's stable.

## 7. Package (preview)

```sh
./oci/build-oci.sh          # stages the payload; STUB for now
```

Packaging is the E8 packaging path (`tsp-ziac.3`): `mmdebstrap → tar → OCI → cosign
sign-by-digest → syft SBOM → grype scan`, producing the sibling files that ride beside
`app.toml` in the installed bundle (`app.toml.sig`, `oci/`, `oci.sig`, `sbom.spdx.json`,
`slice.conf`). The stub stages what you already own and marks each hand-off point.

## Reference

- **Schema + validator + ABI contract:** `pocketforge-os/platform` → `abi/app.schema.json`,
  `pf app-validate`, `docs/PLATFORM-ABI-CONTRACT.md`.
- **Capability facade (frozen v1):** `pocketforge-os/runtime` → `include/pocketforge.h`,
  `STABILITY.md`, `docs/RUNTIME-SDK-SPLIT.md`.
- **Reference app:** `pocketforge-os/pf-hwprobe` (the full data-driven pattern).
- **Simulator:** `pocketforge-os/sim`.
