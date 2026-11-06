#!/bin/bash
# Build every local Haiku change for one hrev in a single pass and package the
# result as revision 2 of `haiku`, `haiku_devel` and `haiku_datatranslators`.
# This replaces the one-fix-per-revision chain (build-haiku-chromium-fixes.sh ..
# build-haiku-backtab.sh) and the hand-made "regular profile" revisions.
#
#   HREV_NUM=60368 bash build-haiku-system.sh
#
# Expects:
#   /build/patches-hrev$HREV_NUM/*.patch   git format-patch output, from
#                                          patches/haiku-hrev$HREV_NUM
#   $NATIVE_TRANSLATORS                    a haiku_datatranslators .hpkg that
#                                          holds the PNG/JPEG/WebP translators
#                                          built on the VM
#                                          (scripts/guest/build-image-translators-native.sh)
#   the cross tools from build-cross-tools.sh, in /build/haiku/generated.arm64
#
# Writes /build/out/hrev$HREV_NUM/{haiku,haiku_devel,haiku_datatranslators}-r1~beta6_hrev$HREV_NUM-2-arm64.hpkg
#
# The arm64 nightly is the *minimum* profile. The plain jam build here is the
# *regular* profile (Mail, MediaPlayer, HaikuDepot, the media kit, more
# drivers and translators). The system package is the stock one with:
#   - the binaries our patches change, overwritten from the jam build
#   - every file the regular profile adds that the stock package lacks
# Every other stock binary stays byte-identical. (A package made only from
# jam's output broke Deskbar once: empty leaf menu, no tray clock.)
set -euxo pipefail

N=${HREV_NUM:?set HREV_NUM, e.g. 60368}
HREV=r1~beta6_hrev$N
NATIVE_TRANSLATORS=${NATIVE_TRANSLATORS:?set NATIVE_TRANSLATORS to a haiku_datatranslators .hpkg with the native PNG/JPEG/WebP translators}
G=/build/haiku/generated.arm64
X=$G/cross-tools-arm64
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
# The host tools in generated/ must come first: generated.arm64's copies use
# a different attribute store, and mimeset then writes app MIME entries that
# come out empty without an error.
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib:$G/objects/linux/lib
OUT=/build/out/hrev$N
HAIKU_REPO=https://eu.hpkg.haiku-os.org/haiku/master/arm64/current/packages
J=-j"$(nproc)"

