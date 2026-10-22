#!/bin/bash
# Give Haiku arm64's own network kit HTTPS, so pkgman can download again.
# libbnetapi.so is built without OpenSSL on arm64 (there is no openssl3
# package for it), so every https:// BUrlRequest fails with "Operation not
# supported". This:
#  1. packages the OpenSSL from build-tls.sh as openssl3 (runtime libs only).
#     They go to /boot/system/lib, not non-packaged: safe mode drops the
#     non-packaged dirs from the library path, and every app linking
#     libbnetapi would then fail to start.
#  2. rebuilds libbnetapi.so against it (patches/haiku/netapi-local-openssl.patch).
#  3. repacks the revision-2 haiku/haiku_devel from
#     build-haiku-chromium-fixes.sh as revision 3 around that library. haiku
#     gains `requires lib:libssl lib:libcrypto` (as on x86_64) and
#     `provides haiku_bnetapi_ssl = 1`.
# CA certificates come from OpenSSL's default verify file, OPENSSLDIR/cert.pem
# = /boot/system/non-packaged/data/ssl/cert.pem, as set up by build-tls.sh.
#
# Needs build-tls.sh and build-haiku-chromium-fixes.sh first. Output:
# /repo/out/haiku-system/openssl3-3.5.9-1-arm64.hpkg and
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-3-arm64.hpkg
# Install all three with one `pkgman install <file> <file> <file>` and reboot.
set -euxo pipefail

HREV=r1~beta6_hrev60290
OSSL=3.5.9
G=/build/haiku/generated.arm64
NP=$G/cross-tools-arm64/sysroot/boot/system/non-packaged
CROSS=$G/cross-tools-arm64/bin/aarch64-unknown-haiku
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system
STAGE=/build/openssl3-stage
O3=/build/repack-openssl3

# 1. openssl3 package, plus the develop/ tree the jam build links against
rm -rf $STAGE $O3
mkdir -p $STAGE/develop/headers $STAGE/develop/lib $O3/lib $OUT
cp -a $NP/include/openssl $STAGE/develop/headers/
for l in ssl crypto; do
	cp $NP/lib/lib$l.so.3 $O3/lib/
	$CROSS-strip --strip-unneeded $O3/lib/lib$l.so.3
	ln -s $O3/lib/lib$l.so.3 $STAGE/develop/lib/lib$l.so
done
cat > $O3/.PackageInfo <<EOF
name			openssl3
version			$OSSL-1
architecture	arm64
summary			"OpenSSL $OSSL runtime libraries (local arm64 build)"
description		"libssl and libcrypto, cross-built by haiku-arm64-bootstrap because HaikuPorts has no arm64 openssl3 yet. OPENSSLDIR is /boot/system/non-packaged/data/ssl."
packager		"haiku-arm64-bootstrap"
vendor			"The OpenSSL Project"
copyrights		{ "1998-2026 The OpenSSL Project Authors" }
licenses		{ "Apache v2" }
provides {
	openssl3 = $OSSL compat >= 3
	lib:libcrypto = 3 compat >= 3
	lib:libssl = 3 compat >= 3
}
requires {
	haiku
}
EOF
(cd $O3 && $PKG create -q -z zlib -i .PackageInfo "$OUT/openssl3-$OSSL-1-arm64.hpkg")

# 2. libbnetapi.so with OPENSSL_ENABLED
cd /build/haiku
if ! grep -q HAIKU_LOCAL_OPENSSL src/kits/network/libnetapi/Jamfile; then
	git apply /repo/patches/haiku/netapi-local-openssl.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 -sHAIKU_LOCAL_OPENSSL=$STAGE libbnetapi.so
LIB=$G/objects/haiku/arm64/release/kits/network/libnetapi/ssl/libbnetapi.so
$CROSS-readelf -d $LIB | grep -q 'NEEDED.*\[libssl\.so\.3\]'
$CROSS-readelf -d $LIB | grep -q 'NEEDED.*\[libcrypto\.so\.3\]'

# 3. haiku/haiku_devel revision 3
for p in haiku haiku_devel; do
	rm -rf "/build/repack3-$p" && mkdir -p "/build/repack3-$p" && cd "/build/repack3-$p"
	$PKG extract -C . "$OUT/$p-$HREV-2-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $LIB > lib/libbnetapi.so
		sed -i "s/^\thaiku_rchromium_fixes=1$/&\n\thaiku_bnetapi_ssl=1/" .PackageInfo
		sed -i "s/^\tlib:libz>=1.2.13$/&\n\tlib:libssl>=3\n\tlib:libcrypto>=3/" .PackageInfo
		grep -q haiku_bnetapi_ssl .PackageInfo
		grep -q lib:libssl .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-2/hrev60290-3/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-3-arm64.hpkg"
done
ls -la $OUT
