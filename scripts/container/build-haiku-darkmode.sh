#!/bin/bash
# Add a "Dark mode" check box to the Colors tab of the Appearance
# preferences: build Appearance with patches/haiku/appearance-dark-mode.patch
# and repack the revision-6 haiku/haiku_devel from build-haiku-natscroll.sh
# as revision 7. Haiku has a complete built-in dark color set (the dark
# variant of its defaults, BPrivate::GetSystemColor(which, true)) but no
# switch for it; you had to pick a dark panel color by hand. The box swaps
# every color between the light and dark sets (the desktop color stays), and
# follows the panel color when you change it, use Defaults or Revert.
# The haiku package also gains `provides haiku_appearance_dark_mode = 1`.
#
# Needs build-haiku-natscroll.sh first. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-7-arm64.hpkg
# Install both with one `pkgman install <file> <file>`; no reboot needed.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if ! grep -q DARK_MODE_CHANGED src/preferences/appearance/ColorsView.cpp; then
	git apply /repo/patches/haiku/appearance-dark-mode.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 Appearance
O=$G/objects/haiku/arm64/release

for p in haiku haiku_devel; do
	rm -rf "/build/repack7-$p" && mkdir -p "/build/repack7-$p" && cd "/build/repack7-$p"
	$PKG extract -C . "$OUT/$p-$HREV-6-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $O/preferences/appearance/Appearance > preferences/Appearance
		sed -i "s/^\thaiku_mouse_natural_scrolling=1$/&\n\thaiku_appearance_dark_mode=1/" .PackageInfo
		grep -q haiku_appearance_dark_mode .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-6/hrev60290-7/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-7-arm64.hpkg"
done
ls -la $OUT
