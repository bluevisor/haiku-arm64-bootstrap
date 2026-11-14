#!/bin/bash
# Build Capstone's AArch64 disassembler as a static, position independent
# library for Haiku arm64. The Debugger's arm64 architecture
# (patches/haiku-hrev60368/0023-Debugger-arm64-architecture.patch) links it into
# libdebugger.so; jam finds it through HAIKU_CAPSTONE_DIR.
#
# Runs in the haiku-tools container (needs the cross compiler from the
# Haiku build in /build/haiku/generated.arm64). Output:
#   /build/deps/capstone-arm64/include/capstone/*.h
#   /build/deps/capstone-arm64/lib/libcapstone.a
set -euo pipefail

VERSION=${CAPSTONE_VERSION:-5.0.3}
SHA256=3970c63ca1f8755f2c8e69b41432b710ff634f1b45ee4e5351defec4ec8e1753
CROSS=${CROSS:-/build/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku}
SRCDIR=/build/deps/capstone-src
OUT=${HAIKU_CAPSTONE_DIR:-/build/deps/capstone-arm64}

mkdir -p "$SRCDIR"
cd "$SRCDIR"
if [ ! -f "capstone-$VERSION.tar.gz" ]; then
	curl -sSL -o "capstone-$VERSION.tar.gz" \
		"https://github.com/capstone-engine/capstone/archive/refs/tags/$VERSION.tar.gz"
fi
echo "$SHA256  capstone-$VERSION.tar.gz" | sha256sum -c -
rm -rf "capstone-$VERSION" && tar xzf "capstone-$VERSION.tar.gz"
cd "capstone-$VERSION"

# Only the AArch64 back end; Capstone's own malloc/free hooks default to libc.
CFLAGS="-O2 -fPIC -fvisibility=hidden -Iinclude -I. -DCAPSTONE_HAS_ARM64 \
	-DCAPSTONE_USE_SYS_DYN_MEM -DCAPSTONE_DIET_NO"
rm -rf obj && mkdir obj
for f in cs.c MCInst.c MCInstrDesc.c MCRegisterInfo.c SStream.c utils.c \
		Mapping.c arch/AArch64/*.c; do
	[ -f "$f" ] || continue
	"$CROSS-gcc" $CFLAGS -c "$f" -o "obj/$(echo "$f" | tr / _ | sed 's/\.c$/.o/')"
done

rm -rf "$OUT" && mkdir -p "$OUT/lib" "$OUT/include"
"$CROSS-ar" rcs "$OUT/lib/libcapstone.a" obj/*.o
cp -r include/capstone "$OUT/include/"
cp LICENSE.TXT "$OUT/LICENSE.TXT"
ls -la "$OUT/lib/libcapstone.a"
