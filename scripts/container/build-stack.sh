#!/bin/bash
# Package the stack that guide steps 5-9 installed by hand into non-packaged:
# ca_root_certificates, openssl3, nghttp2, curl, git, openssh, sqlite and
# python3.12 (now with _bz2, _lzma and _sqlite3). Perl is built on the guest
# (scripts/guest/build-perl-native.sh PKG=1) and packaged by package-perl.sh.
#
# Everything moves to the HaikuPorts layout under /boot/system: OPENSSLDIR is
# /boot/system/data/ssl, and the CA bundle is data/ssl/CARootCertificates.pem
# from ca_root_certificates (OpenSSL's default file there, with the HaikuPorts
# patchset). openssh creates its `sshd` privsep user on install like the
# HaikuPorts package, so no account name is compiled in.
# ONLY="curl git" rebuilds a subset, in this order (later ones link earlier ones).
#
# Needs build-cross-tools.sh, build-python.sh (host python, libffi/ncurses/
# expat in the sysroot) and build-dev-tools.sh (bzip2, libiconv in the
# sysroot); xz from build-core-tools.sh. Output: /repo/out/packages
set -euxo pipefail

declare -A SHA=(
	[openssl-3.5.9.tar.gz]=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
	[nghttp2-1.63.0.tar.xz]=4879c75dd32a74421b9857924449460b8341796c0613ba114ab2188e4622354b
	[curl-8.23.0.tar.bz2]=95b22eb32bf6d1fa6e3e9463bdb61cece3efc56d86576a9b3cbd428246a6d854
	[git-2.56.0.tar.xz]=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3
	[openssh-10.6p1.tar.gz]=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39
	[sqlite-autoconf-3530400.tar.gz]=0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
	[Python-3.12.15.tar.xz]=c2c4321961fab0fb999d66e0cecf521c2ab3994c7992873ea99e306c1094fd5a
	[cacert-2026-10-20.pem]=796f1389bfea13c0ed78f663b765baaff54a508e5483786bd6ece73c5e3e3cbe
)
declare -A URL=(
	[openssl-3.5.9.tar.gz]=https://github.com/openssl/openssl/releases/download/openssl-3.5.9
	[nghttp2-1.63.0.tar.xz]=https://github.com/nghttp2/nghttp2/releases/download/v1.63.0
	[curl-8.23.0.tar.bz2]=https://github.com/curl/curl/releases/download/curl-8_23_0
	[git-2.56.0.tar.xz]=https://www.kernel.org/pub/software/scm/git
	[openssh-10.6p1.tar.gz]=https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable
	[sqlite-autoconf-3530400.tar.gz]=https://www.sqlite.org/2026
	[Python-3.12.15.tar.xz]=https://www.python.org/ftp/python/3.12.15
	[cacert-2026-10-20.pem]=https://curl.se/ca
)

source "$(dirname "$0")/hpkg-common.sh"

want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

# Resolve .pc files from the sysroot, never the build machine's
export PKG_CONFIG_LIBDIR=$SR/boot/system/develop/lib/pkgconfig PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_PATH=
# include/ + lib/ view of the sysroot's develop tree, for configure scripts
# that take --with-foo=PREFIX (the packaged libraries live there, not in non-packaged)
SYSDEV=$SRC/sysdev
mkdir -p $SYSDEV
ln -sfn $SR/boot/system/develop/headers $SYSDEV/include
ln -sfn $SR/boot/system/develop/lib $SYSDEV/lib
CABUNDLE=$S/data/ssl/CARootCertificates.pem

# --- ca_root_certificates 2026_10_20 (curl.se's Mozilla bundle, as HaikuPorts;
# their package is zstd-compressed, which the arm64 packagefs can't read) ---
if want ca_root_certificates; then
cd $SRC && echo "${SHA[cacert-2026-10-20.pem]}  cacert-2026-10-20.pem" | sha256sum -c - \
	|| { wget -q -T 60 ${URL[cacert-2026-10-20.pem]}/cacert-2026-10-20.pem; \
	     echo "${SHA[cacert-2026-10-20.pem]}  cacert-2026-10-20.pem" | sha256sum -c -; }
R=$(dest ca_root_certificates)$S
mkdir -p $R/data/ssl
cp $SRC/cacert-2026-10-20.pem $R/data/ssl/CARootCertificates.pem
ARCH=any package $R ca_root_certificates 2026_10_20 "Bundle of CA root certificates" \
	"Mozilla's CA root certificates (curl.se/ca extract of 2026-10-20) as data/ssl/CARootCertificates.pem, the default CA file of OpenSSL, curl and Haiku's network kit." \
	"Mozilla Foundation" "MPL v2.0"
