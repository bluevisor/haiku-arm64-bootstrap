#!/bin/bash
# Builds a copy of UTM whose QEMU can map virtio-gpu host blobs on Intel Macs.
#   build.sh <stock UTM.app> <output .app>
# Stock UTM aborts the VM on the first Venus blob map on Intel: QEMU maps
# every region with HV_MEMORY_EXEC, and Intel Hypervisor.framework refuses
# that for shared memory (see hvfix.c). This rebuilds QEMULauncher from UTM's
# own sources with libhvfix linked in, so its hv_vm_map interposer covers the
# QEMU framework the launcher dlopens. It also adds libmtlfix (mtlfix.m), which
# keeps the render server alive on Metal drivers without attribute-stride binds
# (2013 Mac Pro FirePro). The copy is ad-hoc signed with the entitlements in
# ents/ (UTM's unsigned set: no vmnet, so VMs must use Emulated networking;
# library validation off so the ad-hoc dylibs load).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
stock=$1 out=$2
[ -d "$stock/Contents/XPCServices/QEMUHelper.xpc" ] || { echo "not a UTM.app: $stock" >&2; exit 2; }
[ ! -e "$out" ] || { echo "$out exists" >&2; exit 2; }

cp -R "$stock" "$out"
helper="$out/Contents/XPCServices/QEMUHelper.xpc"
launcher="$helper/Contents/MacOS/QEMULauncher.app"
min=$(defaults read "$out/Contents/Info" LSMinimumSystemVersion)
arch=$(uname -m)

# The launcher only ever runs on this machine: build it for this arch alone.
clang -O2 -Wall -arch "$arch" -mmacosx-version-min="$min" -dynamiclib \
	-install_name @executable_path/libhvfix.dylib \
	-o "$launcher/Contents/MacOS/libhvfix.dylib" "$here/hvfix.c" -framework Hypervisor
# Metal fallbacks for the render server (mtlfix.m); hvfix puts it in the
# environment QEMU's children inherit.
clang -O2 -Wall -fobjc-arc -arch "$arch" -mmacosx-version-min="$min" -dynamiclib \
	-install_name @executable_path/libmtlfix.dylib \
	-o "$launcher/Contents/MacOS/libmtlfix.dylib" "$here/mtlfix.m" \
	-framework Metal -framework Foundation
clang -O2 -Wall -arch "$arch" -mmacosx-version-min="$min" \
	-o "$launcher/Contents/MacOS/QEMULauncher" \
	"$here/launcher/main.c" "$here/launcher/Bootstrap.c" \
	-L"$launcher/Contents/MacOS" -lhvfix \
	-Wl,-rpath,@executable_path/../../../../../../../Frameworks
# (the rpath is the stock launcher's: the QEMU framework's own dependencies
# resolve @rpath through the main executable; without it QEMU exits with
# "no LC_RPATH's found")

# Everything ad hoc first, then the pieces that need entitlements, inside out.
codesign --force --deep --sign - "$out" 2>&1 | grep -v "replacing existing signature" || true
sign() { codesign --force --sign - --options runtime --entitlements "$here/ents/$1.plist" "$2"; }
codesign --force --sign - "$launcher/Contents/MacOS/libhvfix.dylib"
codesign --force --sign - "$launcher/Contents/MacOS/libmtlfix.dylib"
sign QEMULauncher "$launcher"
sign QEMURenderServer "$helper/Contents/MacOS/QEMURenderServer.app"
sign QEMUHelper "$helper"
sign utmctl "$out/Contents/MacOS/utmctl"
sign MAIN "$out"
codesign --verify --deep --strict "$out" && echo "built and signed: $out"
otool -L "$launcher/Contents/MacOS/QEMULauncher" | sed -n 2,4p
