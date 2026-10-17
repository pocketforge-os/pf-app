#!/usr/bin/env bash
# test-build-sh-pin-invalidation.sh — every derived artifact of the scaffolded
# build.sh must be bound to the pins.env commits (review pf-app#6, stale-state
# integrity): after a pin bump, libpocketforge.a (RUNTIME_COMMIT), libSDL3.a +
# sdl3-include (SIM_COMMIT) and the final linked binary must be invalidated,
# and the cached source worktrees must be reset exactly to the pin.
#
# Hermetic: git/docker/make are PATH shims that fabricate artifact CONTENT
# stamps; no network, no containers, no real toolchains. Positive control:
# after bumping SIM_COMMIT the SDL artifact content changes while the runtime
# artifact (pin unchanged) does not, and the binary relinks. Negative control:
# an unchanged pin set reuses everything (warm path stays warm).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${PF_APP_PIN_TEST_ROOT:-$HERE}"
TMP="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-app-pin.XXXXXX")"
cleanup() { find "$TMP" -mindepth 1 -delete; rmdir "$TMP"; }
trap cleanup EXIT

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# ---------------------------------------------------------------- shims
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat > "$SHIM/git" <<'EOF'
#!/usr/bin/env bash
# minimal git shim: clone fabricates a worktree; reset/checkout record the pin.
while [ "${1:-}" = "-c" ]; do shift 2; done  # skip -c key=value config pairs
sub="$1"; shift
last_nonflag=""
for a in "$@"; do case "$a" in -*) ;; *) last_nonflag="$a";; esac; done
case "$sub" in
  clone)
    dest="$last_nonflag"
    mkdir -p "$dest/.git" "$dest/include"
    echo "/* fake header */" > "$dest/include/pocketforge.h"
    ;;
  reset|checkout)
    [ -n "$last_nonflag" ] && echo "$last_nonflag" > .git/FAKE_HEAD
    ;;
  rev-parse) cat .git/FAKE_HEAD ;;
  fetch) : ;;
  clean)
    xflag=0
    for a in "$@"; do case "$a" in *x*) xflag=1 ;; esac; done
    if [ "$xflag" = 1 ] && [ -f .git/IGNORED ]; then
      while IFS= read -r p; do [ -n "$p" ] && rm -f "$p"; done < .git/IGNORED
    fi
    ;;
  *) echo "shim-git: unsupported: $sub $*" >&2; exit 1 ;;
esac
EOF
cat > "$SHIM/docker" <<'EOF'
#!/usr/bin/env bash
# minimal docker shim: fabricates the artifact a container step would produce.
out=""; workbuild=""; script=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a="${args[$i]}"
  case "$a" in
    -v|-e|-w)
      v="${args[$((i + 1))]}"
      case "$v" in
        *":/out") out="${v%:/out}" ;;
        *":/work/build") workbuild="${v%:/work/build}" ;;
      esac
      i=$((i + 2)); continue
      ;;
  esac
  i=$((i + 1))
done
script="${args[-1]}"
if [[ "$script" == *"make -f Makefile all"* ]]; then
  bin="$(printf '%s\n' "$script" | sed -n 's/^.*BIN_NAME=\([^[:space:]]*\).*$/\1/p' | head -1)"
  # timestamp semantics of a real make relink rule: only rewrite when missing
  # or when a dependency library is newer.
  need=1
  if [ -f "$workbuild/$bin" ]; then
    need=0
    for dep in "$workbuild/deps/libSDL3.a" "$workbuild/deps/libpocketforge.a"; do
      [ "$dep" -nt "$workbuild/$bin" ] && need=1
    done
  fi
  [ "$need" = 1 ] && echo "bin-$$-$RANDOM$RANDOM" > "$workbuild/$bin"
elif [[ "$script" == *libSDL3.a* && "$script" == *sdl3-include* ]]; then
  echo "sdl-$$-$RANDOM$RANDOM" > "$out/libSDL3.a"
  mkdir -p "$out/sdl3-include"
  echo "/* fake sdl header */" > "$out/sdl3-include/SDL.h"
elif [[ "$script" == *libpocketforge.a* ]]; then
  echo "pf-$$-$RANDOM$RANDOM" > "$out/libpocketforge.a"
else
  echo "shim-docker: unrecognized container script" >&2; exit 1
fi
# A successful warm build deliberately writes nothing. Do not leak the false
# no-relink predicate above as the shim's process status.
exit 0
EOF
cat > "$SHIM/make" <<'EOF'
#!/usr/bin/env bash
# minimal make shim (host fast path): fabricate the linked binary with the
# timestamp semantics of a real relink rule.
need=1
if [ -f "$OUT_DIR/$BIN_NAME" ]; then
  need=0
  for dep in "$SDL3_STATIC" "$PF_STATIC"; do
    [ "$dep" -nt "$OUT_DIR/$BIN_NAME" ] && need=1
  done
fi
[ "$need" = 1 ] && echo "bin-$$-$RANDOM$RANDOM" > "$OUT_DIR/$BIN_NAME"
exit 0
EOF
chmod +x "$SHIM/git" "$SHIM/docker" "$SHIM/make"

