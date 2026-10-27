#!/bin/bash
# Build and install the Haiku guest tools on the running VM, from the Mac.
#
#   guest-tools/build.sh [ssh-host]        (default: haiku-dbg)
#
# Builds natively on the guest (gcc + Haiku private headers fetched from
# review.haiku-os.org at the VM's hrev), then installs:
#   /boot/system/non-packaged/add-ons/kernel/drivers/ports/virtio_console
#   ~/config/non-packaged/add-ons/kernel/drivers/bin/virtio_console_attach
#     (+ dev/misc symlink)
#   ~/config/non-packaged/add-ons/kernel/drivers/graphics/virtio_gpu
#     (local patches 0009 + 0015)
#   ~/config/non-packaged/bin/vdagent (+ UserBootscript line)
# Kernel drivers take effect after a reboot.
set -euo pipefail

HOST=${1:-haiku-dbg}
HREV=${HREV:-hrev60295}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WORK=${WORK:-$HOME/Developer/bluevisor/haiku-src}

# 1. Haiku sources: headers + virtio_gpu, with our patches on top.
if [ ! -d "$WORK/.git" ]; then
	git init -q "$WORK"
	git -C "$WORK" remote add origin https://review.haiku-os.org/haiku
	git -C "$WORK" config core.sparseCheckout true
	printf '%s\n' headers/ build/config_headers/ \
		src/add-ons/kernel/drivers/graphics/virtio/ \
		> "$WORK/.git/info/sparse-checkout"
	git -C "$WORK" fetch -q --depth 1 origin tag "$HREV"
	git -C "$WORK" checkout -q "$HREV"
	for p in 0009-haiku-virtio_gpu-3d.patch 0015-virtio_gpu-report-host-display-changes.patch; do
		git -C "$WORK" apply --include='src/add-ons/*' --include='headers/*' \
			"$REPO/patches/haiku-$HREV/$p"
	done
fi

# 2. Ship sources to the guest (no AppleDouble files: they confuse BFS tar).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/gt"
cp -R "$WORK/headers" "$WORK/build" "$STAGE/gt/"
mkdir -p "$STAGE/gt/virtio_gpu"
cp "$WORK"/src/add-ons/kernel/drivers/graphics/virtio/* "$STAGE/gt/virtio_gpu/"
cp -R "$HERE/virtio_console" "$HERE/vdagent" "$HERE/kbuild.sh" "$STAGE/gt/"
COPYFILE_DISABLE=1 tar czf "$STAGE/gt.tgz" --no-xattrs -C "$STAGE" gt
scp -q "$STAGE/gt.tgz" "$HOST:/boot/home/guest-tools.tgz"

# 3. Build and install on the guest. Never cp over a loaded driver in place:
#    copy to a temp name and mv.
ssh "$HOST" bash -s <<'EOF'
set -e
rm -rf ~/src/guest-tools && mkdir -p ~/src && cd ~/src
tar xzf ~/guest-tools.tgz 2>/dev/null && mv gt guest-tools && cd guest-tools
K=./kbuild.sh
mkdir -p out
$K out/virtio_console virtio_console/virtio_console.cpp
$K out/virtio_console_attach virtio_console/virtio_console_attach.cpp
$K out/virtio_gpu virtio_gpu/virtio_gpu.cpp -Ivirtio_gpu
g++ -O2 -Wall -o out/vdagent vdagent/vdagent.cpp -lbe -ltranslation
# Tracker/Deskbar icon (vdagent/vdagent-icon.hvif, made from vdagent-icon.svg
# with hvif-tools' icon2icon) and the app signature, as resources.
xres -o out/vdagent -a VICN:101:BEOS:ICON vdagent/vdagent-icon.hvif \
	-a MIMS:1:BEOS:APP_SIG -s application/x-vnd.bluevisor-vdagent

install_file() { mkdir -p "$(dirname "$2")"; cp "$1" "$2.tmp"; mv -f "$2.tmp" "$2"; }
SYS=/boot/system/non-packaged/add-ons/kernel/drivers
USR=~/config/non-packaged/add-ons/kernel/drivers
install_file out/virtio_console $SYS/ports/virtio_console
install_file out/virtio_console_attach $USR/bin/virtio_console_attach
mkdir -p $USR/dev/misc
ln -sf ../../bin/virtio_console_attach $USR/dev/misc/virtio_console_attach
install_file out/virtio_gpu $USR/graphics/virtio_gpu
install_file out/vdagent ~/config/non-packaged/bin/vdagent
mimeset -f ~/config/non-packaged/bin/vdagent

BOOT=~/config/settings/boot/UserBootscript
grep -q non-packaged/bin/vdagent $BOOT || printf '\n%s\n%s\n' \
	"# SPICE guest agent: clipboard sharing + resize-to-window (haiku-arm64-bootstrap/guest-tools)" \
	"/boot/home/config/non-packaged/bin/vdagent </dev/null >/dev/null 2>&1 &" >> $BOOT
sync
echo "installed; reboot the guest to load the kernel drivers"
EOF
