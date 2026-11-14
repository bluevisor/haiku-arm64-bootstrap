#!/bin/bash
# kbuild.sh <out> <src.cpp> [extra -I dirs...] : build a Haiku kernel add-on natively (arm64 or x86_64)
set -e
out=$1; src=$2; shift 2
# headers/ and build/config_headers/ come from the Haiku tree at the VM's hrev
ROOT=${HAIKU_HEADERS_ROOT:-$(cd "$(dirname "$0")" && pwd)}
H=$ROOT/headers
ARCH=$(getarch)
case $ARCH in
x86_64)
	KARCH=x86; SARCH=x86_64; BARCH=x86
	# as Haiku's ArchitectureRules: no red zone in kernel code (interrupts),
	# frame pointers for stack traces
	ARCHFLAGS="-mno-red-zone -fno-omit-frame-pointer"
	GCCLIB=$(dirname "$(gcc -print-libgcc-file-name)")
	;;
*)
	KARCH=$ARCH; SARCH=$ARCH; BARCH=$ARCH; ARCHFLAGS=
	GCCLIB=/boot/system/develop/lib
	;;
esac
INC="-I$ROOT/build/config_headers -I$H/private -I$H/private/kernel -I$H/private/kernel/arch/$KARCH -I$H/private/system -I$H/private/system/arch/$SARCH -I$H/private/shared -I$H/private/virtio -I$H/private/drivers -I$H/private/graphics/common -I$H/private/graphics/virtio -I$H/private/graphics -I$H/os/drivers -I$H/os/drivers/graphics -I$H/os/add-ons/graphics -I$H/os/kernel -I$H/private/kernel/util -I$H/private/kernel/boot/platform/efi -I$H/private/kernel/boot/arch/$BARCH $*"
g++ -c -O2 -std=gnu++17 -D_KERNEL_MODE -D__HAIKU__ -fno-exceptions -fno-rtti -fno-builtin -fno-use-cxa-atexit -fno-strict-aliasing -fpic $ARCHFLAGS -Wall -Wno-multichar -Wno-class-memaccess $INC "$src" -o "$out.o"
# Kernel-flavored gcc runtime. x86_64 ships no libsupc++-kernel.a; the kernel
# exports what the add-ons need from it.
LIBS=
for l in libgcc-kernel.a libsupc++-kernel.a; do
	[ -f "$GCCLIB/$l" ] && LIBS="$LIBS $GCCLIB/$l"
done
# 4 KiB segment alignment: with ld's arm64 default (64 KiB) the kernel
# rejects the add-on with "Bad data".
ld -shared -z max-page-size=0x1000 -z common-page-size=0x1000 -Bsymbolic -soname=$(basename $out) -o "$out" "$out.o" /boot/system/develop/lib/_KERNEL_ $LIBS
