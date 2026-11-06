#!/bin/bash
# Cross-build everyday command-line tools for Haiku arm64: which, file, wget,
# rsync, vim, libevent + tmux, jq, bc, netcat, p7zip (7z), unrar, libpcap +
# tcpdump. Same rules as build-dev-tools.sh (HaikuPorts versions, checksums
# and patchsets, one package per tool, helpers in hpkg-common.sh).
# ONLY="vim tmux" rebuilds just those (tmux needs libevent built once,
# tcpdump needs libpcap).
#
# Needs build-cross-tools.sh, build-tls.sh (OpenSSL for wget, rsync and
# libevent), the ncurses6 bootstrap packages in the sysroot (build-python.sh)
# and libiconv from build-dev-tools.sh.
# Output: /repo/out/packages/<name>-<version>-1-arm64.hpkg
set -euxo pipefail

declare -A SHA=(
	[which-2.21.tar.gz]=f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad
	[file-5.43.tar.gz]=8c8015e91ae0e8d0321d94c78239892ef9dbc70c4ade0008c0e95894abfb1991
	[wget-1.24.5.tar.gz]=fa2dc35bab5184ecbc46a9ef83def2aaaa3f4c9f3c97d4bd19dcb07d4da637de
	[rsync-3.2.7.tar.gz]=4e7d9d3f6ed10878c58c5fb724a67dacf4b6aac7340b13e488fb2dc41346f2bb
	[vim-9.1.1618.tar.gz]=3078aaa7e72054ae025eebb81f40aad567054dcea3ff68f5ebecd94874568cf8
	[libevent-2.1.13-stable.tar.gz]=f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c
	[tmux-3.1c.tar.gz]=918f7220447bef33a1902d4faff05317afd9db4ae1c9971bef5c787ac6c88386
	[jq-1.8.1.tar.gz]=2be64e7129cecb11d5906290eba10af694fb9e3e7f9fc208a311dc33ca837eb0
	[bc-1.07.1.tar.gz]=62adfca89b0a1c0164c2cdca59ca210c1d44c3ffc46daf9931cf4942664cb02a
	# Debian's repack of nc110.tgz (same files; SourceForge doesn't answer here)
	[netcat_1.10.orig.tar.bz2]=64913dc3f0b4a96c3ab04d062d84f28ba6854152c94344e3985458b2aebca3d5
	[p7zip-17.05.tar.gz]=d2788f892571058c08d27095c22154579dfefb807ebe357d145ab2ddddefb1a6
	[unrarsrc-6.2.10.tar.gz]=55fe6ebd5e48d6655bfda3fd19b55438ca05e13c7e69772420caad9fdb68ef42
	[libpcap-1.11.0.tar.xz]=9237f5bae9dcf3a91823d9963ec43b7c0e2e3374ef2ad57d92c8cd39530f4723
	[tcpdump-4.99.7.tar.xz]=39675dfa06fb0e99be8da5d4a1784acbaab58ae0870231d956ff7870cb99eec1
)
declare -A URL=(
	[which-2.21.tar.gz]=https://ftp.gnu.org/gnu/which
	[file-5.43.tar.gz]=https://astron.com/pub/file
	[wget-1.24.5.tar.gz]=https://ftp.gnu.org/gnu/wget
	[rsync-3.2.7.tar.gz]=https://download.samba.org/pub/rsync/src
	[vim-9.1.1618.tar.gz]=https://github.com/vim/vim/archive
	[libevent-2.1.13-stable.tar.gz]=https://github.com/libevent/libevent/releases/download/release-2.1.13-stable
	[tmux-3.1c.tar.gz]=https://github.com/tmux/tmux/releases/download/3.1c
	[jq-1.8.1.tar.gz]=https://github.com/jqlang/jq/releases/download/jq-1.8.1
	[bc-1.07.1.tar.gz]=https://ftp.gnu.org/gnu/bc
	[netcat_1.10.orig.tar.bz2]=http://deb.debian.org/debian/pool/main/n/netcat
	[p7zip-17.05.tar.gz]=https://github.com/p7zip-project/p7zip/archive
	[unrarsrc-6.2.10.tar.gz]=https://www.rarlab.com/rar
	[libpcap-1.11.0.tar.xz]=https://www.tcpdump.org/release
	[tcpdump-4.99.7.tar.xz]=https://www.tcpdump.org/release
)

