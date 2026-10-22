#!/bin/bash
# Cross-build OpenSSH 10.6p1 for Haiku arm64 (HaikuPorts patchset).
# There is no OpenSSL or zlib for arm64 in the bootstrap set, so this builds
# --without-openssl --without-zlib: host keys are ed25519 / mldsa44-ed25519.
#
# PRIVSEP_USER: sshd needs an existing account for privilege separation and
# bakes its name in at build time. Haiku has a single user; use its name
# (`whoami` on the guest). Rebuild if you rename the account.
set -euxo pipefail

V=10.6p1
PRIVSEP_USER=${PRIVSEP_USER:-baron}
X=/build/haiku/generated.arm64/cross-tools-arm64
export PATH=$X/bin:$PATH
STAGE=/repo/out/openssh

mkdir -p /build/ssh && cd /build/ssh
[ -f openssh-$V.tar.gz ] || wget -q https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-$V.tar.gz
rm -rf openssh-$V && tar xzf openssh-$V.tar.gz && cd openssh-$V
patch -p1 < /repo/patches/haikuports/openssh-$V.patchset
touch configure   # as the HaikuPorts recipe does: don't regenerate

DEFAULT_PATH=".:/boot/home/config/non-packaged/bin:/boot/home/config/bin:/boot/system/non-packaged/bin:/boot/system/bin:/bin:/boot/system/apps:/boot/system/preferences"
./configure --host=aarch64-unknown-haiku \
	--prefix=/boot/system/non-packaged \
	--sysconfdir=/boot/system/settings/ssh \
	--libexecdir=/boot/system/non-packaged/lib/openssh \
	--with-privsep-path=/boot/system/non-packaged/data/openssh/empty \
	--with-privsep-user="$PRIVSEP_USER" \
	--with-pid-dir=/boot/system/var/run \
	--with-default-path="$DEFAULT_PATH" \
	--disable-utmpx --without-openssl --without-zlib --disable-strip >/dev/null
make -j"$(nproc)" >/dev/null
rm -rf "$STAGE" && make install-nokeys DESTDIR="$STAGE" >/dev/null
find "$STAGE" -type f -perm -u+x -exec sh -c 'file "$1" | grep -q ELF && aarch64-unknown-haiku-strip "$1"' _ {} \;
rm -rf "$STAGE/boot/system/non-packaged/share/man"
echo "staged: $STAGE (privsep user: $PRIVSEP_USER)"
