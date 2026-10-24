#!/bin/bash
# Send Shift+Tab to terminal apps as back-tab: build Terminal with
# patches/haiku/terminal-shift-tab.patch and repack the revision-8
# haiku/haiku_devel from build-haiku-wheel.sh as revision 9. Haiku's Terminal
# passed Shift+Tab through as a plain Tab byte, so no app could tell the two
# apart (reverse completion, Shift+Tab bindings in TUIs). It now sends xterm's
# CSI Z. The haiku package also gains
# `provides haiku_terminal_back_tab = 1`.
#
# Needs build-haiku-wheel.sh first. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-9-arm64.hpkg
# Install both with one `pkgman install <file> <file>`, then reboot.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if ! grep -q 'case B_TAB:' src/apps/terminal/TermViewStates.cpp; then
	git apply /repo/patches/haiku/terminal-shift-tab.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 Terminal
O=$G/objects/haiku/arm64/release

for p in haiku haiku_devel; do
	rm -rf "/build/repack9-$p" && mkdir -p "/build/repack9-$p" && cd "/build/repack9-$p"
	$PKG extract -C . "$OUT/$p-$HREV-8-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $O/apps/terminal/Terminal > apps/Terminal
		sed -i "s/^\thaiku_terminal_mouse_wheel=1$/&\n\thaiku_terminal_back_tab=1/" .PackageInfo
		grep -q haiku_terminal_back_tab .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-8/hrev60290-9/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-9-arm64.hpkg"
done
ls -la $OUT
