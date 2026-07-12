# pf-app — PocketForge app developer SDK & tooling

`pf-app` is the authoring surface for PocketForge apps: scaffold a new app, build
and sign it into a signed OCI bundle, and target a named per-SoC-family Platform
ABI contract.

```
pf-app new mygame --device a523   # scaffold from the canonical SDL3 immediate-mode shape
pf-app build                      # mmdebstrap -> tar -> OCI layout
pf-app sign                       # app.toml.sig (minisign) + oci.sig (cosign-by-digest)
pf-app push <device>              # deliver to a fielded device WITHOUT a reflash
```

Home of the `pf-app new` scaffold, app templates, and the "build your own
PocketForge app" guide. The public capability-facade ABI it targets lives in
[`pocketforge-os/runtime`](https://github.com/pocketforge-os/runtime)
(`libpocketforge.so.1`); the named per-family Platform ABI contract + canonical
`app.toml` schema live in [`pocketforge-os/platform`](https://github.com/pocketforge-os/platform)
(`abi/`).

Filed under epic **tsp-ziac** (E8 — App Packaging + Distribution + Developer SDK),
child **tsp-ziac.2**. Design: `mission-control/.planning/infra/infra-107-app-packaging-sdk-distribution.md`.
