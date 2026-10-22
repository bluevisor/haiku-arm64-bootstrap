#!/bin/bash
# Make `shutdown` and `shutdown -r` actually power off / reset Haiku arm64:
# build kernel_arm64 with patches/haiku/arm64-psci-shutdown.patch (PSCI
# SYSTEM_OFF / SYSTEM_RESET, conduit from the ACPI FADT) and repack the
# revision-3 haiku/haiku_devel from build-haiku-netssl.sh as revision 4.
# The haiku package also gains `provides haiku_arm64_psci_shutdown = 1`.
#
# Needs build-haiku-netssl.sh first (its tree already carries the R Chromium
# kernel fix, which this kernel keeps). Output:
# /repo/out/haiku-system/haiku{,_devel}-r1~beta6_hrev60290-4-arm64.hpkg
# Install both with one `pkgman install <file> <file>` and reboot (the old
# kernel still needs the UTM stop + start for this one).
set -euxo pipefail

HREV=r1~beta6_hrev60290
G=/build/haiku/generated.arm64
PKG=/build/haiku/generated/objects/linux/$(uname -m | sed 's/aarch64/arm64/')/release/tools/package/package
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib
OUT=/repo/out/haiku-system

cd /build/haiku
if ! grep -q PSCI_SYSTEM_RESET src/system/kernel/arch/arm64/arch_cpu.cpp; then
	git apply /repo/patches/haiku/arm64-psci-shutdown.patch
fi
grep -q 'cacheChainLocker.Unlock' src/system/kernel/vm/vm.cpp
cd $G
jam -q -j"$(nproc)" -sHAIKU_REVISION=hrev60290 kernel_arm64
KERNEL=$G/objects/haiku/arm64/release/system/kernel/kernel_arm64
$G/cross-tools-arm64/bin/aarch64-unknown-haiku-objdump -d $KERNEL \
	| grep -A30 '<arch_cpu_shutdown>:' | grep -q 'hvc'

for p in haiku haiku_devel; do
	rm -rf "/build/repack4-$p" && mkdir -p "/build/repack4-$p" && cd "/build/repack4-$p"
	$PKG extract -C . "$OUT/$p-$HREV-3-arm64.hpkg"
	if [ $p = haiku ]; then
		# overwrite in place: keeps the file's Haiku attributes
		cat $KERNEL > kernel_arm64
		sed -i "s/^\thaiku_bnetapi_ssl=1$/&\n\thaiku_arm64_psci_shutdown=1/" .PackageInfo
		grep -q haiku_arm64_psci_shutdown .PackageInfo
	fi
	# haiku_devel requires haiku==<exact version>, so both move together
	sed -i "s/hrev60290-3/hrev60290-4/g" .PackageInfo
	# the arm64 packagefs cannot read zstd: force zlib
	$PKG create -q -z zlib -i .PackageInfo "$OUT/$p-$HREV-4-arm64.hpkg"
done
ls -la $OUT
