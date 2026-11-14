#!/bin/bash
# Build libedit (the portable NetBSD editline, https://thrysoee.dk/editline/)
# as a static, position independent library for Haiku arm64. libedit is not
# packaged for Haiku arm64, so the Debugger's command line interface links it
# statically; jam finds it through HAIKU_LIBEDIT_DIR.
#
# libedit needs termcap functions (tgetent, tputs, ...). They come from the
# ncurses6 build package the Haiku build already extracted; a consumer of
# libedit.a must also link libncurses from there (see NCURSES below).
#
# Runs in the haiku-tools container (needs the cross compiler from the
# Haiku build in /build/haiku/generated.arm64, which it only reads). Output:
#   /build/deps/libedit-arm64/include/histedit.h
#   /build/deps/libedit-arm64/include/editline/readline.h
#   /build/deps/libedit-arm64/lib/libedit.a
set -euo pipefail

VERSION=${LIBEDIT_VERSION:-20260512-3.1}
SHA256=432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0
CROSS=${CROSS:-/build/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku}
NCURSES=${NCURSES:-$(ls -d /build/haiku/generated.arm64/build_packages/ncurses6-*-arm64 | tail -1)}
SRCDIR=/build/deps/libedit-src
OUT=${HAIKU_LIBEDIT_DIR:-/build/deps/libedit-arm64}

[ -f "$NCURSES/develop/headers/termcap.h" ] || {
	echo "ncurses6 build package not found under $NCURSES" >&2; exit 1; }

mkdir -p "$SRCDIR"
cd "$SRCDIR"
if [ ! -f "libedit-$VERSION.tar.gz" ]; then
	curl -sSfL -o "libedit-$VERSION.tar.gz" \
		"https://thrysoee.dk/editline/libedit-$VERSION.tar.gz"
fi
echo "$SHA256  libedit-$VERSION.tar.gz" | sha256sum -c -
rm -rf "libedit-$VERSION" && tar xzf "libedit-$VERSION.tar.gz"
cd "libedit-$VERSION"

# Haiku has no <sys/ttydefaults.h>; readline.h only includes it for CTRL(),
# which it defines itself when missing. Skip the include on Haiku, as libedit
# already does for Solaris/HP-UX/AIX (this also fixes the installed header).
sed -i 's/#if !defined(__sun) && !defined(__hpux) && !defined(_AIX)$/& \&\& !defined(__HAIKU__)/' \
	src/editline/readline.h
grep -q '!defined(_AIX) && !defined(__HAIKU__)' src/editline/readline.h

# Cross compiling: configure cannot run test programs, so answer the
# malloc(0)/realloc(0) checks (Haiku's libroot returns non-NULL for both).
rm -rf build && mkdir build && cd build
../configure \
	--host=aarch64-unknown-haiku \
	--prefix="$OUT" \
	--disable-shared --enable-static --disable-examples \
	CC="$CROSS-gcc" AR="$CROSS-ar" RANLIB="$CROSS-ranlib" \
	CFLAGS="-O2 -fPIC" \
	CPPFLAGS="-I$NCURSES/develop/headers" \
	LDFLAGS="-L$NCURSES/develop/lib" \
	ac_cv_func_malloc_0_nonnull=yes \
	ac_cv_func_realloc_0_nonnull=yes

make -j"$(nproc)"

rm -rf "$OUT"
make install
# Only the static library and headers are wanted; drop libtool/pkgconfig/man.
rm -rf "$OUT/share" "$OUT/lib/pkgconfig" "$OUT/lib/libedit.la"
cp ../COPYING "$OUT/COPYING"
ls -la "$OUT/lib/libedit.a"
find "$OUT/include" -type f
