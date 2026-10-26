#!/bin/bash
# grow-disk.sh DISK.qcow2 NEW_SIZE   (e.g. 32g)
#
# Grow the Haiku arm64 nightly disk (MBR: partition 1 = EFI, partition 2 = BFS)
# and the BFS volume inside it. Haiku's own `resizefs` refuses ("The disk system
# does not support resizing"): BFS only enables growing in the host bfs_shell
# build, which needs patches/bfs-resize-fixes.patch to actually work.
#
# Before running: shut Haiku down (`shutdown` in Terminal/ssh), then stop the VM
# in UTM. Run from the repo root; needs the build container from
# scripts/container/build-bfs-shell.sh (CONTAINER, repo mounted at /repo).
# QEMU_IMG may point at any qemu-img (see scripts/host/qemu-img-shim.c for using
# the copy bundled inside UTM.app).
# Space: needs about two disk copies free on the Mac (raw + new qcow2), and the
# $disk.bak clone stops being free once $disk is replaced. Don't put scratch copies in
# the container's /build: colima's disk is a sparse file on the BACKUP drive, and filling
# that drive gives the VM ext4 I/O errors and shuts colima down.
set -euo pipefail
disk=$1
size=$2
QEMU_IMG=${QEMU_IMG:-qemu-img}
CONTAINER=${CONTAINER:-haiku-bfs}
BFS_SHELL=/build/haiku/generated/objects/linux/arm64/release/tools/bfs_shell/bfs_shell
raw=out/grow-disk.raw                     # under the repo so the container sees it

mkdir -p out
cp -c "$disk" "$disk.bak" 2>/dev/null || cp "$disk" "$disk.bak"
echo "backup: $disk.bak"
"$QEMU_IMG" convert -O raw "$disk" "$raw"
truncate -s "$size" "$raw"

# Extend MBR partition 2 (type 0xEB, BFS) to the end of the disk.
read -r start_bytes fs_bytes disk_bytes < <(python3 -I - "$raw" <<'PY'
import os, struct, sys
p = sys.argv[1]
total = os.path.getsize(p) // 512
with open(p, "r+b") as f:
    f.seek(0x1CE); e = bytearray(f.read(16))
    if e[4] != 0xEB:
        sys.exit(f"partition 2 is type {e[4]:#x}, expected 0xeb (BFS)")
    start, _ = struct.unpack("<II", e[8:16])
    new = total - start
    e[12:16] = struct.pack("<I", new)
    f.seek(0x1CE); f.write(e)
part_bytes = new * 512
# the volume size must be a multiple of the 2 KiB block size and must not
# exceed the partition -- bfs_shell does not check this for you
print(start * 512, part_bytes - part_bytes % 2048, total * 512)
PY
)
echo "BFS partition: offset $start_bytes, new filesystem size $fs_bytes bytes"

# The long-lived container mounts the repo read-only, and bfs_shell then "resizes" nothing
# ("tried to get writable block on a read-only cache!"). Run a throwaway copy of it with
# out/ mounted writable instead.
docker commit "$CONTAINER" "$CONTAINER:grow" >/dev/null
trap 'docker rmi "$CONTAINER:grow" >/dev/null 2>&1 || true' EXIT
run_bfs() {
	docker run --rm -i --volumes-from "$CONTAINER" -v "$PWD/out:/out" "$CONTAINER:grow" \
		"$BFS_SHELL" --start-offset "$start_bytes" --end-offset "$disk_bytes" "/out/${raw#out/}"
}
printf 'resizefs -n %s\nquit\n' "$fs_bytes" | run_bfs | tail -1
printf 'resizefs %s\nsync\nquit\n' "$fs_bytes" | run_bfs | tr '\r' '\n' | grep -a -q 'successfully resized' \
	|| { echo "!! resizefs failed; $raw left in place, original disk untouched" >&2; exit 1; }
# "Unmounting FS failed: Device or resource busy" after a successful resize is harmless.
printf 'checkfs\ninfo\nquit\n' | run_bfs | grep -a -E 'blocks (not allocated|already set|could be freed)|total size|free size'

"$QEMU_IMG" convert -O qcow2 "$raw" "$disk.new"
mv "$disk.new" "$disk"
rm -f "$raw"
# colima's virtiofs keeps deleted files open, so the raw image's space is not returned
# until the VM drops it: `colima ssh -- sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'`,
# or `colima restart` if `lsof +L1 | grep grow-disk` still lists it.
echo "done: $disk"
