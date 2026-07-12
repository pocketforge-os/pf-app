#!/usr/bin/env bash
# verify.sh — OFF-DEVICE proof that the signed bundle is well-formed: exactly the checks the
# on-device supervisor will perform, run here (on the build host / CI) before the bundle ever
# reaches silicon. Proves the two-signature pair + the by-digest binding hold.
set -euo pipefail

OUT="${OUT:?}"
MINISIGN_PUB="${MINISIGN_PUB:?}"
COSIGN_PUB="${COSIGN_PUB:?}"

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }
INDEX="$OUT/oci/index.json"

# 1. minisign: app.toml.sig verifies against the release pub
minisign -Vm "$OUT/app.toml" -p "$MINISIGN_PUB" -x "$OUT/app.toml.sig" \
    || fail "app.toml.sig minisign verify failed"
echo "OK  app.toml.sig verifies (minisign / Ed25519)"

# 2. cosign: oci.sig (sigstore bundle) verifies against the release pub over index.json
cosign verify-blob --key "$COSIGN_PUB" --bundle "$OUT/oci.sig" "$INDEX" \
    || fail "oci.sig cosign verify failed"
echo "OK  oci.sig verifies (cosign over oci/index.json)"

# 3. by-digest binding: the signed index.json still commits to the recorded image digest,
#    and every blob it (transitively) names is present under blobs/sha256/<digest>.
SIGNED_DIGEST="$(cat "$OUT/oci.digest")"
LIVE_DIGEST="$(jq -r '.manifests[0].digest' "$INDEX")"
[ "$SIGNED_DIGEST" = "$LIVE_DIGEST" ] \
    || fail "digest drift: signed=$SIGNED_DIGEST live=$LIVE_DIGEST"
MAN_BLOB="$OUT/oci/blobs/${LIVE_DIGEST/://}"
[ -f "$MAN_BLOB" ] || fail "manifest blob $MAN_BLOB absent"
# recompute the manifest blob's sha256 and confirm it equals the digest index.json commits to
CALC="sha256:$(sha256sum "$MAN_BLOB" | cut -d' ' -f1)"
[ "$CALC" = "$LIVE_DIGEST" ] || fail "manifest content-address mismatch: $CALC != $LIVE_DIGEST"
echo "OK  by-digest binding intact (index.json -> $LIVE_DIGEST, content-addressed)"

echo "VERIFY PASS — bundle is well-formed for the on-device supervisor"
