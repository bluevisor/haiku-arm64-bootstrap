#!/bin/bash
# Cross-build the second tier of Haiku arm64 packages: bzip2, zip, unzip, nano,
# libiconv, ninja, cmake. Same rules as build-core-tools.sh (HaikuPorts flags and
# patchsets, one package per tool, helpers in hpkg-common.sh). Sources are
# checked against the HaikuPorts recipes' CHECKSUM_SHA256.
# ONLY="ninja cmake" rebuilds just those (bzip2 must have run once: unzip
# links the sysroot's libbz2).
#
# Needs build-cross-tools.sh, build-tls.sh (OpenSSL for cmake's HTTPS) and the
# ncurses6/ncurses6_devel bootstrap packages in the sysroot (build-python.sh).
# Output: /repo/out/packages/<name>-<version>-1-arm64.hpkg
set -euxo pipefail

declare -A SHA=(
	[bzip2-1.0.8.tar.gz]=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269
	[zip30.tar.gz]=f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369
	[unzip610c23.zip]=a9c3f0b4377aa593a77574e2fb69aeab97e66e93d8b110797f7b329e09848b62
	[nano-9.1.tar.xz]=5f47764274cb7532349ce0aa20ec10f1e8e851a6e9fa3eb66812c43d196db042
	[ninja-1.13.2.tar.gz]=974d6b2f4eeefa25625d34da3cb36bdcebe7fbce40f4c16ac0835fd1c0cbae17
	[cmake-4.4.4.tar.gz]=bd24c30d80a7744ae84b845ff080cc8453b06c622ef01066564108e9cefc44cf
	[libiconv-1.18.tar.gz]=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8
)
declare -A URL=(
	[bzip2-1.0.8.tar.gz]=https://sourceware.org/pub/bzip2
	# SourceForge stalls; Debian's zip_3.0.orig.tar.gz is the same file
	[zip30.tar.gz]=http://deb.debian.org/debian/pool/main/z/zip
	[unzip610c23.zip]=http://antinode.info/ftp/info-zip
	[nano-9.1.tar.xz]=https://www.nano-editor.org/dist/v9
	[ninja-1.13.2.tar.gz]=https://github.com/ninja-build/ninja/archive
	[cmake-4.4.4.tar.gz]=https://cmake.org/files/v4.4
	[libiconv-1.18.tar.gz]=https://ftp.gnu.org/gnu/libiconv
)

source "$(dirname "$0")/hpkg-common.sh"

want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

cd $SRC
[ -f zip30.tar.gz ] || wget -q -T 60 -O zip30.tar.gz ${URL[zip30.tar.gz]}/zip_3.0.orig.tar.gz
[ -f ninja-1.13.2.tar.gz ] || wget -q -T 60 -O ninja-1.13.2.tar.gz ${URL[ninja-1.13.2.tar.gz]}/v1.13.2.tar.gz

# --- bzip2 1.0.8 (first: unzip links libbz2) ---
if want bzip2; then
unpack bzip2-1.0.8.tar.gz
patch -p1 < $PATCHES/bzip2-1.0.8.patchset
BZ=(CC=$H-gcc AR=$H-ar RANLIB=$H-ranlib)
# not `all`: it runs the test suite with the freshly built (Haiku) binary
make $J "${BZ[@]}" libbz2.a bzip2 bzip2recover >/dev/null
make $J "${BZ[@]}" -f Makefile-libbz2_so >/dev/null
R=$(dest bzip2)
make "${BZ[@]}" install PREFIX=$R$S BINDIR=$R$S/bin LIBDIR=$R$S/lib \
	INCLUDEDIR=$R$S/develop/headers MANDIR=$R$S/documentation/man/man1 >/dev/null
