# pf-app — PocketForge app developer SDK & tooling

`pf-app` is the authoring surface for PocketForge apps. It scaffolds a new, buildable,
signable SDL3 app that talks to the device **only through the capability facade**
(`libpocketforge`), links the platform SDL3 via **`SDL3_DYNAMIC_API`** (never a vendored
SDL3), and pins a **named per-SoC-family Platform ABI** in its `app.toml`. The emitted app
builds hermetically from committed pins and is **proven off-hardware under the E5 simulator**
before any device is touched.

## Quickstart

```sh
./pf-app new "My App" --device a523      # scaffold (or --device a133)
cd my-app
./build.sh                               # hermetic aarch64 cross-build (docker)
./ci/run-under-sim.py --device a523 ...  # off-hardware proof: draws + reads a button
```

Full walkthrough: **[`docs/BUILD-YOUR-OWN-APP.md`](docs/BUILD-YOUR-OWN-APP.md)**.

## What `pf-app new` emits

A complete, self-contained app project (see [`templates/app/`](templates/app)):

| file | what it is |
|---|---|
| `app.toml` | THE canonical app descriptor — `[app]` + `[runtime]` per-family pin + `use=[]`. Validates via platform `pf app-validate`. |
| `src/main.c` | a minimal SDL3 immediate-mode skeleton: a rectangle that turns green while a button is held, input via the facade. Derived from the reference app `pf-hwprobe`. |
| `launch` | the on-device `SDL3_DYNAMIC_API` shim (swaps in `libSDL3-pocketforge.so.0`). |
| `build.sh` · `Makefile` · `pins.env` | hermetic aarch64 cross-build from committed refs. |
| `ci/run-under-sim.py` | the E5-simulator proof (grey → green on an injected button press). |
| `oci/build-oci.sh` | app-packaging harness **stub** (handed to the E8 packaging path). |
| `.github/workflows/app-smoke.yml` | advisory CI: build (portable) + sim (lab runner). |

The skeleton deliberately **dodges the `tsp-osr` renderer footgun** — it software-renders
off-screen under the sim, and documents the safe on-device window recipe (the owned-source
`libsdl3-sunxifb` "Fix A" is already merged; you just link the fixed lib).

## Roadmap (E8 epic `tsp-ziac`)

| child | scope | status |
|---|---|---|
| `.1` | capability-facade ABI + reconciled `app.toml` schema + named per-family Platform ABI | ✅ merged |
| **`.2`** | **`pf-app new` scaffold + templates + this guide** | **this repo** |
| `.3` | packaging: `mmdebstrap → tar → OCI → cosign-by-digest → syft → grype` (`pf-app build`/`sign`) | next |
| `.4` | distribution + deliver-without-reflash + per-developer keys (`pf-app push`) | design |

So `pf-app build` / `sign` / `push` are **not yet implemented** — `oci/build-oci.sh` is the
authoring-side stub that marks where the packaging path plugs in.

## The contracts it targets

- **Capability facade (frozen v1):** [`pocketforge-os/runtime`](https://github.com/pocketforge-os/runtime)
  — `include/pocketforge.h` (`libpocketforge.so.1`), `STABILITY.md`, `docs/RUNTIME-SDK-SPLIT.md`.
- **App descriptor schema + validator + named per-family Platform ABI:**
  [`pocketforge-os/platform`](https://github.com/pocketforge-os/platform) — `abi/app.schema.json`,
  `pf app-validate`, `docs/PLATFORM-ABI-CONTRACT.md`.
- **Reference app:** [`pocketforge-os/pf-hwprobe`](https://github.com/pocketforge-os/pf-hwprobe)
  (the full data-driven, per-control-class pattern).
- **Simulator:** [`pocketforge-os/sim`](https://github.com/pocketforge-os/sim).

## Development

Branch → PR → merge (no direct pushes to `main`); every non-draft PR carries the three
checklist sections (Summary / Test plan / Related PRs) and is gated by `pf-pr-review`.
Structural smoke: `tests/test-scaffold.sh` (`PLATFORM_PF=/path/to/platform/pf` also runs
`app-validate`).

Filed under epic **tsp-ziac** (E8), child **tsp-ziac.2**. Design:
`mission-control/.planning/infra/infra-107-app-packaging-sdk-distribution.md`.
