#!/bin/bash
# Codecs for Haiku arm64: FFmpeg 6 and Haiku's ffmpeg media plugin, which is
# what MediaPlayer, MediaConverter and every BMediaFile user decode through.
# The arm64 image has only the raw decoder: no MP3, AAC, H.264 or Vorbis.
#
#   DEPS=/build/deps bash build-ffmpeg.sh
#
# Builds, like HaikuPorts' ffmpeg6 recipe (patchset included):
#   lame 3.100              libmp3lame (MP3 encoding) + lame
#   dav1d 1.5.4             AV1 decoding
#   ffmpeg6 6.1.6           the libraries; FFmpeg's own decoders cover MP3,
#                           AAC, FLAC, ALAC, Vorbis, Opus, H.264, HEVC, VP8,
#                           VP9, MPEG-1/2/4, Theora, MJPEG and more
#   ffmpeg6_devel           headers, link symlinks, pkg-config
#   ffmpeg6_tools           ffmpeg, ffprobe (no ffplay: no SDL2 on arm64)
#   haiku_ffmpeg_plugin     add-ons/media/plugins/ffmpeg from the hrev tree,
#                           built with jam against the packages above
#
# Runs in the container that holds the Haiku tree for the VM's hrev
# (/build/haiku, generated.arm64; build-haiku-system.sh), with this repo's
# scripts/container and patches/haikuports at /repo. $DEPS holds the openssl3,
# bzip2, libiconv and xz_utils packages from haiku-arm64-packages; their
# libraries and headers go into the sysroot.
# Output: /repo/out/packages
set -euxo pipefail

declare -A SHA=(
	[lame-3.100.tar.gz]=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
	[dav1d-1.5.4.tar.bz2]=2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
	[ffmpeg-6.1.6.tar.xz]=d4fcb164028dd3beee5d92c0ac72e46aac6973c75ea12dc14de07bf8f407370a
)
declare -A URL=(
	[lame-3.100.tar.gz]=https://downloads.sourceforge.net/project/lame/lame/3.100
	[dav1d-1.5.4.tar.bz2]=https://code.videolan.org/videolan/dav1d/-/archive/1.5.4
	[ffmpeg-6.1.6.tar.xz]=https://ffmpeg.org/releases
)

source "$(dirname "$0")/hpkg-common.sh"
want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

export PKG_CONFIG_LIBDIR=$SR/boot/system/develop/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$SR
export PKG_CONFIG_PATH=

# --- dependencies from haiku-arm64-packages, into the sysroot ---
DEPS=${DEPS:?set DEPS to a directory with the openssl3, bzip2, libiconv and xz_utils .hpkg files}
for p in openssl3 bzip2 libiconv xz_utils; do
	f=$(ls "$DEPS"/$p-[0-9]*-arm64.hpkg | tail -1)
	rm -rf $SRC/deps/$p && mkdir -p $SRC/deps/$p
	pkgtool extract -C $SRC/deps/$p "$f"
	to_sysroot $SRC/deps/$p
done
# their .pc files name /boot/system paths; PKG_CONFIG_SYSROOT_DIR maps them
# zlib: the sysroot may lack the headers; use the bootstrap zlib + zlib_devel
# that jam downloaded (both: zlib_devel's link symlinks point into zlib's lib/)
for p in zlib zlib_devel; do
	rm -rf $SRC/deps/$p && mkdir -p $SRC/deps/$p
	pkgtool extract -C $SRC/deps/$p \
		/build/haiku/generated.arm64/download/$p-1.2.13_bootstrap-1-arm64.hpkg
	to_sysroot $SRC/deps/$p
done
[ -f $SR/boot/system/develop/headers/zlib.h ] && [ -e $SR/boot/system/develop/lib/libz.so ]