# ---------------------------------------------------------------- render
echo "rendering a smoke app from $ROOT ..."
"$ROOT/pf-app" new "Smoke a133" --device a133 --id com.example.smokea133 --dir "$TMP/app" >/dev/null
cd "$TMP/app"
BIN="build/smoke-a133.arm64"
content() { cat "$1"; }

run_build() {
  PATH="$SHIM:$PATH" bash ./build.sh >"$TMP/build-run.log" 2>&1 || {
    echo "build.sh FAILED:"; tail -20 "$TMP/build-run.log"; return 1;
  }
}

# ---------------------------------------------------------------- run 1: cold
run_build
for f in build/deps/libpocketforge.a build/deps/libSDL3.a "$BIN" \
         build/deps/.libpocketforge.runtime-sha build/deps/.libSDL3.sim-sha build/.linked-pins; do
  [ -f "$f" ] && ok "run1 produced $f" || fail "run1 missing $f"
done
pf1=$(content build/deps/libpocketforge.a); sdl1=$(content build/deps/libSDL3.a); bin1=$(content "$BIN")

# Plant an ignored leftover in every cached source worktree: `git clean -ffd`
# deliberately KEEPS ignored files, so only -ffdx (or a fresh clone) removes
# them; run 2 must rebind each worktree exactly to its pin.
for wt in .cache/runtime .cache/sim .cache/platform; do
  printf 'leftover\n' > "$wt/ignored-leftover"
  printf 'ignored-leftover\n' >> "$wt/.git/IGNORED"
done

# ---------------------------------------------------------------- run 2: warm, pins unchanged (negative control)
run_build
for wt in .cache/runtime .cache/sim .cache/platform; do
  if [ -e "$wt/ignored-leftover" ]; then
    fail "run2 kept the planted ignored leftover in $wt (clean must use -ffdx)"
  else
    ok "run2 removed the planted ignored leftover in $wt"
  fi
done
pf2=$(content build/deps/libpocketforge.a); sdl2=$(content build/deps/libSDL3.a); bin2=$(content "$BIN")
[ "$pf2" = "$pf1" ] && ok "run2 reused libpocketforge.a (pin unchanged)" || fail "run2 rebuilt libpocketforge.a despite unchanged pin"
[ "$sdl2" = "$sdl1" ] && ok "run2 reused libSDL3.a (pin unchanged)" || fail "run2 rebuilt libSDL3.a despite unchanged pin"
[ "$bin2" = "$bin1" ] && ok "run2 reused the linked binary (pins unchanged)" || fail "run2 relinked despite unchanged pins"

# ---------------------------------------------------------------- run 3: SIM_COMMIT bump
sed -i 's/^SIM_COMMIT=.*/SIM_COMMIT=1111111111111111111111111111111111111111/' pins.env
run_build
pf3=$(content build/deps/libpocketforge.a); sdl3c=$(content build/deps/libSDL3.a); bin3=$(content "$BIN")
[ "$sdl3c" != "$sdl2" ] && ok "run3 rebuilt libSDL3.a after the SIM pin bump" || fail "run3 REUSED the stale libSDL3.a after the SIM pin bump"
[ "$(cat build/deps/.libSDL3.sim-sha)" = "1111111111111111111111111111111111111111" ] && ok "run3 recorded the new sim sha" || fail "run3 sim sha stamp not updated"
[ "$pf3" = "$pf2" ] && ok "run3 kept libpocketforge.a (runtime pin unchanged)" || fail "run3 rebuilt libpocketforge.a despite unchanged runtime pin"
[ "$bin3" != "$bin2" ] && ok "run3 relinked the binary after the SIM pin bump" || fail "run3 KEPT the stale binary after the SIM pin bump"

# ---------------------------------------------------------------- run 4: RUNTIME_COMMIT bump
sed -i 's/^RUNTIME_COMMIT=.*/RUNTIME_COMMIT=2222222222222222222222222222222222222222/' pins.env
run_build
pf4=$(content build/deps/libpocketforge.a); sdl4=$(content build/deps/libSDL3.a); bin4=$(content "$BIN")
[ "$pf4" != "$pf3" ] && ok "run4 rebuilt libpocketforge.a after the RUNTIME pin bump" || fail "run4 REUSED the stale libpocketforge.a after the RUNTIME pin bump"
[ "$(cat build/deps/.libpocketforge.runtime-sha)" = "2222222222222222222222222222222222222222" ] && ok "run4 recorded the new runtime sha" || fail "run4 runtime sha stamp not updated"
[ "$sdl4" = "$sdl3c" ] && ok "run4 kept libSDL3.a (sim pin unchanged)" || fail "run4 rebuilt libSDL3.a despite unchanged sim pin"
[ "$bin4" != "$bin3" ] && ok "run4 relinked the binary after the RUNTIME pin bump" || fail "run4 KEPT the stale binary after the RUNTIME pin bump"

# ---------------------------------------------------------------- worktree binding
head="$(cat .cache/runtime/.git/FAKE_HEAD)"
[ "$head" = "2222222222222222222222222222222222222222" ] && ok "cached runtime worktree bound to the pin" || fail "cached runtime worktree at $head, not the pin"

if [ "$failures" -ne 0 ]; then
  echo "PIN-INVALIDATION FAIL ($failures check(s))"
  exit 1
fi
echo "PIN-INVALIDATION PASS (artifacts keyed to pins.env; stale deps invalidated; binary relinked; warm path stays warm)"
