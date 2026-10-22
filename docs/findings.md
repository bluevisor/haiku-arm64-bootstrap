# Findings: Haiku arm64 under UTM

Everything that broke while bootstrapping, with the exact error text, the cause
and what worked. Tested with Haiku hrev60290 (2026-10-21), UTM 5.0.8, QEMU
10.0 with HVF, Apple Silicon.

## UTM / QEMU

**Black screen with `ramfb` display.** The serial log shows `GOP protocol not found`,
then app_server loops `Failed to initialize virtual screen configuration`.
→ Use **`virtio-gpu-pci`**. Haiku ships a `virtio_gpu` driver and accelerant.

**Disk dies mid-boot with `virtio-net-pci`.** Right after
`publish device: ... net/virtio/0`, virtio_block starts failing:
`packagefs: ReadFileData(...) failed to read data: I/O error` and
`bfs: could not write log area: I/O error!`. The message points at the disk,
but the trigger is the virtio NIC (all virtio_pci devices use legacy INTx).
→ Use **`e1000`**: Haiku's ipro1000 driver works, and DHCP comes up on UTM's shared network.

**`utmctl` fails on every call** with `OSStatus error -1708`.
→ Drive UTM through AppleScript: `tell application "UTM" to start virtual machine named "X"`.
Edit configs with `set cfg to configuration of vm` … `update configuration of vm with cfg`.

**`update configuration` silently converts a raw `.img` drive to qcow2**
(`Data/haiku.qcow2`, `ImageName` rewritten). Check `Data/` before assuming the disk path.

**Setting `guest size` on a drive via AppleScript** is accepted, but doesn't resize anything.

**No `qemu-img` on PATH.** UTM bundles it as a framework that exports `main`.
`scripts/host/qemu-img-shim.c` `dlopen`s it, which gives you the full qemu-img 10.x.

**Input automation**: `input mouse click (vm) at {x, y}` (guest pixels),
`input keystroke (vm) text "..."` and `input scan code (vm) codes {...}`
(PC AT set 1, e.g. Down = `{224,80,224,208}`, Enter = `{28,156}`) all work.
macOS-level synthetic clicks land at guest (0,0).

**Serial log**: serial mode TcpServer, then `nc -d 127.0.0.1 PORT < /dev/null > log`
right after start. Without `-d`, macOS `nc` drops the connection on stdin EOF.
Haiku logs the whole boot (loader + kernel) to the PL011 port. From a shell,
`cmd | tee /dev/dprintf` sends output there too.

**Shutdown**: UTM's `stop … by request` (ACPI) is ignored. `shutdown` and
`shutdown -r` in Haiku stop all apps but never power off or reset (UTM shows
"Display output is not active"). The disk is synced by then, so `stop … by kill` is safe.

## Haiku arm64 system

**Clock starts at 1970 every boot.** There's no driver for QEMU's PL031 RTC.
Symptom: `SSL certificate OpenSSL verify result: certificate is not yet valid (9)`.
→ `/boot/system/preferences/Time --update` does a headless NTP sync and exits 0.
Run it at boot (`scripts/guest/UserBootscript.snippet`).

**`pkgman` can't download anything**: `Refreshing repository … failed`,
`Failed to download package curl: Operation not supported`. Haiku's network kit on
this build has no TLS (no OpenSSL). → Download the `.hpkg` on another machine from
`https://eu.hpkg.haiku-os.org/haikuports/master/build-packages/packages/<name>-<version>-<arch>.hpkg`
and check it against
`package_repo list -v /boot/system/cache/package-repositories/HaikuPorts`.
Copy it to a staging dir on `/boot`, then `mv` it into `/boot/system/packages`;
`package_daemon` activates it in seconds.

**The arm64 HaikuPorts repo is a bootstrap set, not empty**: bash, binutils, bison,
ca_root_certificates, coreutils, curl, expat, findutils, flex, gawk, gcc 13.3
(native), grep, haikuporter, icu74, less, libffi, m4, make, ncurses6, python3.10,
sed, texinfo, zlib (+ `_devel`). Checking `repo.info` with curl is misleading:
`repo` is a binary file, so ask `pkgman search -a ""` on the guest instead.