# --- lame 3.100 ---
if want lame; then
unpack lame-3.100.tar.gz
# 2017 config.sub doesn't know aarch64-*-haiku
cp /usr/share/misc/config.sub /usr/share/misc/config.guess .
haiku_configure lame --disable-static --disable-frontend-tests >/dev/null
make $J >/dev/null
R=$(dest lame)
make install DESTDIR=$R >/dev/null
R=$R$S
mkdir -p $R/data/licenses && cp COPYING $R/data/licenses/lame
tidy $R
to_sysroot $R
package $R lame 3.100 "LAME Ain't an MP3 Encoder" \
	"LAME is a high quality MPEG Audio Layer III (MP3) encoder: the lame command line encoder and the libmp3lame library." \
	"1998-2017 The LAME Project" "GNU LGPL v2"
fi

# --- dav1d 1.5.4 ---
if want dav1d; then
unpack dav1d-1.5.4.tar.bz2
cat > cross.txt <<EOF
[binaries]
c = '$H-gcc'
cpp = '$H-g++'
ar = '$H-ar'
strip = '$H-strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
EOF
meson setup build --cross-file cross.txt --buildtype=release \
	--prefix=$S --bindir=bin --libdir=lib --includedir=develop/headers \
	-Denable_tests=false -Denable_tools=true >/dev/null
ninja -C build >/dev/null
R=$(dest dav1d)
DESTDIR=$R ninja -C build install >/dev/null
R=$R$S
mkdir -p $R/data/licenses && cp COPYING $R/data/licenses/dav1d
tidy $R
to_sysroot $R
package $R dav1d 1.5.4 "AV1 cross-platform decoder" \
	"dav1d is a fast AV1 video decoder: the libdav1d library and the dav1d command line tool." \
	"2018-2025 VideoLAN and dav1d authors" "BSD (2-clause)"
fi

# --- ffmpeg 6.1.6 ---
if want ffmpeg; then
unpack ffmpeg-6.1.6.tar.xz
patch -p1 < $PATCHES/ffmpeg-6.1.6.patchset
./configure --enable-cross-compile --cross-prefix=$H- --arch=aarch64 \
	--target-os=haiku --pkg-config=pkg-config \
	--prefix=$S --bindir=$S/bin --datadir=$S/data/ffmpeg6 \
	--incdir=$S/develop/headers --libdir=$S/lib --shlibdir=$S/lib \
	--mandir=$S/documentation/man \
	--disable-debug --disable-stripping --disable-static --enable-shared \
	--enable-version3 --enable-pic --disable-doc --disable-sdl2 \
	--enable-libmp3lame --enable-libdav1d --enable-openssl \
	--enable-bzlib --enable-zlib --enable-lzma --enable-iconv
make $J >/dev/null
R=$(dest ffmpeg)
make install DESTDIR=$R >/dev/null
R=$R$S
mkdir -p $R/data/licenses && cp COPYING.LGPLv3 $R/data/licenses/ffmpeg6
tidy $R
to_sysroot $R

# split like the recipe: libraries / devel / tools
B=$(dest ffmpeg6)$S; D=$(dest ffmpeg6_devel)$S; T=$(dest ffmpeg6_tools)$S
mkdir -p $B $D $T
cp -a $R/lib $R/data $B/
cp -a $R/develop $D/
if [ -d $B/data/ffmpeg6/examples ]; then
	mkdir -p $D/data/ffmpeg6 && mv $B/data/ffmpeg6/examples $D/data/ffmpeg6/
fi
cp -a $R/bin $T/
[ -d $R/documentation ] && cp -a $R/documentation $T/

V=6.1.6
declare -A LV=([libavutil]=58.29.100 [libavcodec]=60.31.102 [libavformat]=60.16.101
	[libavdevice]=60.3.100 [libavfilter]=9.12.100 [libswscale]=7.5.100
	[libswresample]=4.12.100)
for l in "${!LV[@]}"; do [ -e $B/lib/$l.so.${LV[$l]} ]; done
DEVEL=""
for l in "${!LV[@]}"; do
	DEVEL+=$'\n'"	devel:$l = ${LV[$l]} compat >= ${LV[$l]%%.*}"