source "$(dirname "$0")/hpkg-common.sh"
# pkg-config answers from the sysroot (OpenSSL, ncurses, zlib, libevent)
export PKG_CONFIG_LIBDIR=$SR/boot/system/develop/lib/pkgconfig PKG_CONFIG_SYSROOT_DIR=$SR PKG_CONFIG_PATH=

want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }

# Host tools the debian:bookworm image lacks: autopoint (autoreconf of wget),
# ed (bc's fix-libmath_h)
command -v autopoint >/dev/null && command -v ed >/dev/null || \
	{ apt-get update -qq && apt-get install -y -qq autopoint gettext ed >/dev/null; }

# Archives whose download name differs from the HaikuPorts source file name
cd $SRC
[ -f vim-9.1.1618.tar.gz ] || wget -q -T 60 -O vim-9.1.1618.tar.gz ${URL[vim-9.1.1618.tar.gz]}/v9.1.1618.tar.gz
[ -f p7zip-17.05.tar.gz ] || wget -q -T 60 -O p7zip-17.05.tar.gz ${URL[p7zip-17.05.tar.gz]}/refs/tags/v17.05.tar.gz

license() { mkdir -p "$1/data/licenses" && cp "$3" "$1/data/licenses/$2"; }

# --- which 2.21 ---
if want which; then
unpack which-2.21.tar.gz
patch -p1 < $PATCHES/which-2.21.patch
haiku_configure which --disable-dependency-tracking >/dev/null
make $J >/dev/null
R=$(dest which)
make install DESTDIR=$R >/dev/null
R=$R$S
license $R which COPYING
tidy $R
package $R which 2.21 "Shows the full path of (shell) commands" \
	"GNU which prints the full path of the executables that would run for the given command names, searching PATH like the shell does." \
	"1999-2008 Carlo Wood" "GNU GPL v3"
fi

# --- netcat 1.10 (Hobbit's original nc; HaikuPorts patchset) ---
if want netcat; then
# (unpack can't be used: the tarball extracts to netcat-1.10.orig)
cd $SRC
F=netcat_1.10.orig.tar.bz2
[ -f $F ] || wget -q -T 60 "${URL[$F]}/$F"
echo "${SHA[$F]}  $F" | sha256sum -c -
rm -rf build/netcat-1.10.orig && tar xjf $F -C build && cd build/netcat-1.10.orig
patch -p1 < $PATCHES/netcat-1.10.patchset
$H-gcc netcat.c -O -DHAIKU -lnetwork -o nc
R=$(dest netcat)$S
mkdir -p $R/bin && cp nc $R/bin/
license $R netcat README
tidy $R
package $R netcat 1.10 "Reads and writes data across network connections" \
	"netcat (nc) reads and writes data across TCP or UDP connections: a simple client, server, port scanner and pipe for scripts." \
	"1995-1996 Hobbit" "Public Domain"
fi

# --- jq 1.8.1 (with its bundled oniguruma, linked in) ---
if want jq; then
unpack jq-1.8.1.tar.gz
haiku_configure jq --with-oniguruma=builtin --disable-static --disable-docs \
	--disable-maintainer-mode >/dev/null
make $J >/dev/null
R=$(dest jq)
make install DESTDIR=$R >/dev/null
R=$R$S
# the bundled oniguruma installs as a shared library; keep it, drop its tool
rm -rf $R/documentation/packages $R/bin/onig-config
license $R jq COPYING
tidy $R
package $R jq 1.8.1 "Command-line JSON processor" \
	"jq slices, filters, maps and transforms structured JSON data, like sed and awk do for text. Includes libjq." \
	"2012 Stephen Dolan" "MIT"
fi

