# haiku-arm64-bootstrap

Getting a usable developer environment on **Haiku arm64** running under
**UTM on Apple Silicon** (QEMU + HVF, near-native speed).

The arm64 nightly (`haiku-master-hrevNNNNN-arm64-mmc`) is a minimal image: no
package repository beyond ~25 bootstrap packages, no TLS anywhere, no SSH, no
`tar`, and a 336 MB disk. This repo has the scripts, patches and notes used to
take it from there to:

| | Version | How | Status |
|---|---|---|---|
| UTM VM config | — | `utm/config.plist.example` | boots to desktop in ~30 s |
| Disk grown to 32 GB | — | `scripts/host/grow-disk.sh` + patched `bfs_shell` | `checkfs` clean |
| GCC cross toolchain | 13.3 (`aarch64-unknown-haiku`) | `scripts/container/build-cross-tools.sh` | builds & links |
| OpenSSH | 10.6p1 | cross-built | ssh / scp / sftp, key + password auth |
| OpenSSL | 3.5.9 | cross-built | TLS 1.3 |
| curl | 8.23.0 | cross-built | HTTPS with certificate verification |
| git | 2.56.0 | cross-built | HTTPS clone, commit, log |
| Python | 3.12.15 + pip 25 | cross-built | `ssl`, `ctypes`, `curses`; `pip install` works |
| Perl | 5.42.2 | built **natively** on the VM | core tests pass apart from Haiku limits |
| **Chromium** | R Chromium 154 (third-party) | [docs/chromium.md](docs/chromium.md): rebased kernel + loader fixes, RLIM_INFINITY shim | renders haiku-os.org, GitHub, Google over HTTPS |
| **pkgman over HTTPS** | `openssl3` + `haiku` rev 3 | `scripts/container/build-haiku-netssl.sh`: `libbnetapi.so` rebuilt with OpenSSL | `pkgman install` downloads + verifies from HaikuPorts |
| **Power off / reboot** | `haiku` rev 4 | `scripts/container/build-haiku-psci.sh`: PSCI `SYSTEM_OFF`/`SYSTEM_RESET` in `arch_cpu_shutdown()` | `shutdown -r` resets, `shutdown` stops the VM; KDL `reboot` only with 1 vCPU |
| **pkgman repo** | diffutils 3.12, patch 2.8, tar 1.35, gzip 1.15, xz 5.8.4, zstd 1.5.7, pkgconf 3.0.10 | `build-core-tools.sh` + `make-package-repo.sh`, served at [haiku-arm64-packages](https://github.com/bluevisor/haiku-arm64-packages) | `pkgman add-repo` + `pkgman install`; tar round-trips gzip/xz/zstd |
| ↳ tier 2 | bzip2 1.0.8, zip 3.0, unzip 6.10c23, nano 9.1, ninja 1.13.2, cmake 4.4.4, libiconv 1.18 | `build-dev-tools.sh` | cmake+ninja+pkg-config build a C++ project; cmake HTTPS downloads; zip keeps BFS attributes; nano edits/saves |
| ↳ base stack | openssl3 3.5.9 rev 2, ca_root_certificates, nghttp2, curl, git, openssh, sqlite, python3.12 (+bz2/lzma/sqlite3), perl, ncurses6 6.6_release | `build-stack.sh`, `package-perl.sh` | replaces the `non-packaged` installs; pkgman, pip, cargo, git, curl and cmake all verify TLS against the packaged CA store |
| **Rust** | 1.101.0-nightly, LLVM 23 | own repo: [aarch64-unknown-haiku](https://github.com/bluevisor/aarch64-unknown-haiku) | native `cargo build` with crates.io deps and proc-macros; `cargo install ripgrep` works |

Built against **hrev60290** (2026-10-21). Binaries are in the
[release](../../releases); this repo holds everything needed to rebuild them.

> Tested on one machine (UTM 5.0.8, macOS 26, Apple Silicon). Expect to adapt
> paths and versions. Haiku arm64 itself is experimental.

## Quick start (using the release binaries)

1. **VM**: download the latest arm64 nightly from
   <https://download.haiku-os.org/nightly-images/arm64/>, unzip, and create a UTM
   QEMU VM like `utm/config.plist.example`: aarch64 `virt`, HVF on, UEFI on,
   **display `virtio-gpu-pci`**, **NIC `e1000`**, disk on VirtIO.
   Two settings matter (see [findings](docs/findings.md)):
   `ramfb` gives a black screen, and `virtio-net-pci` makes the *disk* fail with I/O errors.
2. **Remote shell**: the image ships `telnetd`. In Haiku's Terminal:
   `while true; do telnetd -debug 2323; done &`
3. **Bootstrap file transfer**: `tools/hsh.py --send rx --to /boot/home/bin/rx`
   (pushes the small `rx` receiver over telnet), then `tools/push.sh` for
   anything else.
4. **Install OpenSSH** from the release with `push.sh`, add your public key to
   `~/config/settings/ssh/authorized_keys` (not `~/.ssh`), run `ssh-keygen -A`,
   start `/boot/system/non-packaged/sbin/sshd`, and **stop telnetd**.
5. **Everything else**: unpack a release tarball on the host and
   `tools/push-tree.sh <dir> <ssh-host>`. That pushes over SFTP, recreates
   symlinks and verifies SHA-256. For the Perl tarball, unpack it **on the
   guest** (`python3 -m tarfile -e perl-*.tar.gz /`): it has both `pod/` and
   `Pod/`, which collide on a case-insensitive macOS filesystem.
6. **Clock + certificates**: Haiku arm64 can't read QEMU's RTC, so it boots in
   1970 and every TLS certificate looks "not yet valid". Append
   `scripts/guest/UserBootscript.snippet` to `~/config/settings/boot/UserBootscript`
   (NTP sync at boot + start sshd). The CA bundle ships in the TLS tarball
   at `/boot/system/non-packaged/data/ssl/`.
7. **Then switch to packages**: install the release's `openssl3` + revision-3
   `haiku`/`haiku_devel` so `pkgman` has HTTPS ([guide step 11](docs/guide.md#11-pkgman-over-https)),
   add the [haiku-arm64-packages](https://github.com/bluevisor/haiku-arm64-packages)
   repo, and `pkgman install` curl, git, openssh, python3.12, perl and the
   rest. Then retire the tarball copies ([guide step 13](docs/guide.md#13-from-non-packaged-to-packages)).

The tarballs install under `/boot/system/non-packaged`, which Haiku searches
before `/boot/system` (PATH and default library path). So they override packages
until they're removed, which is what step 13 does.

## Rebuilding

Cross builds run in a `debian:bookworm` container (arm64 host) with this repo
mounted at `/repo`:

```sh
docker run -d --name haiku-bfs -v "$PWD":/repo debian:bookworm sleep infinity
docker exec haiku-bfs bash /repo/scripts/container/build-bfs-shell.sh   # bfs_shell + package tool
docker exec haiku-bfs bash /repo/scripts/container/build-cross-tools.sh # GCC 13 cross toolchain (~15 min)
docker exec -e PRIVSEP_USER=<haiku user> haiku-bfs bash /repo/scripts/container/build-openssh.sh
docker exec haiku-bfs bash /repo/scripts/container/build-tls.sh         # OpenSSL + curl + git
docker exec haiku-bfs bash /repo/scripts/container/build-python.sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-chromium-fixes.sh # system packages rev 2
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-netssl.sh  # openssl3 + rev 3 (pkgman HTTPS)
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-psci.sh    # rev 4 (shutdown/reboot via PSCI)
docker exec haiku-bfs bash /repo/scripts/container/build-core-tools.sh   # diff/patch/tar/gzip/xz/zstd/pkgconf hpkgs
docker exec haiku-bfs bash /repo/scripts/container/build-dev-tools.sh    # bzip2/zip/unzip/nano/ninja/cmake/libiconv
docker exec haiku-bfs bash /repo/scripts/container/build-stack.sh        # openssl3/curl/git/openssh/python3.12/...
# perl: scripts/guest/build-perl-native.sh with PKG=1 on the VM, then package-perl.sh
docker exec haiku-bfs bash /repo/scripts/container/make-package-repo.sh  # pkgman repo index
```

Outputs land in `out/<component>/boot/system/non-packaged`. Perl is built on
the VM itself with `scripts/guest/build-perl-native.sh` (after installing the
bootstrap gcc/make; see [docs/guide.md](docs/guide.md)).

Patches under `patches/haikuports/` are the [HaikuPorts](https://github.com/haikuports/haikuports)
patchsets for each package (MIT). `patches/bfs-resize-fixes.patch` is new, as
are the build adjustments noted in the scripts.

## Docs

- [docs/guide.md](docs/guide.md): the full walkthrough in the order it was done
- [docs/chromium.md](docs/chromium.md): running Chromium (R Chromium) on stock hrev60290
- [docs/findings.md](docs/findings.md): every bug, quirk and dead end, with symptom → cause → fix
- [THIRD_PARTY.md](THIRD_PARTY.md): licenses of the software in the release

## What is still missing on arm64

Rust now works: see [aarch64-unknown-haiku](https://github.com/bluevisor/aarch64-unknown-haiku)
(the target is not upstream), and `pkgman` downloads over HTTPS after guide step 11.
Still missing: Go, gdb, Node.js, a standalone LLVM/clang, and an upstream arm64
HaikuPorts index (pkgman only knows the ~25 bootstrap packages baked into the image,
plus whatever [haiku-arm64-packages](https://github.com/bluevisor/haiku-arm64-packages) adds).
See [docs/findings.md](docs/findings.md#whats-missing-on-arm64).
For a complete Haiku with the full package repository, use the **x86_64**
nightly or R1/beta6 (emulated, so much slower on Apple Silicon).

## License

Scripts, tools and docs in this repo: MIT (see `LICENSE`). Third-party patches
and the software they apply to keep their own licenses.