**zstd packages won't activate**: `ca_root_certificates` fails with
`Failed to decompress chunk data: Operation not supported` (packagefs here has
no zstd). → Extract it with the host `package` tool *inside a Linux filesystem*.
On a macOS bind mount, extraction fails with `Failed to create attribute "BEOS:TYPE"`.
Then install the PEM by hand.

**The bootstrap `python3.10` is broken**: exits rc 3 with nothing on stderr.
The serial/kernel log says `runtime_loader: Cannot open file libpython3.10.so.1.0`,
because the package doesn't contain it. Runtime-loader errors go to the serial
log, not stderr.

**The bootstrap `curl` has no TLS**: `Protocol "https" disabled`.

**No `tar`, `gzip` or `unzip`**, and bootstrap bash has **no `/dev/tcp`**. Push files
with `tools/rx.c` (TCP receiver) or base64 in ≤3000-char `printf` chunks over
telnet, waiting for an ack after each. Blasting a heredoc overruns the tty
(`base64: invalid input`). Once Perl or Python is installed, `ptar` /
`python3 -m tarfile` extract archives.

**`LIBRARY_PATH` is empty in ssh sessions** (sshd doesn't run Haiku's
SetupEnvironment), and on Haiku a *set* `LIBRARY_PATH` replaces the default
search path. Build systems doing `LIBRARY_PATH=$PWD:$LIBRARY_PATH ./tool` then fail with
`runtime_loader: Cannot open file libnetwork.so`. → Export
`LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"` first.

**`getsockopt()` wants an exact `optlen`**: `getsockopt(SOL_SOCKET, SO_ERROR)`
returns EINVAL unless `optlen == sizeof(int)`. Perl passes 256, so
`IO::Socket::IP` with a `Timeout` warns `Use of uninitialized value $err … IP.pm line 749`
and can't see connect errors. Four tests in `io/socket.t` fail. Probably not
arm64-specific.

**Locales**: `setlocale()` accepts arbitrary names (`Afrikaans.1.UTF-8`) that
aren't actually UTF-8. That accounts for every block of exactly 952 failures in
Perl's locale-dependent tests (`t/loc_tools.pl`).

**No zoneinfo** on the minimal image: `pip install tzdata` makes Python's
`zoneinfo` work.

**The `ps` output** is `Team(path+args) Id #Threads Gid Uid`, with no ppid.

## Disk growth (BFS)

**`resizefs /boot <size>` → `The disk system does not support resizing.`**
BFS advertises resizing only `#ifdef FS_SHELL`, so it works in the host
`bfs_shell` and nowhere else. The kernel has the `BFS_IOCTL_RESIZE` ioctl, but no stock tool calls it.

**Stock `bfs_shell resizefs` can't grow a volume**; it has two bugs
(`patches/bfs-resize-fixes.patch`):
1. `ResizeVisitor::Resize` leaves `SetAllowedRange()` active while calling
   `MoveLog()`, so the larger journal can't be allocated:
   `MoveLog: Could not allocate space to move log area!` /
   `Resizing failed, status: Invalid argument`.
2. `BlockAllocator::Reinitialize()` calls `Initialize(true, true)` without holding
   the lock. The kernel tolerates that; fs_shell panics with
   `recursive_lock ... unlocked by non-holder thread` and segfaults *after* the
   superblock is written. It looks like a crash mid-move only because stdout isn't flushed.

**`bfs_shell` doesn't check the new size against the device.** Passing 1 MB too
much gives a volume that won't mount (`Disk size … < file system size`).
Use (partition sectors × 512) rounded down to the 2 KiB block size.
"Unmounting FS failed: Device or resource busy" after a successful resize is harmless.

After growing, used space jumps by about the RAM size: Haiku creates
`/boot/system/var/swap` once there's room.

## Cross-compiling

**`package` host tool (GCC 12)**: `'offsetof' was not declared in this scope` in
`src/kits/storage/sniffer/RPattern.cpp`. → Add `#include <cstddef>`.

