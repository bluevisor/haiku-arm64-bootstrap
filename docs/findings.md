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
`Failed to download package curl: Operation not supported`. `libbnetapi.so` is
built without `OPENSSL_ENABLED` on arm64, because the build only enables TLS when
an `openssl3` package exists for the architecture, and none does. So
`BSecureSocket` returns `B_NOT_SUPPORTED` for every `https://` request.
→ Fixed by `scripts/container/build-haiku-netssl.sh` (guide step 11). It
packages our OpenSSL as `openssl3` and rebuilds `libbnetapi.so` against it
(`patches/haiku/netapi-local-openssl.patch`). It then repacks `haiku`/`haiku_devel`
as revision 3, requiring `lib:libssl`/`lib:libcrypto` as x86_64 does.
Certificates come from OpenSSL's default verify file
(`/boot/system/non-packaged/data/ssl/cert.pem`). Before that fix, the way in was:
download the `.hpkg` on another machine from
`https://eu.hpkg.haiku-os.org/haikuports/master/build-packages/packages/<name>-<version>-<arch>.hpkg`,
check it against
`package_repo list -v /boot/system/cache/package-repositories/HaikuPorts`,
copy it to a staging dir on `/boot`, then `mv` it into `/boot/system/packages`.
`package_daemon` activates it in seconds.

**OpenSSL for system libraries must be packaged, not in `non-packaged`.** In
safe mode ("disable user add-ons"), runtime_loader drops every `non-packaged`
and user directory from the library path (`search_path_for_type` in
`runtime_loader.cpp`). A `libbnetapi.so` whose `libssl.so.3` lives only in
`non-packaged/lib` would then stop every networked app from starting. Hence the
`openssl3` package in `/boot/system/lib`. The `non-packaged` copies are the same
build and are found first in normal mode.

**With TLS working, downloads 404**: `Failed to download package m4: Resource not found`.
The HaikuPorts repo config's `baseurl` is
`https://eu.hpkg.haiku-os.org/haikuports/master/arm64/current`, but upstream
has **no arm64 HaikuPorts index**. `repo`, `repo.sha256` and `repo.info` there
are a 2-byte `[]` placeholder, and nothing is under `packages/`. The only index
is the one baked into the image (repository `HaikuPorts-BuildPackages`). Its files
are under `…/haikuports/master/build-packages/packages/`, and that directory has
no `repo` file of its own. pkgman builds download URLs from the config's
`baseurl`, not from the cached index's `base-url`. → In
`/boot/system/settings/package-repositories/HaikuPorts` set
`baseurl=https://eu.hpkg.haiku-os.org/haikuports/master/build-packages`.
`pkgman refresh` then reports `Resource not found` for HaikuPorts. That's harmless:
the cached index stays and `pkgman install` downloads and verifies checksums.

**The `bison-3.8.2_bootstrap-1` arm64 package contains an x86_64 Linux binary**
(`readelf -l`: interpreter `/lib64/ld-linux-x86-64.so.2`, `NEEDED libc.so.6`).
It exits 16 with no output, and `strace` says `Failed to start 'bison': Bad data`.
That's an upstream packaging bug, so don't install it; configure scripts would
detect a broken bison. m4 and flex from the same set work.

**`package_repo create` rejects mixed vendors**:
`package 'openssl3' has unexpected vendor 'The OpenSSL Project' (expected 'haiku-arm64-bootstrap')!`.
Every package in a repository must carry the repository's `vendor`. That's why
`openssl3-3.5.9-1` stays a release asset rather than going into haiku-arm64-packages.

**`pkgman drop-repo` hangs over ssh.** It waits on an unprinted
`Really remove the repository …? [yes/no]` prompt (it has no `-y`), so feed it
with `echo yes | pkgman drop-repo <name>`. Run other pkgman commands with
`-y … < /dev/null` so a prompt can't block.

**Cross configure: `checking whether strcasecmp works... cannot run test program while cross compiling`**
(diffutils 3.12, gnulib). → Pass `gl_cv_func_strcasecmp_works=yes`.
Other gnulib run tests in tar, patch and gzip have cross defaults and need nothing.