# --- bc 1.07.1 ---
# The build runs the bc it just built (fbc) to turn libmath.b into libmath.h;
# on an arm64 Linux host the Haiku binary even starts, and segfaults. Make
# the header with a host build and drop the rule's prerequisites.
if want bc; then
unpack bc-1.07.1.tar.gz
patch -p1 < $PATCHES/bc-1.07.1.patchset
rm -rf ../bc-host && cp -a . ../bc-host
(cd ../bc-host && ./configure >/dev/null && make -C lib >/dev/null && make -C bc libmath.h >/dev/null)
cp ../bc-host/bc/libmath.h bc/libmath.h
haiku_configure bc >/dev/null
sed -i 's/^libmath\.h: .*/libmath.h:/' bc/Makefile
grep -q '^libmath.h:$' bc/Makefile
make -j1 MAKEINFO=true >/dev/null
R=$(dest bc)
make install MAKEINFO=true DESTDIR=$R >/dev/null
R=$R$S
license $R bc COPYING
tidy $R
package $R bc 1.07.1 "An arbitrary precision calculator language" \
	"GNU bc is an interactive calculator with arbitrary precision numbers and a C-like language; dc is the reverse-polish desk calculator." \
	"1991-2017 Free Software Foundation, Inc." "GNU GPL v3"
fi

# --- file 5.43 (+ libmagic and the compiled magic database) ---
# Cross builds compile magic.mgc with a host `file` of the same version.
if want file; then
unpack file-5.43.tar.gz
patch -p1 < $PATCHES/file-5.43.patchset
rm -rf ../file-host && cp -a . ../file-host
(cd ../file-host && ./configure --disable-shared >/dev/null && make -C src >/dev/null)
autoreconf -fi >/dev/null 2>&1
PATH=$SRC/build/file-host/src:$PATH haiku_configure file >/dev/null
PATH=$SRC/build/file-host/src:$PATH make $J >/dev/null
R=$(dest file)
make install DESTDIR=$R >/dev/null
R=$R$S
license $R file COPYING
tidy $R
package $R file 5.43 "Determines file types" \
	"file tells what kind of data a file holds by checking its magic numbers against a database of several thousand types. Includes libmagic." \
	"1986-2022 Ian F. Darwin, Christos Zoulas et al." "BSD (2-clause)"
fi

# --- wget 1.24.5 (OpenSSL; no IDN, PSL, PCRE or NLS on arm64 yet) ---
if want wget; then
unpack wget-1.24.5.tar.gz
patch -p1 < $PATCHES/wget-1.24.5.patchset
autoreconf -fi >/dev/null 2>&1
haiku_configure wget --with-ssl=openssl --without-libpsl --disable-iri \
	--disable-pcre --disable-pcre2 --without-metalink --without-cares \
	--without-libuuid --disable-nls >/dev/null
make $J >/dev/null
R=$(dest wget)
make install DESTDIR=$R >/dev/null
R=$R$S
mkdir -p $R/settings
echo "ca_certificate=/boot/system/data/ssl/CARootCertificates.pem" > $R/settings/wgetrc
license $R wget COPYING
tidy $R
EXTRA_INFO='global-writable-files {
	"settings/wgetrc" keep-old
}' \
package $R wget 1.24.5 "Retrieves files from the web" \
	"GNU wget downloads files over HTTP, HTTPS and FTP. It is non-interactive, so it works in scripts, and it can resume downloads and mirror sites." \
	"1996-2024 Free Software Foundation, Inc." "GNU GPL v3"
fi

# --- rsync 3.2.7 (with BFS attribute support from the HaikuPorts patchset) ---
if want rsync; then
unpack rsync-3.2.7.tar.gz
patch -p1 < $PATCHES/rsync-3.2.7.patchset
# The patchset changes configure.ac: regenerate configure.sh + config.h.in.
# The shipped aclocal.m4 includes ../m4/*.m4, so remake it first.
aclocal -I m4 && autoconf -o configure.sh && autoheader && touch config.h.in
haiku_configure rsync --enable-xattr-support --disable-iconv \
	--disable-iconv-open --disable-locale --disable-debug \
	--with-included-zlib=no --disable-xxhash --disable-zstd --disable-lz4 \
	--disable-md2man >/dev/null
