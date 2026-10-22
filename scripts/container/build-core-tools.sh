#!/bin/bash
# Cross-build Haiku arm64 packages for command-line tools the arm64 HaikuPorts
# bootstrap set lacks: xz_utils, zstd, gzip, diffutils, patch, tar, pkgconf.
# Flags, patches and file layout follow the HaikuPorts recipes (checkout in
# /build/haikuports; patchsets copied to patches/haikuports/). Each tool is a
# single package (runtime + devel files), zlib-compressed because the arm64
# packagefs cannot read zstd. Feed them to make-package-repo.sh.
#
# Needs build-cross-tools.sh and build-tls.sh (zlib in the sysroot). Output:
# /repo/out/packages/<name>-<version>-1-arm64.hpkg
set -euxo pipefail

X=/build/haiku/generated.arm64/cross-tools-arm64
export PATH=$X/bin:$PATH
SR=$X/sysroot
H=aarch64-unknown-haiku
HP=/build/haikuports
PATCHES=/repo/patches/haikuports
SRC=/build/core
OUT=/repo/out/packages
J=-j"$(nproc)"
REV=1
S=/boot/system

pkgtool() {
	LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib \
		/build/haiku/generated/objects/linux/arm64/release/tools/package/package "$@"
}

declare -A SHA=(
	[diffutils-3.12.tar.xz]=7c8b7f9fc8609141fdea9cece85249d308624391ff61dedaf528fcb337727dfd
	[patch-2.8.tar.xz]=f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3
	[tar-1.35.tar.xz]=4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16
	[xz-5.8.4.tar.xz]=4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
	[zstd-1.5.7.tar.gz]=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
	[pkgconf-3.0.10.tar.xz]=9371b2f6372da574d4c6dc96fe9b1463037bcf6afcb6671c1555afde7b17e2de
	[gzip-1.15.tar.xz]=9aa0cc780dec156b8282844833b342ab7cb08c25d2cd9a1869cdd0df31deff48
)
declare -A URL=(
	[diffutils-3.12.tar.xz]=https://ftp.gnu.org/gnu/diffutils
	[patch-2.8.tar.xz]=https://ftp.gnu.org/gnu/patch
	[tar-1.35.tar.xz]=https://ftp.gnu.org/gnu/tar
	[xz-5.8.4.tar.xz]=https://github.com/tukaani-project/xz/releases/download/v5.8.4
	[zstd-1.5.7.tar.gz]=https://github.com/facebook/zstd/releases/download/v1.5.7
	[pkgconf-3.0.10.tar.xz]=https://distfiles.ariadne.space/pkgconf
	[gzip-1.15.tar.xz]=https://ftp.gnu.org/gnu/gzip
)

# unpack <tarball>: fresh source tree in $SRC/build, cwd set to it
unpack() {
	cd $SRC
	[ -f "$1" ] || wget -q "${URL[$1]}/$1"
	echo "${SHA[$1]}  $1" | sha256sum -c -
	rm -rf "$SRC/build/${1%.tar.*}" && mkdir -p "$SRC/build"
	tar xf "$1" -C "$SRC/build"
	cd "$SRC/build/${1%.tar.*}"
}

# HaikuPorts' runConfigure directory set for the system package location
haiku_configure() {
	local name=$1; shift
	./configure --host=$H --build="$(uname -m)-unknown-linux-gnu" \
		--prefix=$S --exec-prefix=$S --bindir=$S/bin --sbindir=$S/bin \
		--libdir=$S/lib --libexecdir=$S/lib --includedir=$S/develop/headers \
		--datarootdir=$S/data --datadir=$S/data --sysconfdir=$S/settings \
		--localstatedir=$S/var --sharedstatedir=$S/var/com \
		--mandir=$S/documentation/man --infodir=$S/documentation/info \
		--docdir=$S/documentation/packages/$name "$@"
}

# dest <name>: clean DESTDIR for a package; prints the package root
dest() {
	rm -rf "$SRC/dest/$1" && mkdir -p "$SRC/dest/$1"
	echo "$SRC/dest/$1"
}

