#!/bin/bash
# Make a TCP connection that both sides closed read as end-of-file on Haiku:
# build the tcp add-on with patches/haiku/tcp-eof-after-close.patch and
# repack the revision-4 haiku/haiku_devel from build-haiku-psci.sh as
# revision 5. Two bugs, both hit by every graceful Node.js http2 close
# (the server socket never sees 'end', so the process never exits):
# - once our FIN is acknowledged in LAST_ACK the endpoint is CLOSED, and
#   ReadData() returned ENOTCONN although the peer's FIN had arrived;
# - accept()ed endpoints never got FLAG_CAN_NOTIFY, so after a simultaneous
#   close (CLOSING/TIME_WAIT) they never polled readable at all.
# The haiku package also gains `provides haiku_tcp_eof_after_close = 1`.
#
# Needs build-haiku-psci.sh first. Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-5-arm64.hpkg
# Install both with one `pkgman install <file> <file>` and reboot.
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if ! grep -q FLAG_FINISH_RECEIVED src/add-ons/kernel/network/protocols/tcp/TCPEndpoint.cpp; then
	git apply /repo/patches/haiku/tcp-eof-after-close.patch
fi
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 tcp
TCP=$G/objects/haiku/arm64/release/add-ons/kernel/network/protocols/tcp/tcp

for p in haiku haiku_devel; do
	rm -rf "/build/repack5-$p" && mkdir -p "/build/repack5-$p" && cd "/build/repack5-$p"
	$PKG extract -C . "$OUT/$p-$HREV-4-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $TCP > add-ons/kernel/network/protocols/tcp
		sed -i "s/^\thaiku_arm64_psci_shutdown=1$/&\n\thaiku_tcp_eof_after_close=1/" .PackageInfo
		grep -q haiku_tcp_eof_after_close .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-4/hrev60290-5/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-5-arm64.hpkg"
done
ls -la $OUT
