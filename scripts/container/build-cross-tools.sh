#!/bin/bash
# Build the aarch64-unknown-haiku GCC cross toolchain with Haiku's own build
# system, then populate its sysroot from the arm64 haiku + haiku_devel packages
# so ordinary programs can be compiled and linked.
#
# Needs build-bfs-shell.sh first (it clones /build/haiku and builds `package`).
# Takes ~15 minutes on 12 cores.
set -euxo pipefail

HREV=${HREV:-r1~beta6_hrev60290}          # must match the Haiku you run
HAIKU_REPO=https://eu.hpkg.haiku-os.org/haiku/master/arm64/current/packages

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	texinfo gawk bc autoconf automake libtool unzip zip \
	libgmp-dev libmpfr-dev libmpc-dev >/dev/null 2>&1

# full buildtools checkout (binutils + gcc sources)
cd /build/buildtools && git sparse-checkout disable

cd /build/haiku && mkdir -p generated.arm64 && cd generated.arm64
[ -x cross-tools-arm64/bin/aarch64-unknown-haiku-gcc ] || \
	../configure --cross-tools-source ../../buildtools --build-cross-tools arm64 -j"$(nproc)"

# The configured sysroot doesn't exist yet: fill it with the target's headers,
# crt objects and libraries.
X=/build/haiku/generated.arm64/cross-tools-arm64
SR=$X/sysroot/boot/system
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
mkdir -p "$SR" /build/hpkg && cd /build/hpkg
for p in "haiku_devel-$HREV-1-arm64.hpkg" "haiku-$HREV-1-arm64.hpkg"; do
	[ -f "$p" ] || wget -q "$HAIKU_REPO/$p"
	LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib "$PKG" extract -C "$SR" "$p"
done

# smoke test
cat > /tmp/hello.c <<'EOF'
#include <stdio.h>
int main(void) { puts("hello from Haiku"); return 0; }
EOF
"$X/bin/aarch64-unknown-haiku-gcc" -O2 -o /tmp/hello /tmp/hello.c
file /tmp/hello
echo "cross compiler: $X/bin/aarch64-unknown-haiku-gcc"
