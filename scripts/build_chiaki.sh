#!/bin/zsh
# Builds chiaki-ng's libchiaki (+ bundled deps) for macOS arm64 with Veyra's video-metadata patch.
set -euo pipefail
ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHIAKI="$ROOT/third_party/chiaki-ng"
VEYRA="$ROOT/third_party/veyra"
PIN_CHIAKI="43728af2e639fecb8a7af1cd68c29820a40de973"
PIN_VEYRA="0dac67a0153a0a9881b8b022200d8888dd782107"
# Check out exactly the tested commits; a moving upstream must never change the build silently.
# pin <dir> <url> <sha> [submodules]: fetches only <sha> (shallow) when it is not already there,
# checks it out detached (-f: the patches are re-applied below), and with "submodules" puts every
# submodule at the commit that <sha> records. A checkout already at <sha> keeps its applied patches.
pin() {
  local dir=$1 url=$2 sha=$3 subs=${4:-}
  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$dir"; git -C "$dir" init -q; git -C "$dir" remote add origin "$url"
  fi
  if [[ "$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true)" != "$sha" ]]; then
    git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$dir" fetch -q --depth 1 origin "$sha"
    git -C "$dir" checkout -q -f --detach "$sha"
  fi
  if [[ "$subs" == submodules ]]; then
    git -C "$dir" submodule sync -q --recursive
    git -C "$dir" submodule update -q --init --recursive --force --depth 1
    if git -C "$dir" submodule status --recursive | grep -q '^[-+U]'; then
      echo "${dir:t}: submodules do not match $sha" >&2; exit 1
    fi
  fi
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$sha" ]] || { echo "${dir:t}: HEAD is not the pin $sha" >&2; exit 1; }
  echo "${dir:t} at $sha"
}
pin "$CHIAKI" https://github.com/streetpea/chiaki-ng.git "$PIN_CHIAKI" submodules
pin "$VEYRA" https://github.com/Likely7/Veyra-NRVideo.git "$PIN_VEYRA"
PATCH="$VEYRA/scripts/remoteplay/patches/0002-chiaki-video-metadata.patch"
if git -C "$CHIAKI" apply --check "$PATCH" 2>/dev/null; then git -C "$CHIAKI" apply "$PATCH"; echo "applied 0002"; 
elif git -C "$CHIAKI" apply -R --check "$PATCH" 2>/dev/null; then echo "0002 already applied";
else echo "0002 metadata patch does not fit this chiaki-ng revision" >&2; exit 1; fi
# Framelift patches (scripts/patches/*.patch), e.g. 0100: user-interactive QoS for chiaki threads.
# Check "already applied" first: a patch that only inserts lines (0110) can still apply forward
# a second time, because its own last lines repeat the context it was anchored on.
for P in "$ROOT"/scripts/patches/*.patch(N); do
  if git -C "$CHIAKI" apply -R --check "$P" 2>/dev/null; then echo "${P:t} already applied";
  elif git -C "$CHIAKI" apply --check "$P" 2>/dev/null; then git -C "$CHIAKI" apply "$P"; echo "applied ${P:t}";
  else echo "${P:t} does not fit this chiaki-ng revision; if a patch changed, reset with: git -C third_party/chiaki-ng checkout -f -- ." >&2; exit 1; fi
done
[[ -d "$ROOT/.venv" ]] || { python3 -m venv "$ROOT/.venv"; "$ROOT/.venv/bin/pip" install -q protobuf grpcio-tools; }
export PATH="$ROOT/.venv/bin:$PATH"
brew list miniupnpc libevent json-c opus openssl@3 >/dev/null 2>&1 || brew install miniupnpc libevent json-c opus openssl@3
SSL=/opt/homebrew/opt/openssl@3
BUILD="${CHIAKI_BUILD_DIR:-$ROOT/build/chiaki}"
rm -rf "$BUILD"
cmake -S "$CHIAKI" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_C_FLAGS="-I$SSL/include" -DCMAKE_CXX_FLAGS="-I$SSL/include" \
  -DCHIAKI_ENABLE_GUI=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
  -DCHIAKI_ENABLE_PI_DECODER=OFF -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_LIB_ENABLE_OPUS=ON \
  -DOpus_INCLUDE_DIRS=/opt/homebrew/opt/opus/include -DOpus_LIBRARIES=/opt/homebrew/opt/opus/lib/libopus.a \
  -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBPSL=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF \
  -DOPENSSL_ROOT_DIR=$SSL -DCMAKE_PREFIX_PATH="$SSL;/opt/homebrew" -DPYTHON_EXECUTABLE="$ROOT/.venv/bin/python3" -DPython3_EXECUTABLE="$ROOT/.venv/bin/python3" >/dev/null
make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" chiaki-lib >/dev/null
# Stage headers + static libs where Package.swift expects them.
OUT="${CHIAKI_DIST_DIR:-$ROOT/build/chiaki-dist}"; rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$CHIAKI/lib/include/chiaki" "$OUT/include/"
cp "$BUILD/lib/include/chiaki/"*.h "$OUT/include/chiaki/" 2>/dev/null || true
find "$BUILD" -name "*.a" -exec cp {} "$OUT/lib/" \;
for l in opus json-c event miniupnpc; do cp /opt/homebrew/opt/${l/event/libevent}/lib/lib$l*.a "$OUT/lib/" 2>/dev/null || true; done
cp $SSL/lib/libcrypto.a $SSL/lib/libssl.a "$OUT/lib/"
ls "$OUT/lib"
# Guard: every object must have been compiled against OpenSSL 3 headers (the app links libcrypto 3).
if grep -rl "Cellar/openssl@4" "$BUILD" --include="*.o.d" | grep -q .; then echo "ERROR: OpenSSL 4 headers leaked into build" >&2; exit 1; fi
echo "chiaki build OK"
