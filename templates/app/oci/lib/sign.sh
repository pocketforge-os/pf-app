#!/usr/bin/env bash
# sign.sh — produce the two-signature pair over the packaged bundle.
#   app.toml.sig : minisign (Ed25519) detached signature over app.toml
#   oci.sig      : cosign detached signature over oci/index.json — the content-addressed
#                  Merkle ROOT of the OCI image-layout. index.json commits to the manifest
#                  by sha256 digest, which commits to the config + every layer by digest, and
#                  every blob is stored under blobs/sha256/<its-digest>. So a valid signature
#                  over index.json + content-addressed load == a signature over the WHOLE
#                  image BY DIGEST: any tampered blob changes a digest the signature commits to.
#
# KEY BOUNDARY (honest): with --dev this signs using a LOCALLY-GENERATED dev/test keypair to
# PROVE the mechanism off-device. The REAL release keys are trust-tier / CI-OIDC-only and are
# NOT agent-readable — release signing happens in the image repo's sign-and-scan CI. Never
# claim release-signing performed here; --dev proves the bundle is well-formed for that CI.
set -euo pipefail

OUT="${OUT:?}"                # dir with oci/, oci.digest ; receives oci.sig, app.toml.sig
APP_TOML="${APP_TOML:?}"      # path to the app.toml to sign
MINISIGN_KEY="${MINISIGN_KEY:?}"   # minisign secret key file
COSIGN_KEY="${COSIGN_KEY:?}"       # cosign secret key file
: "${COSIGN_PASSWORD:=}"; export COSIGN_PASSWORD

INDEX="$OUT/oci/index.json"
[ -f "$INDEX" ] || { echo "sign: $INDEX missing — run pipeline.sh first" >&2; exit 1; }

# minisign over app.toml (prehashed default; matches the on-device libsodium verify).
# app.toml was placed alongside the oci/ by pipeline.sh as the signed bundle sibling.
[ -f "$OUT/app.toml" ] || cp "$APP_TOML" "$OUT/app.toml"
minisign -S -s "$MINISIGN_KEY" -m "$OUT/app.toml" -x "$OUT/app.toml.sig" \
    -c "PocketForge app descriptor" -t "PocketForge app.toml signature"
echo "signed: app.toml.sig (minisign)"

# cosign over the OCI Merkle root (index.json) == sign-by-digest. cosign v3 emits a
# sigstore bundle (self-describing: signature + public-key hint) — oci.sig IS that bundle.
cosign sign-blob --key "$COSIGN_KEY" --yes \
    --bundle "$OUT/oci.sig" "$INDEX" >/dev/null 2>&1
echo "signed: oci.sig (cosign bundle over oci/index.json; image digest $(cat "$OUT/oci.digest"))"
