#!/bin/bash
# Native build of the image libraries Haiku's data translators need, on Haiku
# arm64, each packaged as one .hpkg (runtime + develop files). Versions match
# what x86_64 HaikuPorts ships.
#   bash build-image-libs-native.sh            # all
#   bash build-image-libs-native.sh libpng16   # one
# Sources are fetched from GitHub release tags and checked against SHA256.
# Output: $OUT (default /boot/home/imglibs-out)/*.hpkg
set -euo pipefail
WORK=${WORK:-/boot/home/src/imglibs}
OUT=${OUT:-/boot/home/imglibs-out}
JOBS=${JOBS:-8}
# Package revision. 2 = rebuilt with unwind tables (see CFLAGS below).
REV=${REV:-2}
# Haiku arm64 gcc does not emit unwind tables by default (other aarch64 targets
# do). Without them a C++ exception thrown from a callback cannot unwind
# through the library and ends in terminate(): PNGTranslator throws from its
# png_error handler, so every undecodable PNG killed Tracker's thumbnailer.
export CFLAGS="${CFLAGS:-} -fasynchronous-unwind-tables"
export CXXFLAGS="${CXXFLAGS:-} -fasynchronous-unwind-tables"
S=/boot/system
mkdir -p "$WORK" "$OUT"

declare -A URL SHA DIR
URL[libpng16]=https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.53.tar.gz
SHA[libpng16]=b20cee717e11416d2f96ccc7d184f63730ca8cb2f03bfd0c4ed77fbc909c0bff
DIR[libpng16]=libpng-1.6.53
URL[libjpeg_turbo]=https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.4.1.tar.gz
SHA[libjpeg_turbo]=a7da42b640377c2a9a9665e2c4b0ea60cd5599afb48c2521e6df0c9dc9d15a25
DIR[libjpeg_turbo]=libjpeg-turbo-3.1.4.1
URL[libwebp]=https://github.com/webmproject/libwebp/archive/refs/tags/v1.6.0.tar.gz
SHA[libwebp]=93a852c2b3efafee3723efd4636de855b46f9fe1efddd607e1f42f60fc8f2136
DIR[libwebp]=libwebp-1.6.0

# unpack <name>: fresh verified source tree, cwd set to it
unpack() {
	local tarball=$WORK/${DIR[$1]}.tar.gz
	[ -f "$tarball" ] || curl -fsSL -o "$tarball" "${URL[$1]}"
	echo "${SHA[$1]}  $tarball" | sha256sum -c - >/dev/null
	rm -rf "$WORK/${DIR[$1]}" && tar xzf "$tarball" -C "$WORK"
	cd "$WORK/${DIR[$1]}"
}

# CMake on Haiku arm64 reports the processor as "other" (uname -p) and
# overwrites a -DCMAKE_SYSTEM_PROCESSOR, so libjpeg-turbo and libpng skip
# their NEON code. A toolchain file's value survives detection.
TOOLCHAIN=$WORK/haiku-arm64-native.cmake
cat > "$TOOLCHAIN" <<'EOF'
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
EOF

# cmake_build <name> <cmake args...>: configure, build, install into $R
cmake_build() {
	local name=$1; shift
	R=$WORK/dest/$name
	rm -rf "$R" build && mkdir -p "$R"
	cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_INSTALL_PREFIX=$S -DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_INSTALL_INCLUDEDIR=develop/headers \
		-DCMAKE_INSTALL_DATAROOTDIR=data \
		-DCMAKE_INSTALL_MANDIR=documentation/man \
		-DCMAKE_INSTALL_DOCDIR=documentation/packages/$name "$@" >/dev/null
	ninja -C build -j"$JOBS" >/dev/null
	DESTDIR=$R ninja -C build install >/dev/null
	R=$R$S
}