fi

# --- openssl3 3.5.9, revision 2 (rev 1 is the release's runtime-only package) ---
if want openssl3; then
unpack openssl-3.5.9.tar.gz
patch -p1 < $PATCHES/openssl3-3.5.9.patchset
# the patchset's 50-haiku.conf only defines x86 targets
cat > Configurations/60-haiku-aarch64.conf <<'EOF'
my %targets = (
    "haiku-aarch64" => {
        inherit_from     => [ "haiku-common" ],
        bn_ops           => "SIXTY_FOUR_BIT_LONG",
    },
);
EOF
# CC=gcc: the default `cc` plus the cross prefix doesn't exist
CC=gcc ./Configure haiku-aarch64 --cross-compile-prefix=$H- --prefix=$S --libdir=lib \
	--openssldir=$S/data/ssl enable-zlib shared no-asm no-tests no-docs >/dev/null
make $J >/dev/null
R=$(dest openssl3)
make install_sw install_ssldirs DESTDIR=$R >/dev/null
R=$R$S
mkdir -p $R/develop/headers && mv $R/include/openssl $R/develop/headers/ && rmdir $R/include
rm -f $R/lib/*.a
chmod 700 $R/data/ssl/private
tidy $R
to_sysroot $R
REV=2 EXTRA_REQUIRES="ca_root_certificates" package $R openssl3 3.5.9 \
	"Secure Socket Layer toolkit" \
	"OpenSSL: libssl, libcrypto, the openssl tool and headers. OPENSSLDIR is /boot/system/data/ssl; the default CA file is CARootCertificates.pem there (ca_root_certificates)." \
	"1998-2026 The OpenSSL Project Authors" "Apache v2"
fi

# --- nghttp2 1.63.0 (library only; curl HTTP/2, which cargo requires) ---
if want nghttp2; then
unpack nghttp2-1.63.0.tar.xz
haiku_configure nghttp2 --enable-lib-only --disable-static >/dev/null
make $J >/dev/null
R=$(dest nghttp2)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
to_sysroot $R
package $R nghttp2 1.63.0 "HTTP/2 C library" \
	"libnghttp2, an implementation of the HTTP/2 framing layer." \
	"2012-2024 Tatsuhiro Tsujikawa, nghttp2 contributors" "MIT"
fi

# --- curl 8.23.0 (OpenSSL, HTTP/2, zlib) ---
if want curl; then
unpack curl-8.23.0.tar.bz2
patch -p1 < $PATCHES/curl-8.23.0.patchset
CPPFLAGS="-D_BSD_SOURCE" ac_cv_func_accept4=no haiku_configure curl \
	--with-openssl --with-zlib --with-nghttp2 --with-ca-bundle=$CABUNDLE \
	--without-libpsl --without-libssh2 --without-brotli --without-zstd \
	--without-libidn2 --enable-ipv6 --enable-websockets --disable-static >/dev/null
make $J >/dev/null
R=$(dest curl)
make install DESTDIR=$R >/dev/null
R=$R$S
# "Curl" is not one of Haiku's own licenses: package create refuses
# ("License 'Curl' isn't contained in package!") unless the package ships it
mkdir -p $R/data/licenses
cp COPYING $R/data/licenses/Curl
tidy $R
to_sysroot $R
EXTRA_REQUIRES="ca_root_certificates" package $R curl 8.23.0 \
	"A command-line tool and library for transferring data with URLs" \
	"curl and libcurl with OpenSSL, HTTP/2 (nghttp2) and zlib. CA bundle: /boot/system/data/ssl/CARootCertificates.pem." \
	"1996-2026 Daniel Stenberg and contributors" "Curl"
fi

# --- git 2.56.0 (no perl/python/tcl helpers) ---
if want git; then
unpack git-2.56.0.tar.xz
patch -p1 < $PATCHES/git-2.56.0.patchset
GITFLAGS=(
	CC=$H-gcc AR=$H-ar
	uname_S=Haiku uname_O=Haiku uname_M=arm64 uname_P=arm64 uname_R=1 uname_V=1
	prefix=$S gitexecdir=$S/lib/git-core sharedir=$S/data
	template_dir=$S/data/git-core/templates mandir=$S/documentation/man
	htmldir=$S/documentation/packages/git sysconfdir=$S/settings
	CURLDIR=$SYSDEV CURL_CONFIG=/bin/false CURL_LDFLAGS="-lcurl"
	OPENSSLDIR=$SYSDEV
	NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease
	NO_EXPAT=YesPlease NO_ICONV=YesPlease NO_RUST=YesPlease
	SKIP_DASHED_BUILT_INS=YesPlease
	PTHREAD_LIBS= NO_D_TYPE_IN_DIRENT=YesPlease NO_MEMMEM=YesPlease
	OBJECT_CREATION_USES_RENAMES=YesPlease NO_CROSS_DIRECTORY_HARDLINKS=YesPlease
	NO_INSTALL_HARDLINKS=YesPlease HAVE_DEV_TTY=YesPlease DEFAULT_HELP_FORMAT=web
	BASIC_LDFLAGS="-lnetwork -lbsd" CPPFLAGS="-D_POSIX_THREAD_SAFE_FUNCTIONS"
)
make $J "${GITFLAGS[@]}" all >/dev/null
R=$(dest git)
make "${GITFLAGS[@]}" install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R git 2.56.0 "Fast, scalable, distributed revision control system" \
	"Git with HTTPS (libcurl). Built without the Perl, Python and Tcl based extras (git send-email, git svn, gitk, git gui)." \
	"2005-2026 Linus Torvalds, Junio C Hamano and others" "GNU GPL v2"
fi

# --- openssh 10.6p1 (now with OpenSSL and zlib: RSA/ECDSA keys work) ---
if want openssh; then
unpack openssh-10.6p1.tar.gz
patch -p1 < $PATCHES/openssh-10.6p1.patchset
touch configure # as the recipe does: don't regenerate
DEFPATH=".:/boot/home/config/non-packaged/bin:/boot/home/config/bin:/boot/system/non-packaged/bin:/boot/system/bin:/bin:/boot/system/apps:/boot/system/preferences"
PATH_PASSWD_PROG=/bin/passwd LOGIN_PROGRAM=/bin/login haiku_configure openssh \
	--sysconfdir=$S/settings/ssh --libexecdir=$S/lib/openssh \
	--with-privsep-path=$S/data/openssh/empty --with-pid-dir=$S/var/run \
	--with-default-path="$DEFPATH" --disable-utmpx --disable-strip >/dev/null
make $J >/dev/null
R=$(dest openssh)
make install-nokeys DESTDIR=$R >/dev/null
R=$R$S
install -m 755 contrib/ssh-copy-id $R/bin/
sed -i -e "s| ~/\.ssh/| /boot/home/config/settings/ssh/|" $R/settings/ssh/ssh_config
mkdir -p $R/data/openssh/empty $R/boot/post-install
cp $R/settings/ssh/ssh_config $R/data/openssh/ssh_config.default
cp $R/settings/ssh/sshd_config $R/data/openssh/sshd_config.default
install -m 755 $PATCHES/openssh-10.6p1-files/sshd_keymaker.sh \
	$PATCHES/openssh-10.6p1-files/fix_openssh_config_paths.sh $R/boot/post-install/
tidy $R
# same user/settings declarations as the HaikuPorts package: package_daemon
# creates the `sshd` privsep user, and existing configs are kept
EXTRA_INFO='users {
	sshd real-name "sshd user" home "/packages/openssh-10.6p1-1/.self/data/openssh/empty" shell "/bin/true" groups "sshd"
}
groups {
	sshd
}
global-writable-files {
	"settings/ssh" directory keep-old
	"settings/ssh/ssh_config" keep-old
	"settings/ssh/sshd_config" keep-old
}
user-settings-files {
	"settings/ssh" directory
	"settings/ssh/ssh_config" template "data/openssh/ssh_config.default"
	"settings/ssh/sshd_config" template "data/openssh/sshd_config.default"
}
post-install-scripts {
	"boot/post-install/sshd_keymaker.sh"
	"boot/post-install/fix_openssh_config_paths.sh"
}' package $R openssh 10.6p1 "Secure Shell (SSH) client and server" \
	"OpenSSH: ssh, scp, sftp, ssh-keygen, ssh-agent and sshd. Host keys are generated on first boot; sshd is not started automatically (add it to UserBootscript)." \
	"1995-2026 Tatu Ylonen, The OpenBSD project and others" "BSD (2-clause)" "BSD (3-clause)"
fi

# --- sqlite 3.53.4 (for Python's _sqlite3; flags from the recipe) ---
if want sqlite; then
unpack sqlite-autoconf-3530400.tar.gz
CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY \
	-DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_SECURE_DELETE=1 -DSQLITE_ENABLE_FTS3=1 \
	-DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE" \
./configure --host=$H --build="$(uname -m)-unknown-linux-gnu" --prefix=$S \
	--libdir=$S/lib --includedir=$S/develop/headers --mandir=$S/documentation/man \
	--soname=legacy --disable-static >/dev/null
make >/dev/null # the recipe: no parallel builds
R=$(dest sqlite)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
to_sysroot $R
package $R sqlite 3.53.4.0 "A self-contained, serverless SQL database engine" \
	"libsqlite3 and the sqlite3 shell (FTS3/FTS5, R*Tree, DBSTAT, column metadata)." \
	"Public Domain" "Public Domain"
fi

# --- python3.12 3.12.15, prefix /boot/system (the HaikuPorts haiku install
# scheme then works as designed: pip installs to non-packaged) ---
if want python; then
unpack Python-3.12.15.tar.xz
patch -p1 < $PATCHES/python3.12-3.12.15.patchset
# upstream maps Haiku for MACHDEP but not for _host_cpu: "cross build not
# supported for aarch64-unknown-haiku"
python3 - <<'PY'
p = "configure.ac"; s = open(p).read()
old = """	*-*-vxworks*)
		_host_cpu=$host_cpu
		;;"""
assert s.count(old) == 1
open(p, "w").write(s.replace(old, old + """
	*-*-haiku*)
		_host_cpu=$host_cpu
		;;"""))
PY
autoreconf -fi >/dev/null 2>&1
cat > config.site <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
EOF
NC=$SR/boot/system/develop/headers/ncursesw
CONFIG_SITE=$PWD/config.site BASECFLAGS="-pipe -D_BSD_SOURCE" OPT="-Wall -O2" \
CPPFLAGS="-I$NC" LIBFFI_CFLAGS="" LIBFFI_LIBS="-lffi" \
CURSES_CFLAGS="-I$NC" CURSES_LIBS="-lncursesw" PANEL_CFLAGS="-I$NC" PANEL_LIBS="-lpanelw" \
BZIP2_CFLAGS="" BZIP2_LIBS="-lbz2" LIBLZMA_CFLAGS="" LIBLZMA_LIBS="-llzma" \
LIBSQLITE3_CFLAGS="" LIBSQLITE3_LIBS="-lsqlite3" \
./configure --build=aarch64-linux-gnu --host=$H --prefix=$S --bindir=$S/bin \
	--libdir=$S/lib --includedir=$S/develop/headers --mandir=$S/documentation/man \
	--datarootdir=$S/data --with-build-python=/opt/py312/bin/python3.12 \
	--enable-shared --without-static-libpython --with-ensurepip=no \
	--with-system-expat --with-openssl=$SYSDEV --with-readline=no \
	--with-tzpath=/boot/home/config/non-packaged/data/zoneinfo:/boot/home/config/data/zoneinfo:/boot/system/non-packaged/data/zoneinfo:/boot/system/data/zoneinfo \
	> $SRC/python-configure.log 2>&1
make $J > $SRC/python-make.log 2>&1
R=$(dest python3.12)
make install DESTDIR=$R > $SRC/python-install.log 2>&1
R=$R$S
L=$R/lib/python3.12
rm -f $R/lib/libpython3.so $R/bin/idle3 $R/bin/idle3.12
rm -rf $L/test $L/idlelib/idle_test $L/tkinter/test
# as the recipe: user installs go to non-packaged/lib/python3.12/site-packages
rm -rf $L/site-packages
mkdir -p $L/vendor-packages
echo 'This directory contains packaged python modules.' > $L/vendor-packages/README
grep -A30 -E "^The necessary bits|^Following modules built successfully|^Failed to build" $SRC/python-make.log | grep -v '^\s*$' || true
for m in _bz2 _lzma _sqlite3 _ssl _ctypes _curses pyexpat zlib _hashlib; do
	compgen -G "$L/lib-dynload/$m.cpython-312*.so" >/dev/null || { echo "missing module $m"; exit 1; }
done
mkdir -p $R/data/licenses
cp LICENSE $R/data/licenses/Python
tidy $R
package $R python3.12 3.12.15 "An interpreted, interactive, object-oriented programming language" \
	"CPython 3.12 with ssl, ctypes, curses, sqlite3, bz2, lzma and zlib. pip: python3 -m ensurepip (installs into /boot/system/non-packaged)." \
	"2001-2026 Python Software Foundation" "Python"
fi

ls -la $OUT