**ncurses programs fail: `ncurses: cannot initialize terminal type ($TERM="xterm-256color"); exiting`**
(nano), and `clear` fails too, although `/boot/system/data/terminfo/x/xterm-256color`
exists. The bootstrap `ncurses6-6.6_bootstrap-1` library has the built-in
terminfo path `/packages/ncurses6_bootstrap-6.6-1/.self/data/terminfo` (`strings
libncursesw.so.6.6.0`). packagefs mounts the package as `/packages/ncurses6-6.6_bootstrap-1`,
so the default lookup always misses. → Set `TERMINFO_DIRS`
(`scripts/guest/UserSetupEnvironment.snippet` for Terminal; add the same
variable to sshd's `SetEnv` for ssh). Python's `curses.setupterm()` then sees 256 colors.
The real fix is an ncurses6 rebuild. A replacement must also sort above
`6.6_bootstrap`, and plain `6.6` sorts below it.

**Haiku has no iconv.** libroot doesn't provide `iconv_open`, and there's no
arm64 libiconv package. CMake's bundled libarchive stops with
`iconv is required, but was not found.` → `libiconv` 1.18 package
(`build-dev-tools.sh`). The HaikuPorts libiconv patchset only fixes gcc2 builds.

**CMake 4.4 cross-built with its bundled libraries: three Haiku gaps**
(HaikuPorts avoids all of them by using system curl and libuv):
- `#error "We cannot compile without socket() support!"` in cmcurl. Its
  checks add `-lnetwork` only if `HAVE_LIBNETWORK` is set, and nothing tests
  for it. → `-DHAVE_LIBNETWORK=1`.
- Link fails with `undefined reference to uv__hrtime` / `uv__fs_event_close` /
  `uv__process_title_cleanup`. `Utilities/cmlibuv` ships `src/unix/haiku.c`,
  but its CMakeLists has no Haiku block. → `patches/cmake-4.4.4-cmlibuv-haiku.patch`
  (upstream libuv's source list: haiku.c, bsd-ifaddrs.c, posix-hrtime.c,
  posix-poll.c, no-fsevents.c, no-proctitle.c; links bsd + network).
- `file(DOWNLOAD https://…)` fails with `60;"SSL peer certificate or SSH remote key was not OK"`.
  A cross build gets no CA bundle, and CMake's trimmed curl has no
  `CURL_CA_FALLBACK`: `-DCURL_CA_FALLBACK=ON` is accepted but never reaches
  `curl_config.h`. `cmCurl.cxx` only probes Linux paths. → `patches/cmake-4.4.4-haiku-cafile.patch`
  adds `/boot/system/data/ssl/CARootCertificates.pem` and its `non-packaged`
  twin. `SSL_CERT_FILE` also works as a per-run override.

**Smaller cross-build traps in `build-dev-tools.sh`:**
- ninja's `configure.py` has no Haiku platform, so it's built with CMake.
  HaikuPorts' patch enables `getloadavg()`, which lives in libbsd, so the link
  fails until `-DCMAKE_CXX_STANDARD_LIBRARIES=-lbsd`.
- zip's `unix/configure` runs two `./conftest` programs (uid/gid size, large
  files). It writes `flags` as one line of `VAR="…"` words and picks up the
  sysroot's libbz2 into `LFLAGS2`. Edit it in place (`-DLARGE_FILE_SUPPORT`,
  `LFLAGS2="-lbe …`); an appended `LFLAGS2=` drops `-lbz2` (`undefined reference to BZ2_bzCompress`).
- unzip 6.10c23 without `-DICONV_MAPPING` also loses `<locale.h>`
  (`'LC_CTYPE' undeclared`). Add `-DHAVE_LOCALE_H -DHAVE_LANGINFO_H`.
- bzip2's default `make` target runs its tests with the just-built binary, so
  build `libbz2.a bzip2 bzip2recover` explicitly.
- The shared sysroot leaks between builds. Once `build-dev-tools.sh` has put
  libiconv there, gnulib in tar finds `iconv.h` and the link fails with
  `undefined reference to libiconv_open`. `build-core-tools.sh` therefore
  exports `am_cv_func_iconv=no`, which reproduces the published packages.
- Not a bug: `bzip2 --version` prints its banner and then compresses stdin,
  so over ssh it hangs. Use `< /dev/null`.

**Packaging the base stack (`build-stack.sh`):**
- HaikuPorts' OpenSSL patchset changes the default CA *file* to
  `OPENSSLDIR/CARootCertificates.pem` (not `cert.pem`), and the default cert
  *dir* to `non-packaged/data/ssl/certs/` via `find_directory`. With
  `--openssldir=/boot/system/data/ssl` that is exactly what `ca_root_certificates`
  ships. libbnetapi (`SSL_CTX_set_default_verify_file`), Python, curl and git
  then share one packaged store. Upstream's `ca_root_certificates` is
  zstd-compressed and can't activate on arm64, so the repo has a zlib build.
- Cross `./Configure` without `CC=gcc` looks for `aarch64-unknown-haiku-cc`
  (`/bin/sh: aarch64-unknown-haiku-cc: not found`, make Error 127).