make $J >/dev/null
R=$(dest rsync)
make install DESTDIR=$R >/dev/null
R=$R$S
license $R rsync COPYING
tidy $R
package $R rsync 3.2.7 "Fast incremental file transfer" \
	"rsync copies files locally or to and from another host over ssh, sending only the differences between the source and the existing files. Keeps BFS attributes with -X." \
	"1996-2022 Andrew Tridgell, Wayne Davison et al." "GNU GPL v3"
fi

# --- libevent 2.1.13 (tmux needs it) ---
if want libevent; then
unpack libevent-2.1.13-stable.tar.gz
patch -p1 < $PATCHES/libevent-2.1.13.patchset
sed -i "s|#!/usr/bin/env python|#!python3|" event_rpcgen.py
autoreconf -fi >/dev/null 2>&1
CPPFLAGS="-D_BSD_SOURCE -DEV_ENABLE=0" LDFLAGS="-lbsd -lnetwork" \
	haiku_configure libevent --disable-static --disable-samples >/dev/null
make $J >/dev/null
R=$(dest libevent)
make install DESTDIR=$R >/dev/null
R=$R$S
rm -f $R/bin/event_rpcgen.py && rmdir $R/bin 2>/dev/null || true
license $R libevent LICENSE
tidy $R
to_sysroot $R
package $R libevent 2.1.13 "An event notification library" \
	"libevent runs a callback when a file descriptor becomes ready, a signal arrives or a timeout expires; the basis of tmux and many network servers." \
	"2000-2007 Niels Provos, 2007-2012 Niels Provos and Nick Mathewson" "BSD (3-clause)"
fi

# --- tmux 3.1c ---
if want tmux; then
unpack tmux-3.1c.tar.gz
patch -p1 < $PATCHES/tmux-3.1c.patchset
autoreconf -fi >/dev/null 2>&1
# closefrom() is in libbsd; without it configure misses the function and
# tmux's own fallback clashes with the declaration in <bsd/unistd.h>
LIBS=-lbsd haiku_configure tmux >/dev/null
make $J >/dev/null
R=$(dest tmux)
make install DESTDIR=$R >/dev/null
R=$R$S
license $R tmux COPYING
tidy $R
package $R tmux 3.1c "Terminal multiplexer" \
	"tmux runs several terminal sessions in one window, with panes and windows, and keeps them running when you detach." \
	"2007-2020 Nicholas Marriott et al." "ISC"
fi

# --- vim 9.1.1618 (console only, huge features; no NLS or language
# interpreters) ---
if want vim; then
unpack vim-9.1.1618.tar.gz
patch -p1 < $PATCHES/vim-9.1.1618.patchset
# Answers to configure's run tests, which can't run when cross-compiling
export vim_cv_toupper_broken=no vim_cv_terminfo=yes vim_cv_tgetent=zero \
	vim_cv_getcwd_broken=no vim_cv_stat_ignores_slash=no \
	vim_cv_memmove_handles_overlap=yes vim_cv_tty_group=world \
	vim_cv_tty_mode=0620 vim_cv_timer_create=yes vim_cv_timer_create_works=yes \
	ac_cv_small_wchar_t=no
LDFLAGS=-lgnu haiku_configure vim --disable-gui --without-x --enable-gui=no \
	--with-features=huge --with-tlib=ncursesw --disable-nls \
	--disable-libsodium --disable-canberra --with-compiledby=haiku-arm64-bootstrap \
	>/dev/null
make $J >/dev/null
R=$(dest vim)
make install DESTDIR=$R >/dev/null
R=$R$S
ln -s vim $R/bin/vi
rm -rf $R/data/applications $R/data/icons
license $R Vim LICENSE	# not a license Haiku ships: the file name must match
tidy $R
package $R vim 9.1.1618 "Vi IMproved, a programmer's text editor" \
	"Vim is a highly configurable modal text editor, compatible with vi, with syntax highlighting, multiple windows, a built-in terminal and scripting. Console version; includes xxd and vimtutor." \
	"1991-2025 Bram Moolenaar et al." "Vim"
