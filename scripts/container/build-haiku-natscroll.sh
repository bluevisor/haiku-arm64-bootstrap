#!/bin/bash
# Add a "Natural scrolling" option for mice (Input preferences, mouse page),
# on by default: build input_server, the mouse and tablet input_server
# add-ons and the Input preferences with
# patches/haiku/mouse-natural-scrolling.patch and repack the revision-5
# haiku/haiku_devel from build-haiku-tcp.sh as revision 6.
# Haiku only had natural scrolling for real touchpads (two-finger scrolling).
# Under UTM/QEMU a Mac trackpad or wheel arrives as the wheel of a USB
# tablet/mouse, so it scrolled the opposite way to macOS. The input_server
# keeps the setting per device in ~/config/settings/Mouse_settings (devices
# saved before it existed read as on); the tablet add-on is covered too,
# since QEMU's absolute pointer is a tablet.
# The haiku package also gains `provides haiku_mouse_natural_scrolling = 1`.
#
# Needs build-haiku-tcp.sh first. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-6-arm64.hpkg
# Install both with one `pkgman install <file> <file>`; a reboot (or an
# input_server restart) loads the new add-ons.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if [ ! -f headers/private/input/mouse_natural_scrolling.h ]; then
	git apply /repo/patches/haiku/mouse-natural-scrolling.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 input_server "<input>mouse" \
	"<input>tablet" Input
O=$G/objects/haiku/arm64/release

for p in haiku haiku_devel; do
	rm -rf "/build/repack6-$p" && mkdir -p "/build/repack6-$p" && cd "/build/repack6-$p"
	$PKG extract -C . "$OUT/$p-$HREV-5-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the files' Haiku attributes
		cat $O/servers/input/input_server > servers/input_server
		cat $O/add-ons/input_server/devices/mouse/mouse \
			> add-ons/input_server/devices/mouse
		cat $O/add-ons/input_server/devices/tablet/tablet \
			> add-ons/input_server/devices/tablet
		cat $O/preferences/input/Input > preferences/Input
		sed -i "s/^\thaiku_tcp_eof_after_close=1$/&\n\thaiku_mouse_natural_scrolling=1/" .PackageInfo
		grep -q haiku_mouse_natural_scrolling .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-5/hrev60290-6/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-6-arm64.hpkg"
done
ls -la $OUT
