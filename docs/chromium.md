# Chromium on Haiku arm64

**Status: working on this VM.** R Chromium 154.0.8036.0 (Chromium's
`content_shell` with a BeAPI toolbar) renders haiku-os.org, GitHub and Google
over HTTPS on stock hrev60290, plus the two system fixes below.

The browser is **not built here.** It is
[R Chromium](https://github.com/rainygirl/renkuos-rchromium-arm64) by rainygirl, a
Chromium port to Haiku/AArch64 (an `ozone/haiku` backend over BeAPI, plus
Haiku platform code for base/content/media/V8). Building Chromium yourself is
a much larger job: a clang toolchain for Haiku, 100+ GB, many hours. Their
port notes cover it.

The port is **BSD-3-Clause, Chromium's license.** Its repository has no
top-level LICENSE file, so GitHub lists it as unlicensed. Its sources carry
Chromium's BSD header, though, and its package metadata declares
`BSD (3-clause)`. This repo doesn't mirror their packages: fetch them from
their repository. For the full `//chrome` browser built on the same port, see
[haiku-arm64-chromium](https://github.com/bluevisor/haiku-arm64-chromium).

## 1. The system fixes (`haiku_rchromium_fixes`)

Stock Haiku arm64 cannot run it. Two fixes are needed:

- **runtime_loader: `R_AARCH64_TLSDESC`.** clang emits TLS-descriptor
  relocations for `thread_local` on AArch64 and has no fallback to GCC's
  `__tls_get_addr` sequence; without a resolver the loader can't load
  Chromium.
- **kernel: `lock_memory_etc()` partial failure.** The wired range was left at
  its full size, and the unlock then panicked with
  `VMArea::Unwire(...): no such range` (it hit their `ld` writing the ~190 MB
  binary).

Their `arm64-system` repo ships a whole `haiku` system package with these,
built from **hrev60071**, which is older than this VM. Instead,
`patches/haiku/rchromium-fixes-hrev60290.patch` rebases the two patches onto
hrev60290 (one hunk moved), and
`scripts/container/build-haiku-chromium-fixes.sh` builds just the kernel and
runtime_loader and swaps them into the **stock** hrev60290 `haiku` package
(plus `haiku_devel`, which pins the exact version), as revision `-2`.

```sh
# host
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-chromium-fixes.sh
scp out/haiku-system/*.hpkg haiku:/boot/home/
# guest: snapshot the VM disk first
pkgman install /boot/home/haiku-r1~beta6_hrev60290-2-arm64.hpkg \
               /boot/home/haiku_devel-r1~beta6_hrev60290-2-arm64.hpkg
shutdown        # then stop/start the VM in UTM (no self-reset before rev 4, guide step 11)
```

Afterwards `nm /boot/system/runtime_loader | grep tlsdesc` shows
`__haiku_tlsdesc_resolve`. pkgman keeps the previous state in
`/boot/system/packages/administrative/state_*` for the boot menu.

## 2. Install R Chromium

pkgman on this image can't do HTTPS, so download the package and verify it
against their repository index, which you can fetch over HTTPS from any other
machine:

```sh
curl -fLO http://pkgman.rainygirl.com/arm64/packages/rchromium-154.0.8036.0-13-arm64.hpkg
# check its sha256 against: package_repo list -v <https://pkgman.rainygirl.com/arm64/repo>
pkgman install ./rchromium-154.0.8036.0-13-arm64.hpkg
```

## 3. The RLIM_INFINITY shim

On hrev60290 it then dies at startup with `Received signal 30 BUS_ADRALN`.
That is not an alignment fault: the faulting instruction is `brk #1`, a
`CHECK` in `base::internal::LazySysInfoValue<ByteSize, AmountOfVirtualMemory>`.
**Haiku changed `RLIM_INFINITY` from `0xffffffff` to `__HAIKU_ADDR_MAX`
(all ones)** after hrev60071. `getrlimit(RLIMIT_AS)` now returns all ones,
the binary (built against the old headers) reads that as -1, and `ByteSize`
refuses negatives.

`chromium/rlimit_compat.c` translates between the two encodings in
`getrlimit`/`setrlimit` via `dlsym(RTLD_NEXT)`. Preload it for R Chromium only:

```sh
gcc -O2 -shared -fPIC -o librlimit_compat.so chromium/rlimit_compat.c
LD_PRELOAD=$PWD/librlimit_compat.so rchromium https://www.haiku-os.org/
```

To make Deskbar/Tracker launches work too, put the `.so` in
`apps/RChromium/lib/` and export `LD_PRELOAD` in the `R Chromium` launcher
script (`bin/rchromium` is a symlink to it). That means repacking their
package locally; keep the repack to yourself (see the license note above).

## Screenshots without the host

`tools/haiku-grab.cpp` dumps the Haiku screen to a P6 pixmap (the minimal
image has no PNG translator), and `tools/ppm2png.py` converts it on any host.
That's useful when the host's screen capture is unavailable, e.g. when it's locked.

```sh
g++ -O2 -o grab tools/haiku-grab.cpp -lbe && ./grab /tmp/s.ppm   # on Haiku
python3 tools/ppm2png.py s.ppm                                   # on the host
```
