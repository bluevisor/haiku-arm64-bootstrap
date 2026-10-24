#!/bin/bash
# Build every local Haiku change for one hrev in a single pass and repack the
# stock `haiku` and `haiku_devel` packages around them as revision 2. This
# replaces the one-fix-per-revision chain (build-haiku-chromium-fixes.sh ..
# build-haiku-backtab.sh) when moving to a new hrev.
#
#   HREV_NUM=60295 bash build-haiku-system.sh
#
# Expects the rebased patch set in /build/patches-hrev$HREV_NUM (git
# format-patch output, from patches/haiku-hrev$HREV_NUM) and the cross tools
# from build-cross-tools.sh. Writes to /build/out/hrev$HREV_NUM:
#   haiku{,_devel}-r1~beta6_hrev$HREV_NUM-2-arm64.hpkg  system packages
#   non-packaged/   virtio_gpu + hda drivers and the media kit, for
#                   ~/config/non-packaged (the arm64 image ships none of them)
set -euxo pipefail

N=${HREV_NUM:?set HREV_NUM, e.g. 60295}
HREV=r1~beta6_hrev$N
G=/build/haiku/generated.arm64
X=$G/cross-tools-arm64
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
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
		am -q /build/patches-hrev$N/*.patch
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

# 3. Everything the patches touch, in one jam run
cd $G
jam -q $J -sHAIKU_REVISION=hrev$N -sHAIKU_LOCAL_OPENSSL=$STAGE \
	kernel_arm64 runtime_loader libbnetapi.so tcp \
	input_server "<input>mouse" "<input>tablet" Input Appearance Terminal \
	virtio_gpu hda libmedia.so libgame.so media_server media_addon_server \
	mixer.media_addon hmulti_audio.media_addon
O=$G/objects/haiku/arm64/release
LIB=$O/kits/network/libnetapi/ssl/libbnetapi.so
$X/bin/aarch64-unknown-haiku-readelf -d $LIB | grep -q 'NEEDED.*\[libssl\.so\.3\]'

# 4. Repack the stock packages
mkdir -p /build/hpkg $OUT
for p in haiku haiku_devel; do
	f=$p-$HREV-1-arm64.hpkg
	[ -f /build/hpkg/$f ] || wget -q -O /build/hpkg/$f "$HAIKU_REPO/$f"
	R=/build/repack-hrev$N-$p
	rm -rf $R && mkdir -p $R && cd $R
	$PKG extract -C . /build/hpkg/$f
	if [ $p = haiku ]; then
		# overwrite in place: keeps the files' Haiku attributes
		cat $O/system/kernel/kernel_arm64 > kernel_arm64
		cat $O/system/runtime_loader/runtime_loader > runtime_loader
		cat $LIB > lib/libbnetapi.so
		cat $O/add-ons/kernel/network/protocols/tcp/tcp > add-ons/kernel/network/protocols/tcp
		cat $O/servers/input/input_server > servers/input_server
		cat $O/add-ons/input_server/devices/mouse/mouse > add-ons/input_server/devices/mouse
		cat $O/add-ons/input_server/devices/tablet/tablet > add-ons/input_server/devices/tablet
		cat $O/preferences/input/Input > preferences/Input
		cat $O/preferences/appearance/Appearance > preferences/Appearance
		cat $O/apps/terminal/Terminal > apps/Terminal
		sed -i "s/^\thaiku=$HREV-1 compat>=r1~beta1$/&\n\thaiku_rchromium_fixes=1\n\thaiku_bnetapi_ssl=1\n\thaiku_arm64_psci_shutdown=1\n\thaiku_tcp_eof_after_close=1\n\thaiku_mouse_natural_scrolling=1\n\thaiku_appearance_dark_mode=1\n\thaiku_terminal_mouse_wheel=1\n\thaiku_terminal_back_tab=1/" .PackageInfo
		sed -i "s/^\tlib:libz>=1.2.13$/&\n\tlib:libssl>=3\n\tlib:libcrypto>=3/" .PackageInfo
		grep -q haiku_terminal_back_tab .PackageInfo
		grep -q lib:libssl .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move to -2 together
	sed -i "s/hrev$N-1/hrev$N-2/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-2-arm64.hpkg"
done

# 5. Drivers + media kit for ~/config/non-packaged
D=$OUT/non-packaged
rm -rf $D
mkdir -p $D/add-ons/kernel/drivers/bin $D/lib $D/bin $D/add-ons/media
cp $O/add-ons/kernel/drivers/graphics/virtio/virtio_gpu $D/add-ons/kernel/drivers/bin/
cp $O/add-ons/kernel/drivers/audio/hda/hda $D/add-ons/kernel/drivers/bin/
cp $O/kits/media/libmedia.so $O/kits/game/libgame.so $D/lib/
cp $O/servers/media/media_server $O/servers/media_addon/media_addon_server $D/bin/
cp $O/add-ons/media/media-add-ons/mixer/mixer.media_addon \
	$O/add-ons/media/media-add-ons/multi_audio/hmulti_audio.media_addon $D/add-ons/media/
ls -laR $OUT