# tidy <root>: Haiku layout fixes (HaikuPorts prepareInstalledDevelLib,
# fixPkgconfig), drop libtool/charset/info-dir files, strip ELF files
tidy() {
	local r=$1 f so
	rm -f "$r"/lib/*.la "$r"/lib/charset.alias "$r"/documentation/info/dir
	for f in "$r"/lib/lib*.so; do
		[ -L "$f" ] || continue
		so=$($H-readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		mkdir -p "$r/develop/lib"
		rm "$f" && ln -s "../../lib/$so" "$r/develop/lib/${f##*/}"
	done
	if [ -d "$r/lib/pkgconfig" ]; then
		mkdir -p "$r/develop/lib/pkgconfig"
		mv "$r"/lib/pkgconfig/*.pc "$r/develop/lib/pkgconfig/"
		rmdir "$r/lib/pkgconfig"
		sed -i "s|^libdir=.*|libdir=$S/develop/lib|" "$r"/develop/lib/pkgconfig/*.pc
	fi
	find "$r" -type f -exec sh -c \
		'head -c4 "$1" | grep -q "^.ELF" && '$H'-strip --strip-unneeded "$1"' _ {} \;
	rmdir "$r"/lib 2>/dev/null || true
}

# package <root> <name> <version> <summary> <description> <copyright> <licenses...>
# provides: <name>, cmd: per bin/ entry, lib:/devel: per shared library (at
# the library's own version, e.g. libpkgconf.so.7.0.0 -> 7.0.0 compat >= 7).
# requires: haiku, plus lib: for every NEEDED library from another package.
package() {
	local r=$1 name=$2 ver=$3 summary=$4 desc=$5 copy=$6; shift 6
	local f b so lib libver prov req=() l
	prov="	$name = $ver compat >= ${ver%%.*}"
	for f in "$r"/bin/*; do
		[ -e "$f" ] || continue
		b=${f##*/}
		prov+=$'\n'"	cmd:${b//-/_} = $ver compat >= ${ver%%.*}"
	done
	for f in "$r"/lib/lib*.so.*; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		so=$($H-readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		lib=${so%%.so*}; libver=${f##*.so.}
		prov+=$'\n'"	lib:$lib = $libver compat >= ${so##*.so.}"
		[ -e "$r/develop/lib/$lib.so" ] && prov+=$'\n'"	devel:$lib = $libver compat >= ${so##*.so.}"
	done
	for f in $(find "$r" -type f); do
		head -c4 "$f" | grep -q '^.ELF' || continue
		for l in $($H-readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(lib[^.]*\)\.so.*\]/\1/p'); do
			case $l in libroot|libbe|libnetwork|libbnetapi|libbsd|libgnu) continue ;; # haiku
			esac
			compgen -G "$r/lib/$l.so.*" >/dev/null && continue # this package
			req+=("lib:$l")
		done
	done
	local licenses=""
	for l in "$@"; do licenses+=" \"$l\""; done
	{
		printf 'name\t\t\t%s\nversion\t\t\t%s-%s\narchitecture\tarm64\n' "$name" "$ver" $REV
		printf 'summary\t\t\t"%s"\ndescription\t\t"%s"\n' "$summary" "$desc"
		printf 'packager\t\t"haiku-arm64-bootstrap"\nvendor\t\t\t"haiku-arm64-bootstrap"\n'
		printf 'copyrights\t\t{ "%s" }\nlicenses\t\t{%s }\n' "$copy" "$licenses"
		printf 'provides {\n%s\n}\n' "$prov"
		printf 'requires {\n\thaiku\n'
		[ ${#req[@]} -eq 0 ] || printf '\t%s\n' $(printf '%s\n' "${req[@]}" | sort -u)
		printf '}\n'
	} > "$r/.PackageInfo"
	cat "$r/.PackageInfo"
	(cd "$r" && pkgtool create -q -z zlib -i .PackageInfo "$OUT/$name-$ver-$REV-arm64.hpkg")
}

mkdir -p $SRC $OUT

# --- xz_utils 5.8.4 (first: zstd links liblzma) ---
unpack xz-5.8.4.tar.xz
haiku_configure xz_utils --disable-rpath --disable-static --disable-nls
make $J >/dev/null
R=$(dest xz_utils)
make install DESTDIR=$R >/dev/null
R=$R$S
mkdir -p $R/data/expander/rules $R/data/licenses
cp $HP/app-arch/xz_utils/additional-files/xz_utils-expander-rules $R/data/expander/rules/xz_utils
cp COPYING.0BSD "$R/data/licenses/BSD (0-clause)"
tidy $R
# the cross linker searches develop/lib, so install the tidied layout
cp -a $R/lib $R/develop $SR/boot/system/
package $R xz_utils 5.8.4 "Free general-purpose data compression software" \
	"XZ Utils are free general-purpose data compression tools with a high compression ratio. They are the successors to LZMA Utils." \
	"2005-2025 Lasse Collin and the XZ Utils contributors" "BSD (0-clause)" "GNU GPL v2"

# --- zstd 1.5.7 ---
unpack zstd-1.5.7.tar.gz
patch -p1 < $PATCHES/zstd-1.5.7.patchset
ZMAKE=(UNAME=Haiku CC=$H-gcc CXX=$H-g++ AR=$H-ar
	prefix=$S includedir=$S/develop/headers libdir=$S/lib bindir=$S/bin
	mandir=$S/documentation/man HAVE_THREAD=1 HAVE_ZLIB=1 HAVE_LZ4=0 HAVE_LZMA=1)
make $J "${ZMAKE[@]}" >/dev/null
R=$(dest zstd)
make "${ZMAKE[@]}" install DESTDIR=$R >/dev/null
R=$R$S
rm -f $R/lib/libzstd.a
mkdir -p $R/documentation/packages/zstd
cp LICENSE COPYING doc/zstd_manual.html $R/documentation/packages/zstd/
tidy $R
package $R zstd 1.5.7 "Zstandard, a fast real-time compression algorithm" \
	"Zstd, short for Zstandard, is a fast lossless compression algorithm, targeting real-time compression scenarios at zlib-level and better compression ratios. Includes libzstd and the zstd command line tools." \
	"2016-2025 Meta Platforms, Inc. and affiliates" "BSD (3-clause)" "GNU GPL v2"

# --- gzip 1.15 (tar -z) ---
unpack gzip-1.15.tar.xz
haiku_configure gzip AUTOCONF=: AUTOMAKE=: CFLAGS="-O2 -Wno-error"
make $J >/dev/null
R=$(dest gzip)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R gzip 1.15 "The GNU data compression program" \
	"gzip reduces the size of files using Lempel-Ziv coding (LZ77). Includes gunzip, zcat, zgrep, zless and friends." \
	"1992-1993 Jean-loup Gailly; 1999-2025 Free Software Foundation, Inc." "GNU GPL v3"

# --- diffutils 3.12 (negative-errno mapper, as in the recipe) ---
unpack diffutils-3.12.tar.xz
# gnulib's strcasecmp check is a run test, which a cross build can't run
haiku_configure diffutils --disable-gcc-warnings --disable-nls \
	CFLAGS="-O2 -DB_USE_POSITIVE_POSIX_ERRORS" LDFLAGS="-lposix_error_mapper" \
	gl_cv_func_strcasecmp_works=yes
make $J >/dev/null
R=$(dest diffutils)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R diffutils 3.12 "Several programs for finding differences between files" \
	"diff, cmp, diff3 and sdiff: show differences between files line by line in several formats, or merge them." \
	"1992-2025 Free Software Foundation, Inc." "GNU GPL v3"

# --- patch 2.8 ---
unpack patch-2.8.tar.xz
haiku_configure patch --disable-nls
make $J >/dev/null
R=$(dest patch)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R patch 2.8 "Utility to apply diffs to files" \
	"Patch takes a patch file containing a difference listing produced by the diff program and applies those differences to one or more original files, producing patched versions." \
	"1984-2025 Free Software Foundation, Inc." "GNU GPL v3"

# --- tar 1.35 (HaikuPorts patchset: --replace-hardlinks) ---
unpack tar-1.35.tar.xz
patch -p1 < $PATCHES/tar-1.35.patchset
haiku_configure tar --disable-nls --disable-gcc-warnings \
	LDFLAGS="-lnetwork" CFLAGS="-O2 -D_BSD_SOURCE" FORCE_UNSAFE_CONFIGURE=1
make $J YACC=: >/dev/null
R=$(dest tar)
make install DESTDIR=$R YACC=: >/dev/null
R=$R$S
tidy $R
package $R tar 1.35 "Saves and restores files to/from a tape or disk archive" \
	"GNU tar creates and manipulates tar archives, and extracts files from them. Compressed archives (-z, -J, --zstd) use the gzip, xz and zstd commands." \
	"1985-2025 Free Software Foundation, Inc." "GNU GPL v3"

# --- pkgconf 3.0.10 (finds .pc files via find_paths(B_FIND_PATH_DEVELOP_LIB_DIRECTORY)) ---
unpack pkgconf-3.0.10.tar.xz
haiku_configure pkgconf --disable-static \
	--with-system-libdir=$S/develop/lib --with-system-includedir=$S/develop/headers
make $J >/dev/null
R=$(dest pkgconf)
make install DESTDIR=$R >/dev/null
R=$R$S
ln -s pkgconf $R/bin/pkg-config
ln -s pkgconf.1 $R/documentation/man/man1/pkg-config.1
tidy $R
package $R pkgconf 3.0.10 "A lightweight pkg-config replacement" \
	"pkgconf (and pkg-config) report compiler and linker flags for development libraries from their .pc files." \
	"2011-2025 pkgconf authors" "ISC"

ls -la $OUT
