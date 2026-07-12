#!/usr/bin/env bash
# pipeline.sh — runs INSIDE the pack container. mmdebstrap -> tar -> umoci OCI-layout ->
# syft SBOM. Signing + grype are separate steps (sign.sh / scan.sh). Deterministic:
# SOURCE_DATE_EPOCH drives faketime-free reproducibility via mmdebstrap + umoci.
set -euo pipefail

PAYLOAD="${PAYLOAD:-/pack/payload}"      # dir with <slug>.arm64, launch, app.toml
OUT="${OUT:-/pack/out}"                  # dir to receive oci/, sbom.spdx.json
APP_ID="${APP_ID:?}"
APP_VERSION="${APP_VERSION:?}"
APP_SLUG="${APP_SLUG:?}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
SUITE="${SUITE:-bookworm}"
SDE="${SOURCE_DATE_EPOCH:-1700000000}"
export SOURCE_DATE_EPOCH="$SDE"

echo "== pipeline: $APP_ID:$APP_VERSION arch=$TARGET_ARCH suite=$SUITE SDE=$SDE =="
# clear CONTENTS of $OUT (it may be a bind-mount point — do not remove the dir itself)
mkdir -p "$OUT"; rm -rf "${OUT:?}"/* "${OUT:?}"/.[!.]* 2>/dev/null || true
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- 1. minimal Debian base layer (mmdebstrap) --------------------------------
# variant=minbase: the smallest FULLY-CONFIGURED apt/dpkg Debian base (real /bin/sh, libc,
# coreutils) — a functional, provenance-clean runtime rootfs. arm64 maintainer scripts run
# under host-registered qemu binfmt (F-flag). Deterministic: SOURCE_DATE_EPOCH + mmdebstrap's
# sorted, reproducible tar. (A leaner variant=custom rootfs is a tracked follow-up; minbase is
# the correct, functional default.)
BASE_TAR="$WORK/base.tar"
mmdebstrap \
    --architectures="$TARGET_ARCH" \
    --variant=minbase \
    --format=tar \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --include=ca-certificates \
    "$SUITE" "$BASE_TAR"
echo "base.tar: $(du -h "$BASE_TAR" | cut -f1)"

# ---- 2. app payload layer ------------------------------------------------------
APP_ROOT="$WORK/approot"
mkdir -p "$APP_ROOT/opt/app"
cp "$PAYLOAD/$APP_SLUG.arm64" "$APP_ROOT/opt/app/$APP_SLUG.arm64"
cp "$PAYLOAD/launch"          "$APP_ROOT/opt/app/launch"
cp "$PAYLOAD/app.toml"        "$APP_ROOT/opt/app/app.toml"
chmod 0755 "$APP_ROOT/opt/app/launch" "$APP_ROOT/opt/app/$APP_SLUG.arm64"
# app.toml also rides ALONGSIDE the oci/ as a bundle sibling (what gets minisign'd)
cp "$PAYLOAD/app.toml" "$OUT/app.toml"

# ---- 3. assemble the OCI image-layout with umoci ------------------------------
OCI="$OUT/oci"
umoci init --layout "$OCI"
umoci new --image "$OCI:$APP_VERSION"
# unpack the empty image, drop the base rootfs + app payload in, repack as a layer
BUNDLE="$WORK/bundle"
umoci unpack --rootless --image "$OCI:$APP_VERSION" "$BUNDLE"
tar -C "$BUNDLE/rootfs" -xf "$BASE_TAR"
cp -a "$APP_ROOT/." "$BUNDLE/rootfs/"
umoci repack --image "$OCI:$APP_VERSION" "$BUNDLE"
# runtime config
umoci config --image "$OCI:$APP_VERSION" \
    --architecture "$TARGET_ARCH" --os linux \
    --config.user 1000:1000 \
    --config.workingdir /opt/app \
    --config.entrypoint /opt/app/launch \
    --config.env "SDL_DYNAMIC_API=/usr/lib/libSDL3-pocketforge.so.0" \
    --config.label "org.pocketforge.app.id=$APP_ID" \
    --config.label "org.pocketforge.app.version=$APP_VERSION"
umoci gc --layout "$OCI"

# ---- 4. the image DIGEST (this is what cosign signs BY DIGEST) -----------------
MANIFEST_DIGEST="$(jq -r '.manifests[0].digest' "$OCI/index.json")"
echo "$MANIFEST_DIGEST" > "$OUT/oci.digest"
echo "image manifest digest: $MANIFEST_DIGEST"

# ---- 5. SBOM (syft over the OCI layout) ---------------------------------------
syft scan "oci-dir:$OCI" -o spdx-json > "$OUT/sbom.spdx.json" 2>/dev/null
echo "sbom packages: $(jq '.packages | length' "$OUT/sbom.spdx.json")"

echo "== pipeline done =="
ls -R "$OUT" | head -40
