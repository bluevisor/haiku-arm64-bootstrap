#!/bin/bash
# Build Haiku's host tools: bfs_shell (with the BFS grow fixes) and the
# `package` tool (to extract .hpkg files). Run inside a debian:bookworm
# container with this repo mounted at /repo:
#
#   docker run -d --name haiku-bfs -v "$PWD":/repo debian:bookworm sleep infinity
#   docker exec haiku-bfs bash /repo/scripts/container/build-bfs-shell.sh
#
# Sources are cloned into /build (container filesystem; a macOS bind mount is
# slow for git and can't hold Haiku file attributes).
set -euxo pipefail

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	git g++ make bison flex zlib1g-dev libzstd-dev python3 nasm attr \
	bzip2 xz-utils wget curl file >/dev/null 2>&1

mkdir -p /build && cd /build
# Only jam is needed from buildtools here; the full repo (gcc, binutils) is
# fetched later by build-cross-tools.sh. A blobless sparse clone is fast.
[ -d buildtools ] || { git clone --depth 1 --filter=blob:none --sparse https://github.com/haiku/buildtools.git && git -C buildtools sparse-checkout set jam; }
[ -d haiku ] || git clone --depth 1 https://github.com/haiku/haiku.git

(cd buildtools/jam && make -j"$(nproc)" >/dev/null && cp bin.*/jam /usr/local/bin/jam)

cd /build/haiku
# BFS can only grow via bfs_shell, and stock bfs_shell can't grow a volume:
# see patches/bfs-resize-fixes.patch.
git apply --check /repo/patches/bfs-resize-fixes.patch 2>/dev/null && git apply /repo/patches/bfs-resize-fixes.patch
# The host build of the package tool fails with GCC 12:
# "'offsetof' was not declared in this scope".
grep -q '<cstddef>' src/kits/storage/sniffer/RPattern.cpp || \
	sed -i 's|#include "Data.h"|#include "Data.h"\n#include <cstddef>|' src/kits/storage/sniffer/RPattern.cpp

mkdir -p generated && cd generated
../configure --host-only
jam -q -j"$(nproc)" '<build>bfs_shell' '<build>package'

ARCH=$(uname -m | sed 's/aarch64/arm64/')
echo "bfs_shell: /build/haiku/generated/objects/linux/$ARCH/release/tools/bfs_shell/bfs_shell"
echo "package:   /build/haiku/generated/objects/linux/$ARCH/release/tools/package/package"
echo "           (run with LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib)"
