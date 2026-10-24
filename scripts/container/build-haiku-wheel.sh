#!/bin/bash
# Send the mouse wheel to terminal apps that track the mouse: build Terminal
# with patches/haiku/terminal-mouse-wheel.patch and repack the revision-7
# haiku/haiku_devel from build-haiku-darkmode.sh as revision 8. Haiku's
# Terminal turned every wheel step in the alternate screen into three
# Up/Down arrow keys, even when the app had turned on mouse reporting, so
# scrolling a pane in cmux, vim or htop moved through shell history or the
# cursor instead. With mouse reporting on, Terminal now sends xterm's wheel
# buttons 4 and 5 at the pointer (SGR or legacy encoding); without it,
# nothing changes. The haiku package also gains
# `provides haiku_terminal_mouse_wheel = 1`.
#
# Needs build-haiku-darkmode.sh first. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-8-arm64.hpkg
# Install both with one `pkgman install <file> <file>`, then reboot.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if ! grep -q _SendMouseWheelEvent src/apps/terminal/TermView.cpp; then
	git apply /repo/patches/haiku/terminal-mouse-wheel.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 Terminal
O=$G/objects/haiku/arm64/release

for p in haiku haiku_devel; do
	rm -rf "/build/repack8-$p" && mkdir -p "/build/repack8-$p" && cd "/build/repack8-$p"
	$PKG extract -C . "$OUT/$p-$HREV-7-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $O/apps/terminal/Terminal > apps/Terminal
		sed -i "s/^\thaiku_appearance_dark_mode=1$/&\n\thaiku_terminal_mouse_wheel=1/" .PackageInfo
		grep -q haiku_terminal_mouse_wheel .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-7/hrev60290-8/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-8-arm64.hpkg"
done
ls -la $OUT
