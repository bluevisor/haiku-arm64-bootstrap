#!/bin/bash
# Cross-build OpenSSL, curl (with HTTPS) and git for Haiku arm64.
# Runs inside the build container with this repo at /repo (see build-bfs-shell.sh);
# needs build-cross-tools.sh first. Output: /repo/out/tls.
set -euxo pipefail

X=/build/haiku/generated.arm64/cross-tools-arm64
export PATH=$X/bin:$PATH
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
STAGE=/repo/out/tls
PKG=/build/haiku/generated/objects/linux/arm64/release/tools/package/package
export PKG_CONFIG=/bin/false
J=-j"$(nproc)"
mkdir -p /build/tls && cd /build/tls
[ -f openssl-3.5.9.tar.gz ] || wget -q https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
[ -f curl-8.23.0.tar.bz2 ] || wget -q https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.bz2
[ -f git-2.56.0.tar.xz ] || wget -q https://www.kernel.org/pub/software/scm/git/git-2.56.0.tar.xz
[ -f nghttp2-1.63.0.tar.xz ] || wget -q https://github.com/nghttp2/nghttp2/releases/download/v1.63.0/nghttp2-1.63.0.tar.xz

# zlib headers + library for linking (runtime zlib is already on the guest)
for p in zlib_devel-1.2.13_bootstrap-1 zlib-1.2.13_bootstrap-1; do
	[ -f $p.hpkg ] || wget -q -O $p.hpkg https://eu.hpkg.haiku-os.org/haikuports/master/build-packages/packages/$p-arm64.hpkg
	LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib $PKG extract -C $SR/boot/system $p.hpkg
done
rm -rf $STAGE && mkdir -p $STAGE

# --- OpenSSL 3.5.9 (no-asm, as HaikuPorts does on non-x86_64) ---
rm -rf openssl-3.5.9 && tar xzf openssl-3.5.9.tar.gz && cd openssl-3.5.9
cat > Configurations/60-haiku-aarch64.conf <<'EOF'
my %targets = (
    "haiku-aarch64" => {
        inherit_from     => [ "haiku-common" ],
        bn_ops           => "SIXTY_FOUR_BIT_LONG",
    },
);
EOF
CC=gcc ./Configure haiku-aarch64 no-asm shared no-tests no-docs \
	--cross-compile-prefix=aarch64-unknown-haiku- \
	--prefix=/boot/system/non-packaged --libdir=lib \
	--openssldir=/boot/system/non-packaged/data/ssl
make $J >/dev/null
make install_sw DESTDIR=$STAGE >/dev/null
make install_sw DESTDIR=$SR >/dev/null
cd ..

# --- nghttp2 1.63.0 (lib only): HTTP/2 for curl. cargo enables curl's http2
# feature and otherwise compiles its own static curl. ---
rm -rf nghttp2-1.63.0 && tar xJf nghttp2-1.63.0.tar.xz && cd nghttp2-1.63.0
./configure --host=aarch64-unknown-haiku --prefix=/boot/system/non-packaged \
	--enable-lib-only --disable-static >/dev/null
make $J >/dev/null
make install DESTDIR=$STAGE >/dev/null
make install DESTDIR=$SR >/dev/null
cd ..

# --- curl 8.23.0 with OpenSSL + HTTP/2 ---
rm -rf curl-8.23.0 && tar xjf curl-8.23.0.tar.bz2 && cd curl-8.23.0
patch -p1 < /repo/patches/haikuports/curl-8.23.0.patchset
CPPFLAGS="-D_BSD_SOURCE" ac_cv_func_accept4=no ./configure --host=aarch64-unknown-haiku \
	--prefix=/boot/system/non-packaged \
	--with-openssl=$NP --with-zlib --with-nghttp2=$NP \
	--with-ca-bundle=/boot/system/non-packaged/data/ssl/CARootCertificates.pem \
	--without-libpsl --without-libssh2 --without-brotli \
	--without-zstd --without-libidn2 \
	--enable-ipv6 --enable-websockets --disable-static --disable-manual >/dev/null
make $J >/dev/null
make install DESTDIR=$STAGE >/dev/null
make install DESTDIR=$SR >/dev/null
cd ..

# --- git 2.56.0 ---
rm -rf git-2.56.0 && tar xJf git-2.56.0.tar.xz && cd git-2.56.0
patch -p1 < /repo/patches/haikuports/git-2.56.0.patchset
GITFLAGS=(
	CC=aarch64-unknown-haiku-gcc AR=aarch64-unknown-haiku-ar
	uname_S=Haiku uname_O=Haiku uname_M=arm64 uname_P=arm64 uname_R=1 uname_V=1
	prefix=/boot/system/non-packaged gitexecdir=/boot/system/non-packaged/lib/git-core
	sysconfdir=/boot/system/settings
	CURLDIR=$NP CURL_CONFIG=/bin/false CURL_LDFLAGS="-L$NP/lib -lcurl"
	OPENSSLDIR=$NP
	NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease
	NO_EXPAT=YesPlease NO_ICONV=YesPlease NO_RUST=YesPlease
	SKIP_DASHED_BUILT_INS=YesPlease
	PTHREAD_LIBS= NO_D_TYPE_IN_DIRENT=YesPlease NO_MEMMEM=YesPlease
	OBJECT_CREATION_USES_RENAMES=YesPlease NO_CROSS_DIRECTORY_HARDLINKS=YesPlease
	NO_INSTALL_HARDLINKS=YesPlease HAVE_DEV_TTY=YesPlease DEFAULT_HELP_FORMAT=web
	BASIC_LDFLAGS="-lnetwork -lbsd" CPPFLAGS="-D_POSIX_THREAD_SAFE_FUNCTIONS"
)
make $J "${GITFLAGS[@]}" all >/dev/null
make "${GITFLAGS[@]}" install DESTDIR=$STAGE >/dev/null
cd ..

# strip, drop docs/man/static libs we don't ship
find $STAGE -type f -perm -u+x -exec sh -c 'file "$1" | grep -q ELF && aarch64-unknown-haiku-strip "$1"' _ {} \;
rm -rf $STAGE/boot/system/non-packaged/share/man $STAGE/boot/system/non-packaged/share/doc
find $STAGE \( -name '*.a' -o -name '*.la' \) -delete
echo "== staged:"; du -sh $STAGE; find $STAGE -type l | wc -l | sed 's/^/symlinks: /'
ls $STAGE/boot/system/non-packaged/bin $STAGE/boot/system/non-packaged/lib