# tidy: Haiku layout (HaikuPorts prepareInstalledDevelLib/fixPkgconfig) —
# unversioned .so symlinks and pkgconfig in develop/lib, ELF files stripped
tidy() {
	local f so
	rm -f "$R"/lib/*.la "$R"/lib/*.a
	for f in "$R"/lib/lib*.so; do
		[ -L "$f" ] || continue
		so=$(readelf -d "$(readlink -f "$f")" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		mkdir -p "$R/develop/lib"
		rm "$f" && ln -s "../../lib/$so" "$R/develop/lib/${f##*/}"
	done
	if [ -d "$R/lib/pkgconfig" ]; then
		mkdir -p "$R/develop/lib/pkgconfig"
		mv "$R"/lib/pkgconfig/*.pc "$R/develop/lib/pkgconfig/"
		rmdir "$R/lib/pkgconfig"
		sed -i "s|^libdir=.*|libdir=$S/develop/lib|" "$R"/develop/lib/pkgconfig/*.pc
	fi
	# CMake package configs point at lib/; the dev symlinks live in develop/lib
	[ -d "$R/lib/cmake" ] && { mkdir -p "$R/develop/lib"; mv "$R/lib/cmake" "$R/develop/lib/"; }
	find "$R" -type f -exec sh -c \
		'head -c4 "$1" | grep -q "^.ELF" && strip --strip-unneeded "$1"' _ {} \;
	return 0
}

# package <name> <version> <summary> <copyright> <licenses...>
package() {
	local name=$1 ver=$2 summary=$3 copy=$4; shift 4
	local f b so lib libver prov req=() l lics=""
	prov="	$name = $ver compat >= ${ver%%.*}"
	for f in "$R"/bin/*; do
		[ -e "$f" ] || continue
		b=${f##*/}
		prov+=$'\n'"	cmd:${b//-/_} = $ver compat >= ${ver%%.*}"
	done
	for f in "$R"/lib/lib*.so.*; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		so=$(readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		lib=${so%%.so*}; libver=${f##*.so.}
		prov+=$'\n'"	lib:$lib = $libver compat >= ${so##*.so.}"
		[ -e "$R/develop/lib/$lib.so" ] && prov+=$'\n'"	devel:$lib = $libver compat >= ${so##*.so.}"
	done
	# (Haiku's bash has no /dev/fd, so no process substitution here)
	find "$R" -type f -print0 > "$WORK/files.lst"
	while IFS= read -r -d '' f; do
		head -c4 "$f" | grep -q '^.ELF' || continue
		for l in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(lib[^.]*\)\.so.*\]/\1/p'); do
			case $l in libroot|libbe|libnetwork|libbsd|libgnu) continue ;; esac
			[ -n "$(find "$R" -name "$l.so*" -print -quit)" ] && continue
			req+=("lib:$l")
		done
	done < "$WORK/files.lst"
	for l in "$@"; do lics+=" \"$l\""; done
	{
		printf 'name\t\t\t%s\nversion\t\t\t%s-'"$REV"'\narchitecture\tarm64\n' "$name" "$ver"
		printf 'summary\t\t\t"%s"\ndescription\t\t"%s, built natively for Haiku arm64 (runtime and development files)."\n' "$summary" "$summary"
		printf 'packager\t\t"haiku-arm64-bootstrap"\nvendor\t\t\t"haiku-arm64-bootstrap"\n'
		printf 'copyrights\t\t{ "%s" }\nlicenses\t\t{%s }\n' "$copy" "$lics"
		printf 'provides {\n%s\n}\n' "$prov"
		printf 'requires {\n\thaiku\n'
		[ ${#req[@]} -eq 0 ] || printf '\t%s\n' $(printf '%s\n' "${req[@]}" | sort -u)
		printf '}\n'
	} > "$R/.PackageInfo"
	(cd "$R" && command package create -q -z zlib -i .PackageInfo "$OUT/$name-$ver-$REV-arm64.hpkg")
	echo "built $OUT/$name-$ver-$REV-arm64.hpkg"
}

build_libpng16() {
	unpack libpng16
	cmake_build libpng16 -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=ON
	tidy
	package libpng16 1.6.53 "PNG reference library" \
		"1995-2025 The PNG Reference Library Authors" "LibPNG"
}

build_libjpeg_turbo() {
	unpack libjpeg_turbo
	cmake_build libjpeg_turbo -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=ON
	tidy
	# a license that isn't one of Haiku's stock ones must ship its text
	mkdir -p "$R/data/licenses"
	cp README.ijg "$R/data/licenses/IJG"
	package libjpeg_turbo 3.1.4.1 "JPEG image codec with SIMD acceleration" \
		"1991-2025 The libjpeg-turbo Project, Thomas G. Lane, Guido Vollbeding" \
		"BSD (3-clause)" "IJG"
}

build_libwebp() {
	unpack libwebp
	cmake_build libwebp -DBUILD_SHARED_LIBS=ON -DWEBP_BUILD_ANIM_UTILS=OFF \
		-DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
		-DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
		-DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
	tidy
	package libwebp 1.6.0 "WebP image codec library" "2010-2025 Google Inc." \
		"BSD (3-clause)"
}

for p in ${@:-libpng16 libjpeg_turbo libwebp}; do
	echo "== $p"
	"build_$p"
done