**OpenSSL** has no arm64 Haiku target. → Add a `haiku-aarch64` target inheriting
`haiku-common` with `bn_ops SIXTY_FOUR_BIT_LONG`, and use `no-asm` (HaikuPorts uses
no-asm off x86_64 too).

**CPython 3.12 cross build**:
`configure: error: cross build not supported for aarch64-unknown-haiku`.
Upstream maps Haiku for `MACHDEP` but not in the `_host_cpu` case, so add
`*-*-haiku*) _host_cpu=$host_cpu`. Then
`You must get working getaddrinfo() function` needs `ac_cv_buggy_getaddrinfo=no`.

**HaikuPorts' Python `haiku` install scheme** hard-codes `{base}/non-packaged`,
assuming prefix `/boot/system`. With prefix `/boot/system/non-packaged`, pip
installs into `non-packaged/non-packaged/` and scripts end up off PATH.
`scripts/container/fix-nonpackaged-scheme.py` fixes it; run it on the source `Lib/` before
`make`, because **`site` is deep-frozen into the 3.12 binary** and editing the installed
`site.py` has no effect.

**OpenSSH** bakes the privilege-separation user in at build time
(`--with-privsep-user`). Rename the Haiku account without rebuilding and sshd
won't start. For a uid-0 account, password login fails silently ("Permission
denied") until `PermitRootLogin yes`; keys still work.

**Perl** (native build):
- Configure bakes `LDLIBPTH = LIBRARY_PATH=<builddir>` into makefile/Makefile/pod/Makefile
  when `LIBRARY_PATH` was empty, so exporting it later doesn't help. sed in `:$(LIBRARY_PATH)`.
- With `-Ddont_use_nlink` (BFS link counts), `installperl` copies `bin/perl` and
  `bin/perlthanks` as 0644, so you get "Permission denied" until chmod 755.

## Rust (`aarch64-unknown-haiku`)

Upstream rustc has only i686/x86_64 Haiku targets. Adding the target is ~25
lines (AArch64 ELF data layout + `base::haiku::opts()` + PIE) plus one
registration line; std needs no changes (prior art: felipedbene/Haiku-Graviton
`haiku-rust-bake`, rainygirl/renkuos-rchromium-arm64 `rust/`). Gotchas hit:

- Bootstrap refuses the unknown target ("target not in stage0 list"):
  `BOOTSTRAP_SKIP_TARGET_SANITY=1`.
- `download-ci-llvm` must be **false** for a cross-hosted rustc (rustc_llvm
  rewrites the build host's llvm-config paths to the target's).
- `ld: cannot find -lgcc_s` linking libstd.so: the cross toolchain only builds a
  static libgcc. Extract the `gcc_syslibs` + `gcc_syslibs_devel` hpkgs into the sysroot.
- `x.py dist` wipes `build/host/stage1/bin` when it starts; snapshot stage1
  before using it for a parallel cargo build.
- cargo forces curl's `http2` feature; without HTTP/2 in the system libcurl,
  curl-sys compiles its own static curl. Build nghttp2 and curl `--with-nghttp2`.
- **cargo's child `rustc` exits with status 3 and no message over ssh.** cargo
  prepends to `LIBRARY_PATH`, which is empty in ssh sessions, so the runtime
  loader loses its default search path. Fix for all sessions: at the top of
  `sshd_config`,
  `SetEnv LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib" ADDON_PATH="…"`.
- Use a nightly ≥ 2026-10-13: before that, `File::lock` returns Unsupported on
  Haiku and cargo silently runs without its file locks.

## What's missing on arm64

Blocked upstream: **Go** (no haiku/arm64 port),
**gdb**, Java, GHC, Zig.

HaikuPorts recipes allow arm64 but nothing has been built yet: autoconf,
automake, libtool, pkg-config, cmake, meson, ninja, gettext, gcc 15, LLVM 23,
Ruby, Lua, PHP, Tcl, Node.js 24, plus libs (bzip2, xz, zstd, sqlite, libiconv,
readline). Perl was the main blocker for autotools; it now builds natively.

Vendor CLIs: Homebrew, Claude Code, Codex and the Cursor CLI only ship
macOS/Linux/Windows builds.
