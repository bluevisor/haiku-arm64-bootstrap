#!/bin/bash
# Cross-build GNU make 4.4.1 for Haiku arm64 as `make-4.4.1_release`, to
# replace the HaikuPorts bootstrap make (`4.4.1_bootstrap`). make's configure
# bakes the C++ compiler it saw into the built-in `CXX` default
# (AC_DEFINE MAKE_CXX "$CXX"), so the cross-built bootstrap make defaults to
# CXX = aarch64-unknown-haiku-g++, which isn't on the guest's PATH: every
# Makefile that relies on the default fails, node-gyp's link step included
# ("make: aarch64-unknown-haiku-g++: No such file or directory"). Here
# MAKE_CXX is g++. `_release` because Haiku sorts 4.4.1 below 4.4.1_bootstrap.
#
# Needs build-cross-tools.sh. Output: /repo/out/packages/make-4.4.1_release-1-arm64.hpkg
set -euxo pipefail

declare -A SHA=(
	[make-4.4.1.tar.gz]=dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3
)
declare -A URL=(
	[make-4.4.1.tar.gz]=https://ftp.gnu.org/gnu/make
)

source "$(dirname "$0")/hpkg-common.sh"

unpack make-4.4.1.tar.gz
patch -p1 < $PATCHES/make-4.4.1.patchset
haiku_configure make --disable-rpath --with-gnu-ld --disable-dependency-tracking --disable-nls
sed -i 's/^#define MAKE_CXX ".*"$/#define MAKE_CXX "g++"/' src/config.h
grep -q '^#define MAKE_CXX "g++"$' src/config.h
make $J >/dev/null
R=$(dest make)
make install DESTDIR=$R >/dev/null
R=$R$S
tidy $R
package $R make 4.4.1_release "Standard tool to compile source trees" \
	"GNU make: build programs from Makefiles. Built-in CXX is g++ (the bootstrap make defaults to the cross compiler's name)." \
	"1988-2023 Free Software Foundation, Inc." "GNU GPL v3"