- `package create` fails with `License 'Curl' isn't contained in package!`:
  only Haiku's own license names may be used without shipping the text. Curl,
  Python, CMake, bzip2, Info-ZIP and `BSD (0-clause)` go in `data/licenses/<name>`.
- `.PackageInfo` attribute names are hyphenated: `global-writable-files`,
  `user-settings-files`, `post-install-scripts`. The underscore spelling from
  the recipes' variables gives `unknown attribute "global_writable_files"`.
- **sshd's privsep user:** Haiku has one uid-0 account, and its name varies
  (`baron`, `user`, …). A missing user is fatal for a root sshd
  (`Privilege separation user sshd does not exist`). HaikuPorts doesn't compile
  a name in. Their package declares `users { sshd … }` / `groups { sshd }`,
  and package_daemon creates the account on install (here uid 1000, home in
  the package's `data/openssh/empty`). This package does the same, so it works
  whatever the main user is called.
- OpenSSL's `libssl.pc` has `includedir=${prefix}/include ` with a trailing
  space, so a `$`-anchored sed misses it.
- Perl's `-Dman1dir=none -Dman3dir=none` plus `DESTDIR` makes installperl drop
  a few hundred `*.0` man files into the DESTDIR root. They sit outside
  `boot/system`, so the package isn't affected.
- Perl's Config records the build account and host (`cf_email='<user>@<hostname>'`):
  set `-Dcf_email`/`-Dperladmin` if that matters.

**Switching a live VM from non-packaged to packages** (guide step 13):
- non-packaged comes first on PATH and the library path, so the packages are
  invisible until the old files go. The old libcrypto/libssl also hide whether
  the packaged ones work: test pkgman and Python TLS **after** retiring them.
- pip launchers (`pip3`, `idna`, …) keep `#!/boot/system/non-packaged/bin/python3`
  and break silently once that file is gone.
- A packaged library can't depend on files in non-packaged. In safe mode
  runtime_loader drops non-packaged from the path, which is why OpenSSL and the
  CA store are packages.

**`pkgman update` can undo the local system packages.** The Haiku repo
(`haiku/master/arm64/current`) is real and moves with the nightlies. Once it
serves a newer hrev, `haiku-…-hrev603xx-1` sorts above `hrev60290-3`, and an
update would install the stock package again, without TLS or the Chromium fixes.
`rchromium` requires `haiku_rchromium_fixes`, so the solver should balk, but
check the plan before saying yes. To move to a newer hrev, rebuild the system
packages from it.

**The arm64 HaikuPorts repo is a bootstrap set, not empty**: bash, binutils, bison
(broken, see below), ca_root_certificates, coreutils, curl, expat, findutils, flex,
gawk, gcc 13.3 (native), grep, haikuporter, icu74, less, libffi, m4, make,
ncurses6, python3.10, sed, texinfo, zlib (+ `_devel`). That set is fixed in the
image's cached index; upstream publishes no arm64 index to refresh it from.
Ask `pkgman search -a ""` on the guest.

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

## Chromium

- Stock Haiku arm64 can't load clang-built Chromium: the runtime loader has
  no `R_AARCH64_TLSDESC` support. A kernel `lock_memory_etc()` partial-failure
  path also panics (`VMArea::Unwire(...): no such range`). Both fixed in
  `patches/haiku/rchromium-fixes-hrev60290.patch`.
- `Received signal 30 BUS_ADRALN` at startup is a `brk #1` CHECK, not an
  alignment problem. **`RLIM_INFINITY` changed from `0xffffffff` to all ones**
  after hrev60071, so binaries built against older headers misread "unlimited"
  as -1. See `chromium/rlimit_compat.c` and [chromium.md](chromium.md).
- pkgman's `pkgman install <local file>` refuses a new `haiku` revision while
  `haiku_devel` requires `haiku==<exact version>`: repack both and install them
  in one transaction.

## What's missing on arm64

Blocked upstream: **Go** (no haiku/arm64 port),
**gdb**, Java, GHC, Zig.

HaikuPorts recipes allow arm64 but nothing has been built yet: autoconf,
automake, libtool, pkg-config, cmake, meson, ninja, gettext, gcc 15, LLVM 23,
Ruby, Lua, PHP, Tcl, Node.js 24, plus libs (bzip2, xz, zstd, sqlite, libiconv,
readline). Perl was the main blocker for autotools; it now builds natively.

Vendor CLIs: Homebrew, Claude Code, Codex and the Cursor CLI only ship
macOS/Linux/Windows builds.
