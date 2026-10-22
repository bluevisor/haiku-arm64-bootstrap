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

Everything installs under `/boot/system/non-packaged`, which Haiku searches
before `/boot/system` (PATH and default library path), so it overrides the
bootstrap packages and can be removed by deleting files.

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
(the target is not upstream). Still missing: Go, gdb, Node.js, a standalone LLVM/clang, and a usable `pkgman` (it can't download: no TLS in Haiku's own network kit on
this build). See [docs/findings.md](docs/findings.md#whats-missing-on-arm64).
For a complete Haiku with the full package repository, use the **x86_64**
nightly or R1/beta6 (emulated, so much slower on Apple Silicon).

## License

Scripts, tools and docs in this repo: MIT (see `LICENSE`). Third-party patches
and the software they apply to keep their own licenses.
