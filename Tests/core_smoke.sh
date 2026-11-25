#!/bin/sh
# Builds and runs Tests/core_smoke.c against FrameliftCore (compiled from source) + build/chiaki-dist.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=build/core_smoke
mkdir -p "$OUT"
CXXFLAGS="-std=c++20 -O1 -Wall -Wextra -Wno-unused-parameter -ISources/FrameliftCore/include -ISources/FrameliftCore/RemotePlay/include -Ibuild/chiaki-dist/include -I/opt/homebrew/opt/openssl@3/include"
OBJS=""
for src in Sources/FrameliftCore/*.cpp Sources/FrameliftCore/RemotePlay/*.cpp; do
  obj="$OUT/$(basename "$src" .cpp).o"
  xcrun clang++ $CXXFLAGS -c "$src" -o "$obj"
  OBJS="$OBJS $obj"
done
xcrun clang -ISources/FrameliftCore/include -Ibuild/chiaki-dist/include -c Tests/core_smoke.c -o "$OUT/core_smoke.o"
xcrun clang++ "$OUT/core_smoke.o" $OBJS build/chiaki-dist/lib/libchiaki.a \
  build/chiaki-dist/lib/libcurl.a build/chiaki-dist/lib/libprotobuf-nanopb.a build/chiaki-dist/lib/libjerasure.a \
  build/chiaki-dist/lib/libgf_complete.a build/chiaki-dist/lib/libopus.a build/chiaki-dist/lib/libjson-c.a \
  build/chiaki-dist/lib/libminiupnpc.a build/chiaki-dist/lib/libevent.a build/chiaki-dist/lib/libevent_pthreads.a \
  build/chiaki-dist/lib/libssl.a build/chiaki-dist/lib/libcrypto.a \
  -framework CoreServices -framework SystemConfiguration -framework Security -lz -o "$OUT/core_smoke"
"$OUT/core_smoke"