R=$R$S
ln -sf libbz2.so.1.0.8 libbz2.so
cp -a libbz2.so.1.0.8 libbz2.so.1.0 libbz2.so $R/lib/
rm -f $R/lib/*.a
rm -rf $R/documentation/man/man1/man
mkdir -p $R/data/licenses
cp LICENSE $R/data/licenses/bzip2
tidy $R
to_sysroot $R
package $R bzip2 1.0.8 "A high-quality data compressor" \
	"bzip2 compresses files using the Burrows-Wheeler block sorting text compression algorithm and Huffman coding. Includes libbz2, bzcat, bzgrep, bzdiff and bzmore." \
	"1996-2019 Julian R Seward" "bzip2"
fi

# --- zip 3.0 (Info-ZIP; HaikuPorts patchset stores BFS attributes) ---
if want zip; then
unpack zip30.tar.gz
patch -p1 < $PATCHES/zip-3.0.patchset
# unix/configure runs two ./conftest programs, which can't run here. Both
# answers are known for Haiku: 32-bit uid/gid (-DUIDGID_NOT_16BIT, what a
# failed run picks anyway) and 64-bit off_t (-DLARGE_FILE_SUPPORT, added here).
sh unix/configure "$H-gcc" "-I. -DUNIX"
# flags is a single line of VAR="..." words; it also picks up the sysroot's
# libbz2 (LFLAGS2=" -lbz2"), so edit in place rather than append
grep -q LARGE_FILE_SUPPORT flags || sed -i 's/ CFLAGS="/ CFLAGS="-DLARGE_FILE_SUPPORT /' flags
sed -i 's/ LFLAGS2="/ LFLAGS2="-lbe /' flags
grep -q -- '-DLARGE_FILE_SUPPORT' flags && grep -q 'LFLAGS2="-lbe' flags
cat flags
make -f unix/Makefile generic >/dev/null
R=$(dest zip)
make -f unix/Makefile install PREFIX=$R$S BINDIR=$R$S/bin \
	MANDIR=$R$S/documentation/man/man1 >/dev/null
R=$R$S
mkdir -p $R/data/licenses
cp LICENSE $R/data/licenses/Info-ZIP
tidy $R
package $R zip 3.0 "Info-ZIP's zip archiver" \
	"zip creates and updates .zip archives, storing Haiku file attributes. Includes zipcloak, zipnote and zipsplit." \
	"1990-2008 Info-ZIP" "Info-ZIP"
fi

# --- unzip 6.10c23 (Info-ZIP beta that HaikuPorts ships; patched for attributes) ---
if want unzip; then
unpack unzip610c23.zip
patch -p1 < $PATCHES/unzip-6.10c23.patchset
# the recipe's `haiku` target with CC=cc replaced, and without
# -DICONV_MAPPING/-liconv: there is no libiconv for arm64. ICONV_MAPPING was
# also what pulled in <locale.h> (else `LC_CTYPE undeclared`), hence HAVE_*_H.
UZCFLAGS="-O2 -DLARGE_FILE_SUPPORT -DUNICODE_SUPPORT -DUNICODE_WCHAR \
	-DUTF8_MAYBE_NATIVE -DNO_LCHMOD -DHAVE_DIRENT_H -DHAVE_TERMIOS_H -D_MBCS \
	-DNO_SYSDIR -DBZIP2_SUPPORT -DHAVE_LOCALE_H -DHAVE_LANGINFO_H"
make -f unix/Makefile unix_make >/dev/null
make -f unix/Makefile MU CC=$H-gcc CFLAGS="$UZCFLAGS" CRCA_O="" AS="$H-gcc -c" \
	LF2="-lbe -lbz2" CC_BZ=$H-gcc CFLAGS_BZ="-O2" LN="ln -s" >/dev/null
R=$(dest unzip)
make -f unix/Makefile install PREFIX=$R$S MANDIR=$R$S/documentation/man LN="ln -s" >/dev/null
R=$R$S
mkdir -p $R/data/licenses
cp LICENSE $R/data/licenses/Info-ZIP
tidy $R
package $R unzip 6.10c23 "Info-ZIP's unzip extractor" \
	"unzip lists, tests and extracts .zip archives, restoring Haiku file attributes. Includes funzip, unzipsfx, zipinfo and zipgrep. bzip2-compressed entries supported." \
	"1990-2017 Info-ZIP" "Info-ZIP"
fi

# --- nano 9.1 ---
if want nano; then
unpack nano-9.1.tar.xz
haiku_configure nano --disable-nls
make $J >/dev/null
R=$(dest nano)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R nano 9.1 "A small and friendly text editor" \
	"GNU nano is a small text editor for the terminal, with syntax highlighting, undo/redo, search and replace, and an on-screen list of shortcuts." \
	"1999-2026 Free Software Foundation, Inc." "GNU GPL v3"
fi

# --- ninja 1.13.2 (CMake build: configure.py has no Haiku platform) ---
if want ninja; then
unpack ninja-1.13.2.tar.gz
patch -p1 < $PATCHES/ninja-1.13.2.patchset
# the patchset enables getloadavg(), which Haiku has in libbsd
cmake -S . -B build-haiku -G Ninja -DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN \
	-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCMAKE_INSTALL_PREFIX=$S \
	-DCMAKE_CXX_STANDARD_LIBRARIES=-lbsd >/dev/null
cmake --build build-haiku $J >/dev/null
R=$(dest ninja)
DESTDIR=$R cmake --install build-haiku >/dev/null
R=$R$S
tidy $R
package $R ninja 1.13.2 "A small build system with a focus on speed" \
	"Ninja is a small build system designed to run builds as fast as possible, usually driven by build files generated by CMake or Meson." \
	"2012-2025 Google Inc." "Apache v2"
fi

# --- libiconv 1.18 (Haiku's libroot has no iconv; cmake's libarchive requires
# it). The HaikuPorts patchset only has gcc2 fixes, so it isn't applied. ---
if want libiconv; then
unpack libiconv-1.18.tar.gz
haiku_configure libiconv --enable-relocatable --enable-shared --disable-static \
	--disable-nls --enable-extra-encodings
make $J >/dev/null
R=$(dest libiconv)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
to_sysroot $R
package $R libiconv 1.18 "GNU character set conversion library" \
	"libiconv converts text between character encodings (iconv_open/iconv), with the iconv command line tool. Haiku's libroot has no iconv." \
	"2000-2024 Free Software Foundation, Inc." "GNU LGPL v2.1" "GNU GPL v3"
fi

# --- cmake 4.4.4 (HaikuPorts patchset; bundled third-party libs, OpenSSL for HTTPS) ---
if want cmake; then
unpack cmake-4.4.4.tar.gz
patch -p1 < $PATCHES/cmake-4.4.4.patchset
# bundled libuv has haiku.c but no Haiku block in its CMakeLists (HaikuPorts
# uses a system libuv), so link fails with `undefined reference to uv__hrtime`
patch -p1 < /repo/patches/cmake-4.4.4-cmlibuv-haiku.patch
# CA bundle: CMake's trimmed curl has no CURL_CA_BUNDLE/CURL_CA_FALLBACK, and
# cmCurl.cxx only probes Linux paths, so https downloads fail with curl error
# 60. Add Haiku's CARootCertificates.pem locations to that probe list.
patch -p1 < /repo/patches/cmake-4.4.4-haiku-cafile.patch
cmake -S . -B build-haiku -G Ninja -DCMAKE_TOOLCHAIN_FILE=$TOOLCHAIN \
	-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$S \
	-DCMAKE_DATA_DIR=data/cmake -DCMAKE_DOC_DIR=documentation/packages/cmake \
	-DCMAKE_MAN_DIR=documentation/man -DCMAKE_XDGDATA_DIR=data \
	-DBUILD_TESTING=OFF -DBUILD_CursesDialog=OFF -DBUILD_QtDialog=OFF \
	-DCMAKE_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR=$S/non-packaged \
	`# cmcurl uses HAVE_LIBNETWORK to put -lnetwork into its feature checks but` \
	`# never tests for it, so socket() etc. look missing ("cannot compile` \
	`# without socket() support"). HaikuPorts dodges this with a system curl.` \
	-DHAVE_LIBNETWORK=1 \
	-DCMAKE_EXE_LINKER_FLAGS=-lbsd -DCMAKE_SHARED_LINKER_FLAGS=-lbsd \
	${CMAKE_EXTRA:-}
cmake --build build-haiku $J >/dev/null
R=$(dest cmake)
DESTDIR=$R cmake --install build-haiku >/dev/null
R=$R$S
mkdir -p $R/data/licenses
cp LICENSE.rst $R/data/licenses/CMake
tidy $R
package $R cmake 4.4.4 "Cross platform Make" \
	"CMake generates native build files (Makefiles, Ninja) from platform-independent CMakeLists.txt files. Includes ctest and cpack." \
	"2002-2026 Kitware, Inc., Insight Consortium" "CMake"
fi

ls -la $OUT
