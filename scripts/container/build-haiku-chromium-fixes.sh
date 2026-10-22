#!/bin/bash
# Build Haiku's arm64 kernel + runtime_loader with the fixes R Chromium needs
# (patches/haiku/rchromium-fixes-hrev60290.patch) and repack the stock
# hrev60290 `haiku` and `haiku_devel` packages around them as revision 2.
# The haiku package also gains `provides haiku_rchromium_fixes = 1`.
#
# Needs build-bfs-shell.sh (package tool) and build-cross-tools.sh. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-2-arm64.hpkg
# Install both with one `pkgman install <file> <file>` and reboot.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system
HAIKU_REPO=https://eu.hpkg.haiku-os.org/haiku/master/arm64/current/packages

# hrev60290 == ef0d53750b82 (tags live on review.haiku-os.org, not the GitHub
# mirror). hrev60291/60292 only touch tests and Terminal, so the hrev60292 tree
# build-bfs-shell.sh clones builds identical kernel and loader code.
cd /build/haiku
if ! grep -q tlsdesc src/system/runtime_loader/arch/arm64/Jamfile; then
	git apply /repo/patches/haiku/rchromium-fixes-hrev60290.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 kernel_arm64 runtime_loader

mkdir -p /build/hpkg $OUT && cd /build/hpkg
for p in haiku haiku_devel; do
	f=$p-$HREV-1-arm64.hpkg
	[ -f "$f" ] || wget -q "$HAIKU_REPO/$f"
	rm -rf "/build/repack-$p" && mkdir -p "/build/repack-$p" && cd "/build/repack-$p"
	$PKG extract -C . "/build/hpkg/$f"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the files' Haiku attributes
		cat $G/objects/haiku/arm64/release/system/kernel/kernel_arm64 > kernel_arm64
		cat $G/objects/haiku/arm64/release/system/runtime_loader/runtime_loader > runtime_loader
		sed -i "s/\thaiku=$HREV-1 compat>=r1~beta1/\thaiku=$HREV-1 compat>=r1~beta1\n\thaiku_rchromium_fixes=1/" .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move to -2 together
	sed -i "s/hrev60290-1/hrev60290-2/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-2-arm64.hpkg"
	cd /build/hpkg
done
grep -q haiku_rchromium_fixes /build/repack-haiku/.PackageInfo
ls -la $OUT