fi

# --- p7zip 17.05 (7z, 7za, 7zr) ---
if want p7zip; then
unpack p7zip-17.05.tar.gz
patch -p1 < $PATCHES/p7zip-17.05.patchset
cp makefile.haiku makefile.machine
make $J CC=$H-gcc CXX=$H-g++ 7z 7zr 7za >/dev/null
# Install like install.sh (programs in lib/p7zip, shell wrappers in bin),
# without its host `strip`
R=$(dest p7zip)$S
mkdir -p $R/bin $R/lib/p7zip $R/data/expander/rules
cp -a bin/* $R/lib/p7zip/
for p in 7z 7za 7zr; do
	printf '#!/bin/sh\nexec "%s/lib/p7zip/%s" "$@"\n' $S $p > $R/bin/$p
	chmod 755 $R/bin/$p
done
cp $PATCHES/p7zip-17.05-expander-rules $R/data/expander/rules/p7zip
license $R p7zip DOC/License.txt
tidy $R
package $R p7zip 17.05 "File archiver with a high compression ratio" \
	"p7zip is the command-line port of 7-Zip: 7z, zip, gzip, bzip2, xz and tar archives, and unpacking of many more formats (rar, cab, iso, dmg, ...)." \
	"1999-2017 Igor Pavlov, 2003-2017 myspace, 2020-2021 p7zip-project" "GNU LGPL v2.1"
fi

# --- unrar 6.2.10 (the command only; HaikuPorts also ships libunrar) ---
if want unrar; then
# (unpack can't be used: the tarball extracts to unrar/)
cd $SRC
F=unrarsrc-6.2.10.tar.gz
[ -f $F ] || wget -q -T 60 "${URL[$F]}/$F"
echo "${SHA[$F]}  $F" | sha256sum -c -
rm -rf build/unrar && tar xzf $F -C build && cd build/unrar
# Haiku has pthreads in libroot (no -pthread); libbsd for BSD extras.
# os.hpp only detects little-endian on x86 (Linux gets it from <endian.h>).
make $J CXX=$H-g++ STRIP=$H-strip LDFLAGS=-lbsd \
	DEFINES="-D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DRAR_SMP -D_BSD_SOURCE -DLITTLE_ENDIAN" \
	unrar >/dev/null
R=$(dest unrar)$S
mkdir -p $R/bin && cp unrar $R/bin/
license $R UnRAR license.txt	# not a license Haiku ships: the file name must match
tidy $R
package $R unrar 6.2.10 "Extracts RAR archives" \
	"unrar lists, tests and extracts RAR archives, including RAR5, multi-volume and password-protected ones." \
	"1993-2023 Alexander Roshal" "UnRAR"
fi

# --- libpcap 1.11.0 + tcpdump 4.99.7 ---
if want libpcap; then
unpack libpcap-1.11.0.tar.xz
haiku_configure libpcap >/dev/null
make $J >/dev/null
R=$(dest libpcap)
make install DESTDIR=$R >/dev/null
R=$R$S
rm -f $R/lib/libpcap.a
license $R libpcap LICENSE
tidy $R
to_sysroot $R
package $R libpcap 1.11.0 "Packet capture library" \
	"libpcap captures network packets on Haiku's network stack for tools such as tcpdump. Includes pcap-config and the headers." \
	"1993-2025 The Tcpdump Group" "BSD (3-clause)"
fi

if want tcpdump; then
unpack tcpdump-4.99.7.tar.xz
# by default it finds ../libpcap-*/libpcap.a and links that statically
haiku_configure tcpdump --disable-local-libpcap >/dev/null
make $J >/dev/null
R=$(dest tcpdump)
make install DESTDIR=$R >/dev/null
R=$R$S
rm -f $R/bin/tcpdump.4.99.7
license $R tcpdump LICENSE
tidy $R
package $R tcpdump 4.99.7 "Network traffic dumper" \
	"tcpdump prints a description of the packets on a network interface that match a filter expression, or reads and writes pcap files." \
	"1988-2025 The Tcpdump Group" "BSD (3-clause)"
fi
