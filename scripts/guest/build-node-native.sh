#!/bin/bash
# Native Node.js 24.21.0 build on Haiku arm64, packaged by
# scripts/container/package-nodejs.sh. Patches: the HaikuPorts patchset
# (net-libs/nodejs) plus patches/haikuports/nodejs-24.21.0-arm64.patch for
# the bundled deps HaikuPorts takes from system packages that arm64 doesn't
# have (libuv/c-ares/zlib Haiku support, no libexecinfo) and the
# patchset's commented-out os.cpus(). OpenSSL is our openssl3 package.
#
# Run with tools/rcc/ (rcc-server.py on the host) first in PATH, or V8 takes
# ~11 h: native GCC is ~20x slower on big TUs than the same GCC in haiku-bfs.
#   PATH=/boot/home/rcc/bin:$PATH bash build-node-native.sh   # ~35 min
# Copy both patches next to this script (or set PATCHDIR) first.
# Output: $DEST (default /boot/home/node-pkgroot) and $DEST.tar
set -euo pipefail
V=24.21.0
SHA=622424efb5dc0c26c93fbb619ff10737ee289c605b837c88778e186925d82777
WORK=${WORK:-/boot/home/src/node}
PATCHDIR=${PATCHDIR:-$(cd "$(dirname "$0")" && pwd)}
DEST=${DEST:-/boot/home/node-pkgroot}
JOBS=${JOBS:-16}

mkdir -p "$WORK" && cd "$WORK"
[ -f node-v$V.tar.gz ] || curl -fsSLO https://nodejs.org/dist/v$V/node-v$V.tar.gz
echo "$SHA  node-v$V.tar.gz" | sha256sum -c -
rm -rf node-v$V && tar xzf node-v$V.tar.gz && cd node-v$V
patch -p1 -s < "$PATCHDIR/nodejs-$V.patchset"
patch -p1 -s < "$PATCHDIR/nodejs-$V-arm64.patch"

./configure --dest-os=haiku --dest-cpu=arm64 --ninja --prefix=/boot/system \
	--shared-openssl --shared-openssl-includes=/boot/system/develop/headers \
	--shared-openssl-libpath=/boot/system/develop/lib
ninja -C out/Release -j"$JOBS" node
out/Release/node -e 'if (require("os").cpus().length < 1) process.exit(1)'

rm -rf "$DEST"
python3 tools/install.py install --dest-dir "$DEST" --prefix /boot/system \
	--build-dir out/Release --silent
tar -C "$DEST" -cf "$DEST.tar" .
echo "built: $DEST.tar"