done
COPY="2000-2003 Fabrice Bellard, 2003-2026 the FFmpeg developers"
EXTRA_PROVIDES="	ffmpeg6_avdevice = $V compat >= 5" \
package $B ffmpeg6 $V "Audio and video recording, conversion, and streaming library" \
	"FFmpeg is a complete, cross-platform solution to record, convert and stream audio and video. Built with FFmpeg's own codecs plus LAME (MP3 encoding), dav1d (AV1) and OpenSSL." \
	"$COPY" "GNU LGPL v3"
EXTRA_PROVIDES="${DEVEL#$'\n'}" EXTRA_REQUIRES="ffmpeg6==$V" \
package $D ffmpeg6_devel $V "FFmpeg 6 development files" \
	"Headers, link libraries and pkg-config files for the FFmpeg 6 libraries." \
	"$COPY" "GNU LGPL v3"
package $T ffmpeg6_tools $V "FFmpeg 6 command line tools" \
	"ffmpeg converts and streams audio and video; ffprobe shows what a media file contains." \
	"$COPY" "GNU LGPL v3"
fi

# --- Haiku's ffmpeg media plugin, from the hrev tree ---
# The ffmpeg build feature turns on when jam's HaikuPorts list for arm64 has
# ffmpeg6 and ffmpeg6_devel; jam then extracts them from its download dir.
# Both edits are undone afterwards, so build-haiku-system.sh keeps building the
# system package without the plugin (it ships separately, below).
if want plugin; then
G=/build/haiku/generated.arm64
LIST=/build/haiku/build/jam/repositories/HaikuPorts/arm64
cp $OUT/ffmpeg6-6.1.6-$REV-arm64.hpkg $OUT/ffmpeg6_devel-6.1.6-$REV-arm64.hpkg $G/download/
trap 'git -C /build/haiku checkout -- build/jam/repositories/HaikuPorts/arm64' EXIT
sed -i "s/^\tgcc-13/\tffmpeg6-6.1.6-$REV\n\tffmpeg6_devel-6.1.6-$REV\n&/" $LIST
grep -q "ffmpeg6_devel-6.1.6" $LIST
HREV=$(cat $G/build/haiku-revision)
cd $G
LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib:$G/objects/linux/lib \
	jam -q $J -sHAIKU_REVISION=$HREV -sHAIKU_DISTRO_COMPATIBILITY=official \
	ffmpeg
PLUGIN=$G/objects/haiku/arm64/release/add-ons/media/plugins/ffmpeg/ffmpeg
[ -f $PLUGIN ]
R=$(dest haiku_ffmpeg_plugin)$S
mkdir -p $R/add-ons/media/plugins
cp $PLUGIN $R/add-ons/media/plugins/ffmpeg
$H-strip --strip-unneeded $R/add-ons/media/plugins/ffmpeg
# The plugin uses the media kit's private add-on API, so it is tied to the
# hrev it was built for.
PV=r1~beta6_${HREV}
cat > $R/.PackageInfo <<EOF
name			haiku_ffmpeg_plugin
version			$PV-1
architecture	arm64
summary			"FFmpeg media plugin for Haiku"
description		"Haiku's ffmpeg media kit plugin (reader, decoder, writer and encoder), built for $HREV. MediaPlayer, MediaConverter and other media kit apps decode through it."
packager		"haiku-arm64-bootstrap"
vendor			"haiku-arm64-bootstrap"
copyrights		{ "2001-2026 Haiku, Inc. et al" }
licenses		{ "MIT" }
provides {
	haiku_ffmpeg_plugin = $PV-1
}
requires {
	haiku>=$PV
	lib:libavcodec>=60
	lib:libavformat>=60
	lib:libavutil>=58
	lib:libswresample>=4
	lib:libswscale>=7
}
EOF
(cd $R && pkgtool create -q -z zlib -i .PackageInfo "$OUT/haiku_ffmpeg_plugin-$PV-1-arm64.hpkg")
fi
ls -la $OUT
