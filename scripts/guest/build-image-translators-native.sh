#!/bin/bash
# Native build of Haiku's PNG, JPEG and WebP data translators on Haiku arm64,
# against the libpng16 / libjpeg_turbo / libwebp packages from
# build-image-libs-native.sh (install those first), then repack the installed
# haiku_datatranslators package with them as the next revision.
#   bash build-image-translators-native.sh
# Needs $SRC_TGZ: src/add-ons/translators/{shared,png,jpeg,webp}, raw/*.h and
# headers/private/shared from the Haiku tree at the installed hrev.
# Output: $OUT/haiku_datatranslators-<version>-<rev+1>-arm64.hpkg
set -euo pipefail
WORK=${WORK:-/boot/home/src/imglibs/translators}
SRC_TGZ=${SRC_TGZ:-/boot/home/src/imglibs/haiku-translators-hrev60295.tgz}
OUT=${OUT:-/boot/home/imglibs-out}
mkdir -p "$WORK" "$OUT"
rm -rf "$WORK/tree" "$WORK/obj" && mkdir -p "$WORK/tree" "$WORK/obj"
tar xzf "$SRC_TGZ" -C "$WORK/tree"
T=$WORK/tree/src/add-ons/translators
O=$WORK/obj
# libroot's arm64 __swap_float/__swap_double (os/arch/arm64/byteorder.S) have
# their fmov operands reversed and return garbage, so B_BENDIAN_TO_HOST_FLOAT
# reads 0: JPEG encoded every image as 1x1 and decoded bitmap headers carried
# bogus bounds. Swap inline here; harmless once libroot has the fix (patch
# 0014, installed on the VM as haiku rev 5), and needed on older systems.
cat > "$O/swap_float_fix.h" <<'EOF'
#include <ByteOrder.h>
#include <string.h>
static inline float fixed_swap_float(float value)
{
	uint32 bits;
	memcpy(&bits, &value, sizeof(bits));
	bits = __builtin_bswap32(bits);
	memcpy(&value, &bits, sizeof(bits));
	return value;
}
#define __swap_float(arg) fixed_swap_float(arg)
EOF
CXXFLAGS="-O2 -fPIC -Wno-multichar -include $O/swap_float_fix.h -I$T/shared -I$T/raw -I$WORK/tree/headers/private/shared"

# libtranslatorsutils.a, as the Jamfile in translators/shared builds it
for f in BaseTranslator StreamBuffer TranslatorSettings TranslatorWindow; do
	g++ $CXXFLAGS -c "$T/shared/$f.cpp" -o "$O/$f.o"
done
ar rcs "$O/libtranslatorsutils.a" "$O"/{BaseTranslator,StreamBuffer,TranslatorSettings,TranslatorWindow}.o

# translator <name> <dir> <libs> <sources...>
translator() {
	local name=$1 dir=$2 libs=$3; shift 3
	local srcs=() s
	for s in "$@"; do srcs+=("$T/$dir/$s"); done
	g++ $CXXFLAGS -shared -o "$O/$name" "${srcs[@]}" "$O/libtranslatorsutils.a" \
		-lbe -ltranslation -llocalestub $libs
	rc -o "$O/$name.rsrc" "$T/$dir/$name.rdef"
	xres -o "$O/$name" "$O/$name.rsrc"
	mimeset -f "$O/$name"
	echo "built $name"
}

translator PNGTranslator png "-lpng16 -lz" PNGMain.cpp PNGTranslator.cpp PNGView.cpp
translator JPEGTranslator jpeg "-ljpeg" be_jdatadst.cpp be_jdatasrc.cpp \
	be_jerror.cpp exif_parser.cpp JPEGTranslator.cpp
translator WebPTranslator webp "-lwebp" main.cpp WebPTranslator.cpp ConfigView.cpp

# Repack the installed haiku_datatranslators with the three added
P=$(ls /boot/system/packages/haiku_datatranslators-*.hpkg)
base=${P##*/}; base=${base%-arm64.hpkg}		# haiku_datatranslators-<ver>-<rev>
ver=${base#haiku_datatranslators-}; rev=${ver##*-}; ver=${ver%-*}
R=$WORK/repack
rm -rf "$R" && mkdir -p "$R" && cd "$R"
package extract "$P"
for n in PNGTranslator JPEGTranslator WebPTranslator; do
	# copyattr keeps the resources' attributes (type, signature, icon)
	copyattr -d "$O/$n" "add-ons/Translators/$n"
done
newrev=$((rev + 1))
sed -i "s/$ver-$rev/$ver-$newrev/g" .PackageInfo
sed -i "s/^\thaiku>=r1~beta1$/&\n\tlib:libpng16\n\tlib:libjpeg\n\tlib:libwebp/" .PackageInfo
grep -q "lib:libwebp" .PackageInfo
package create -q -z zlib -i .PackageInfo "$OUT/haiku_datatranslators-$ver-$newrev-arm64.hpkg"
echo "packaged $OUT/haiku_datatranslators-$ver-$newrev-arm64.hpkg"