# 1. Source tree at the tag, with the patch set on a local branch. Uncommitted
# edits from earlier work are stashed, not dropped.
cd /build/haiku
# (add -A first: an intent-to-add entry makes a plain `stash -u` fail)
git diff --quiet HEAD || { git add -A && git stash push -m "before hrev$N"; }
git fetch -q --depth 1 origin tag hrev$N
if [ "$(git rev-parse --abbrev-ref HEAD)" != local-hrev$N ]; then
	git switch -C local-hrev$N hrev$N
	git -c user.name="John Zheng" -c user.email=bluevisor@gmail.com \
		am -q -3 /build/patches-hrev$N/*.patch
fi

# 2. OpenSSL headers + link libraries for libbnetapi (same build as
# build-tls.sh; the runtime libs ship in the openssl3 package already on the VM)
if [ ! -f $NP/include/openssl/ssl.h ]; then
	mkdir -p /build/tls && cd /build/tls
	[ -f openssl-3.5.9.tar.gz ] || wget -q https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
	rm -rf openssl-3.5.9 && tar xzf openssl-3.5.9.tar.gz && cd openssl-3.5.9
	cat > Configurations/60-haiku-aarch64.conf <<'EOF'
my %targets = (
    "haiku-aarch64" => {
        inherit_from     => [ "haiku-common" ],
        bn_ops           => "SIXTY_FOUR_BIT_LONG",
    },
);
EOF
	PATH=$X/bin:$PATH CC=gcc ./Configure haiku-aarch64 no-asm shared no-tests no-docs \
		--cross-compile-prefix=aarch64-unknown-haiku- \
		--prefix=/boot/system/non-packaged --libdir=lib \
		--openssldir=/boot/system/non-packaged/data/ssl
	PATH=$X/bin:$PATH make $J >/dev/null
	PATH=$X/bin:$PATH make install_sw DESTDIR=$SR >/dev/null
fi
STAGE=/build/openssl3-stage
rm -rf $STAGE && mkdir -p $STAGE/develop/headers $STAGE/develop/lib
cp -a $NP/include/openssl $STAGE/develop/headers/
for l in ssl crypto; do ln -s $NP/lib/lib$l.so.3 $STAGE/develop/lib/lib$l.so; done

# 3. The regular-profile packages in one jam run. Jam doesn't notice changed
# flags or build rules, so a new hrev starts from empty target objects (the
# host tools and cross tools are kept). HAIKU_DISTRO_COMPATIBILITY=official is
# what the stock build uses; without it the logos in data/artwork are dropped.
cd $G
# jam only writes build/haiku-revision when it is missing, even with
# HAIKU_REVISION set; a stale one stamps the old hrev into the kernel, libroot
# and every package version.
rm -f build/haiku-revision build/last-built-revision
if [ "$(cat objects/.hrev 2>/dev/null)" != hrev$N ]; then
	rm -rf objects/haiku
	mkdir -p objects && echo hrev$N > objects/.hrev
fi
jam -q $J -sHAIKU_REVISION=hrev$N -sHAIKU_LOCAL_OPENSSL=$STAGE \
	-sHAIKU_DISTRO_COMPATIBILITY=official \
	haiku.hpkg haiku_datatranslators.hpkg libtracker.so
O=$G/objects/haiku/arm64/release
JP=$O/../packaging/packages

# 4. Unpack the stock packages and jam's
mkdir -p /build/hpkg $OUT
for p in haiku haiku_devel haiku_datatranslators; do
	f=$p-$HREV-1-arm64.hpkg
	[ -f /build/hpkg/$f ] || wget -q -O /build/hpkg/$f "$HAIKU_REPO/$f"
done
unpack() { rm -rf "$2" && mkdir -p "$2" && $PKG extract -C "$2" "$1"; }
W=/build/repack-hrev$N
unpack /build/hpkg/haiku-$HREV-1-arm64.hpkg $W/haiku
unpack $JP/haiku.hpkg $W/haiku-regular
unpack /build/hpkg/haiku_datatranslators-$HREV-1-arm64.hpkg $W/haiku_datatranslators
unpack $JP/haiku_datatranslators.hpkg $W/haiku_datatranslators-regular
unpack "$NATIVE_TRANSLATORS" $W/translators-native

# add_missing <from> <to>: copy every file and symlink <to> lacks (cp -a keeps
# the Haiku attributes, stored as xattrs; data/mime_db entries need them)
add_missing() {
	local c=0 f
	while IFS= read -r f; do
		[ -e "$2/$f" ] || [ -L "$2/$f" ] && continue
		mkdir -p "$2/$(dirname "$f")"
		cp -a "$1/$f" "$2/$f"
		c=$((c + 1))
	done < <(cd "$1" && find . -mindepth 1 \( -type f -o -type l \) ! -name .PackageInfo | sed 's|^\./||')
	echo "added $c files from $1"
}

# 5. haiku: stock + the patched binaries + the regular profile's extra files
cd $W/haiku
LIB=$W/haiku-regular/lib/libbnetapi.so
$X/bin/aarch64-unknown-haiku-readelf -d $LIB | grep -q 'NEEDED.*\[libssl\.so\.3\]'
for f in kernel_arm64 runtime_loader lib/libroot.so lib/libbnetapi.so \
		add-ons/kernel/network/protocols/tcp servers/input_server \
		servers/app_server add-ons/kernel/drivers/graphics/virtio_gpu \
		add-ons/input_server/devices/mouse \
		add-ons/input_server/devices/tablet preferences/Input \
		preferences/Appearance apps/Terminal; do
	# overwrite in place: keeps the stock file's Haiku attributes
	cat "$W/haiku-regular/$f" > "$f"
done
add_missing $W/haiku-regular $W/haiku
# virtio_gpu (0009/0015) is in the stock package since about hrev60368 and is
# overwritten above; hda (0010) is a regular-profile file
cmp add-ons/kernel/drivers/graphics/virtio_gpu $O/add-ons/kernel/drivers/graphics/virtio/virtio_gpu
cmp add-ons/kernel/drivers/bin/hda $O/add-ons/kernel/drivers/audio/hda/hda
# jam's .PackageInfo lists what the regular profile needs; drop the packages
# arm64 doesn't have, and add our provides markers and libbnetapi's OpenSSL
cp $W/haiku-regular/.PackageInfo .PackageInfo
sed -i "/^\tnoto_sans_cjk_jp$/d;/^\t[a-z]*_wifi_firmwares$/d" .PackageInfo
sed -i "s/^\thaiku=$HREV-1 compat>=r1~beta1$/&\n\thaiku_rchromium_fixes=1\n\thaiku_bnetapi_ssl=1\n\thaiku_arm64_psci_shutdown=1\n\thaiku_tcp_eof_after_close=1\n\thaiku_mouse_natural_scrolling=1\n\thaiku_appearance_dark_mode=1\n\thaiku_terminal_mouse_wheel=1\n\thaiku_terminal_back_tab=1\n\thaiku_regular_profile=1\n\thaiku_libroot_arm64_swap_float=1\n\thaiku_app_server_offscreen_targets=1/" .PackageInfo
sed -i "s/^\tlib:libz>=1.2.13$/&\n\tlib:libssl>=3\n\tlib:libcrypto>=3/" .PackageInfo
grep -q "^version[[:space:]]r1~beta6_hrev$N-1$" .PackageInfo
grep -q haiku_app_server_offscreen_targets .PackageInfo
grep -q lib:libssl .PackageInfo
! grep -q wifi_firmwares .PackageInfo

# 6. haiku_datatranslators: stock + regular + the three native translators
# (arm64 has no libpng/jpeg/webp build packages, so jam skips them)
cd $W/haiku_datatranslators
add_missing $W/haiku_datatranslators-regular .
for t in PNGTranslator JPEGTranslator WebPTranslator; do
	rm -f add-ons/Translators/$t
	cp -a $W/translators-native/add-ons/Translators/$t add-ons/Translators/$t
done
cp $W/haiku_datatranslators-regular/.PackageInfo .PackageInfo
grep -q "^[[:space:]]lib:libpng16" .PackageInfo || \
	sed -i "s/^\thaiku>=r1~beta1$/&\n\tlib:libpng16\n\tlib:libjpeg\n\tlib:libwebp/" .PackageInfo
grep -q "lib:libwebp" .PackageInfo

# 7. haiku_devel: stock. It requires haiku==<exact version>, so all three
# move to -2 together.
unpack /build/hpkg/haiku_devel-$HREV-1-arm64.hpkg $W/haiku_devel
for p in haiku haiku_devel haiku_datatranslators; do
	cd $W/$p
	sed -i "s/hrev$N-1/hrev$N-2/g" .PackageInfo
	grep -q "hrev$N-2" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-2-arm64.hpkg"
done

# 8. Quick Look's libtracker (patch 0017), for scripts/guest/install-libtracker.sh
cp $O/kits/tracker/libtracker.so $OUT/libtracker.so
ls -la $OUT
