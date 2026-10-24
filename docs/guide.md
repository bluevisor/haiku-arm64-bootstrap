# Walkthrough

The order things were done in, with the commands that worked. See
[findings.md](findings.md) for why each workaround exists.

Conventions: **host** = the Mac, **container** = `debian:bookworm` (arm64)
with this repo at `/repo`, **guest** = Haiku. The guest's address on UTM's
shared network was `192.168.64.4` and the host's was `192.168.64.1`.

## 1. VM

1. Get the newest `haiku-master-hrevNNNNN-arm64-mmc.zip` from
   <https://download.haiku-os.org/nightly-images/arm64/> and check its `.sha256`.
2. Create a QEMU VM in UTM matching `utm/config.plist.example`: aarch64 `virt`,
   HVF, UEFI, 1 vCPU (SMP is untested), **`virtio-gpu-pci`** display, **`e1000`**
   NIC (Shared), the `.image` file as a VirtIO disk. To script it, write the
   bundle by hand and `open -a UTM Haiku.utm`, then use AppleScript
   (`utmctl` returns -1708).
3. Optional: a TcpServer serial port, read with `nc -d 127.0.0.1 PORT < /dev/null`.

## 2. Grow the disk (VM stopped)

```sh
cc -o qemu-img scripts/host/qemu-img-shim.c -Wl,-rpath,/Applications/UTM.app/Contents/Frameworks
docker exec haiku-bfs bash /repo/scripts/container/build-bfs-shell.sh
QEMU_IMG=./qemu-img scripts/host/grow-disk.sh /path/to/Haiku.utm/Data/haiku.qcow2 32g
```

Set RAM in UTM (AppleScript `set memory of cfg to 8192` works; `guest size` doesn't).

## 3. First remote shell and file transfer

In Haiku's Terminal (Deskbar → Applications → Terminal):

```sh
while true; do telnetd -debug 2323; done &
```

From the host. The login name is whatever `whoami` prints in Haiku's Terminal
(`baron` on the nightly tested), with no password by default:

```sh
tools/hsh.py --user baron 'uname -a'          # run a command over telnet
```

`rx` is a tiny TCP receiver that makes transfers fast. Take the prebuilt
`rx-haiku-arm64` from the release, or build it after step 4 with
`aarch64-unknown-haiku-gcc -O2 -s -o rx tools/rx.c -lnetwork`. Then:

```sh
tools/hsh.py --user baron --send rx-haiku-arm64 --to /boot/home/rx \
  'mkdir -p /boot/home/bin && mv /boot/home/rx /boot/home/bin/rx && chmod 755 /boot/home/bin/rx'
tools/push.sh some-file /boot/home/some-file 644   # served by the host, fetched by rx
```

## 4. Cross toolchain

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-cross-tools.sh
```

GCC 13.3 for `aarch64-unknown-haiku`, with the arm64 `haiku` + `haiku_devel`
packages extracted into its sysroot.

## 5. OpenSSH

```sh
docker exec -e PRIVSEP_USER=<haiku user> haiku-bfs bash /repo/scripts/container/build-openssh.sh
# push every file under out/openssh/ with tools/push.sh (no sftp yet), then on the guest:
mkdir -p /boot/system/non-packaged/data/openssh/empty /boot/system/var/run ~/config/settings/ssh
cat key.pub >> ~/config/settings/ssh/authorized_keys     # Haiku path, not ~/.ssh
chmod 700 ~/config/settings/ssh; chmod 600 ~/config/settings/ssh/authorized_keys
/boot/system/non-packaged/bin/ssh-keygen -A               # ed25519 + mldsa44-ed25519
/boot/system/non-packaged/sbin/sshd -t && /boot/system/non-packaged/sbin/sshd
```

Add Haiku's library paths for ssh sessions (sshd doesn't run Haiku's
SetupEnvironment, and tools that set `LIBRARY_PATH` then break), at the top of
`/boot/system/settings/ssh/sshd_config`:

```
SetEnv LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib" ADDON_PATH="%A/add-ons:/boot/home/config/non-packaged/add-ons:/boot/home/config/add-ons:/boot/system/non-packaged/add-ons:/boot/system/add-ons"
```

Then kill the telnetd loop. A host `~/.ssh/config` entry makes it `ssh haiku`:

```
Host haiku
    HostName 192.168.64.4
    User <haiku user>
    IdentityFile ~/.ssh/haiku_vm_ed25519
    IdentitiesOnly yes
```

From here on, `tools/push-tree.sh out/<component> haiku` installs a whole tree.

## 6. Bootstrap packages (native gcc, make, sed, grep, …)

`pkgman` can't download yet (no TLS until step 11). Ask it for the plan, fetch on the host and drop them in:

```sh
ssh haiku 'pkgman install -y curl make gcc binutils haiku_devel gcc_syslibs_devel sed grep less findutils gawk > /tmp/plan.txt 2>&1; cat /tmp/plan.txt'
# for each "install package NAME-VERSION from repository ..." line:
curl -fLO https://eu.hpkg.haiku-os.org/haikuports/master/build-packages/packages/NAME-VERSION-arm64.hpkg   # or -any.hpkg
# (haiku_devel comes from https://eu.hpkg.haiku-os.org/haiku/master/arm64/current/packages/)
# verify against: ssh haiku 'package_repo list -v /boot/system/cache/package-repositories/HaikuPorts'
scp *.hpkg haiku:/boot/home/stage/ && ssh haiku 'mv /boot/home/stage/*.hpkg /boot/system/packages/'
```

Skip `python3.10` (broken) and install `ca_root_certificates` by hand (zstd; see findings).

## 7. OpenSSL, curl, git

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-tls.sh
tools/push-tree.sh out/tls haiku
# CA bundle (from the ca_root_certificates hpkg, extracted with the package tool):
scp CARootCertificates.pem haiku:/boot/system/non-packaged/data/ssl/
ssh haiku 'cd /boot/system/non-packaged/data/ssl && ln -sf CARootCertificates.pem cert.pem'
```

Append `scripts/guest/UserBootscript.snippet` to `~/config/settings/boot/UserBootscript`
so the clock is right after every boot.

## 8. Python 3.12

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-python.sh
tools/push-tree.sh out/python haiku
ssh haiku 'python3 -m ensurepip --upgrade && pip3 install tzdata'
```

## 9. Perl 5.42 (native, on the guest)

Needs step 6. Unpack and patch on the host, push the tree with mtimes preserved,
and build on the guest:

```sh
curl -fLO https://www.cpan.org/src/perl-5.42.2.tar.gz && tar xzf perl-5.42.2.tar.gz
(cd perl-5.42.2 && patch -p1 < ../patches/haikuports/perl-5.42.2.patchset)
# push perl-5.42.2/ to /boot/home/src/perl-5.42.2 (sftp batch of `put -p`, like push-tree.sh)
scp scripts/guest/build-perl-native.sh haiku:/boot/home/src/
ssh haiku 'cd /boot/home/src && nohup sh build-perl-native.sh > perl-build.log 2>&1 < /dev/null &'
```

`make` takes ~3 minutes on one vCPU. Perl's `ptar` then gives the guest a working tar.

## 10. Rust

Moved to its own repo: [aarch64-unknown-haiku](https://github.com/bluevisor/aarch64-unknown-haiku)
(target patch, build scripts, binaries). It builds on the cross toolchain from
step 4 and the HTTP/2 curl from step 7, and over ssh it needs the `SetEnv` from step 5.

## 11. pkgman over HTTPS

Builds on step 7 (OpenSSL + CA bundle) and on the revision-2 system packages from
[chromium.md](chromium.md) (`build-haiku-chromium-fixes.sh`). The three
packages are also in the release (for hrev60290 only), so you can skip the build
and copy those instead.

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-netssl.sh   # ~1 min
# out/haiku-system: openssl3-3.5.9-1, haiku-…-3, haiku_devel-…-3
scp out/haiku-system/openssl3-*.hpkg out/haiku-system/*-3-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./openssl3-*.hpkg ./haiku-*-3-arm64.hpkg ./haiku_devel-*-3-arm64.hpkg'
# reboot (shutdown, then UTM stop by kill + start)
# downloads must go to build-packages/, not the empty arm64/current index:
ssh haiku 'sed -i "s|^baseurl=.*|baseurl=https://eu.hpkg.haiku-os.org/haikuports/master/build-packages|" /boot/system/settings/package-repositories/HaikuPorts'
ssh haiku 'pkgman install -y m4 flex'
```

`pkgman refresh` still prints `Resource not found` for HaikuPorts, which is
expected, and stops there: refresh other repos by name (see findings). Skip `bison`: its arm64 package holds an x86_64 binary.

Then make `shutdown` and `shutdown -r` power off / reset the VM (`haiku`
revision 4, PSCI; see findings; also in the release, where it replaces rev 3).
This is the last reboot that needs UTM:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-psci.sh    # ~10 s
scp out/haiku-system/*-4-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-4-arm64.hpkg ./haiku_devel-*-4-arm64.hpkg'
# reboot once more with UTM stop by kill + start; from then on:
ssh haiku 'grep PSCI /var/log/syslog'   # arm64: PSCI shutdown/reboot via hvc
ssh haiku 'shutdown -r'                  # comes back by itself
```

Revision 5 adds two TCP fixes on top (see findings): a connection that both
sides closed reads as end-of-file instead of `ENOTCONN`, and accepted sockets
poll readable once closed. Without them every graceful Node.js http2 close
hangs. Also in the release:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-tcp.sh     # ~1 min
scp out/haiku-system/*-5-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-5-arm64.hpkg ./haiku_devel-*-5-arm64.hpkg && shutdown -r'
```

Revision 6 adds a **Natural scrolling** check box to the mouse page of the
Input preferences, on by default, so a Mac trackpad scrolls the VM the same
way as macOS (QEMU passes it on as a USB tablet/mouse wheel). It
replaces input_server, the mouse and tablet add-ons and the Input app:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-natscroll.sh # ~2 min
scp out/haiku-system/*-6-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-6-arm64.hpkg ./haiku_devel-*-6-arm64.hpkg && shutdown -r'
```

Revision 7 adds a **Dark mode** check box to the Colors tab of the Appearance
preferences. Haiku already ships a complete dark color set (the dark variant of
its defaults) but had no switch for it. Only the Appearance app changes:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-darkmode.sh  # ~1 min
scp out/haiku-system/*-7-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-7-arm64.hpkg ./haiku_devel-*-7-arm64.hpkg && shutdown -r'
```

Revision 8 fixes the **mouse wheel in terminal apps**. Terminal turned every
wheel step in a full-screen app into three Up/Down arrow keys, even when the
app had asked for mouse events, so scrolling a cmux pane walked through the
shell history. With mouse reporting on, Terminal now sends xterm's wheel
buttons instead. Only the Terminal app changes:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-wheel.sh     # ~1 min
scp out/haiku-system/*-8-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-8-arm64.hpkg ./haiku_devel-*-8-arm64.hpkg && shutdown -r'
```

Revision 9 makes **Shift+Tab** reach terminal apps. Terminal passed it
through as a plain Tab byte, so no app could tell the two apart; it now sends
xterm's back-tab (`ESC [ Z`). Only the Terminal app changes:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-haiku-backtab.sh   # ~1 min
scp out/haiku-system/*-9-arm64.hpkg haiku:/boot/home/stage/
ssh haiku 'cd /boot/home/stage && pkgman install -y ./haiku-*-9-arm64.hpkg ./haiku_devel-*-9-arm64.hpkg && shutdown -r'
```

## 12. Extra packages (diff, tar, xz, zstd, zip, nano, cmake, ninja, …)

Prebuilt in the [haiku-arm64-packages](https://github.com/bluevisor/haiku-arm64-packages)
pkgman repository (GitHub Pages). Needs step 11:

```sh
ssh haiku 'pkgman add-repo https://bluevisor.github.io/haiku-arm64-packages'
# later, to see new packages (a plain refresh stops at HaikuPorts' error):
ssh haiku 'pkgman refresh haiku-arm64-bootstrap'
ssh haiku 'pkgman install -y diffutils patch tar gzip xz_utils zstd pkgconf'
ssh haiku 'pkgman install -y bzip2 zip unzip nano ninja cmake'   # + libiconv
ssh haiku 'pkgman install -y ncurses6'   # 6.6_release: fixes the bootstrap's terminfo path
```

Without the repo's `ncurses6`, ncurses programs (nano, `clear`, Python curses)
can't find any terminfo entry; see findings.

To rebuild the packages and the index:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-core-tools.sh  # ~2 min
docker exec haiku-bfs bash /repo/scripts/container/build-dev-tools.sh   # ~8 min (cmake)
docker exec haiku-bfs bash /repo/scripts/container/make-package-repo.sh # out/repo-site
# copy out/repo-site/ into the haiku-arm64-packages checkout, push; Pages serves it
```

Both build scripts share `hpkg-common.sh`. Set `ONLY="cmake"` to rebuild a
subset of `build-dev-tools.sh`.

## 13. From non-packaged to packages

Steps 5–9 installed curl, git, OpenSSH, Python and Perl by hand into
`/boot/system/non-packaged`, which shadows packages on PATH and the library
path. The repo now has them as packages, in the HaikuPorts layout:
- OpenSSL uses `OPENSSLDIR=/boot/system/data/ssl`, and its default CA file is
  `CARootCertificates.pem` from `ca_root_certificates`.
- openssh creates its `sshd` privsep user on install.

Snapshot the disk first. Then:

```sh
ssh haiku 'pkgman install -y ca_root_certificates openssl3 curl git openssh python3.12 perl'
# sshd: point sftp at the packaged server, add RSA/ECDSA host keys, test on a spare port
ssh haiku 'sed -i "s|/boot/system/non-packaged/lib/openssh/sftp-server|/boot/system/lib/openssh/sftp-server|" /boot/system/settings/ssh/sshd_config;
           ssh-keygen -A; /boot/system/bin/sshd -t && /boot/system/bin/sshd -p 2222'
ssh -p 2222 haiku true   # must work before going on
# boot script: /boot/system/non-packaged/sbin/sshd -> /boot/system/bin/sshd, then
# retire the old files (manifests: `tar -tzf` of the release tarballs, see the script)
scp scripts/guest/retire-nonpackaged.sh haiku:
ssh -p 2222 haiku 'sh retire-nonpackaged.sh openssh.txt tls.txt python.txt perl.txt'
# restart the port-22 listener on the packaged sshd (kill the old pid, start /boot/system/bin/sshd)
```

`retire-nonpackaged.sh` moves files to `~/nonpackaged-retired/<stamp>/`
instead of deleting them, and leaves `site-packages`/`site_perl` alone. Leftovers:
- the HTTP/2 rebuild's `libnghttp2` (it isn't in the TLS tarball);
- the CA files in `non-packaged/data/ssl`;
- `pip3` launchers and other pip scripts, whose `#!` still names
  `/boot/system/non-packaged/bin/python3`. Fix them with
  `python3 -m pip install --force-reinstall --no-deps pip` and a sed for the rest.

Rust (`non-packaged/rust`) stays as it is; cargo and rustc pick up the packaged
libcurl/libssl, which have the same sonames.

Rebuild the packages with `build-stack.sh`. Perl is native: on the VM run
`PKG=1 SRCDIR=<fresh patched tree> sh scripts/guest/build-perl-native.sh`, tar
`/boot/home/perl-pkgroot`, then run `package-perl.sh` in the container.

`pkgconf` searches `develop/lib/pkgconfig` in the system and home locations.
The cross-built libraries from steps 7–8 put their `.pc` files in
`/boot/system/non-packaged/lib/pkgconfig`, so set
`PKG_CONFIG_PATH=/boot/system/non-packaged/lib/pkgconfig` to use them.

## 14. Node.js 24

Prebuilt in the pkgman repo (needs steps 11 and 12):

```sh
ssh haiku 'pkgman install -y nodejs24 make'   # make 4.4.1_release: node-gyp relies on its CXX = g++
ssh haiku 'node -e "fetch(\"https://nodejs.org/dist/index.json\").then(r => console.log(r.status))"'
ssh haiku 'npm -g install cowsay && cowsay moo'   # -g installs land in /boot/system/non-packaged
```

`npm install` with native addons (node-gyp) also needs the bootstrap `gcc`
from step 6 and `python3.12`. Without our `make`, the addon link fails with
`make: aarch64-unknown-haiku-g++: No such file or directory` (see findings).

Node has to be built on the guest: `configure`, `mksnapshot` and V8's
generators run on the target. The guest's own GCC would take ~11 h on V8, so
`tools/rcc/` sends each preprocessed C++ file to the same GCC 13.3 cross
compiler in `haiku-bfs` and gets the object back (~35 min in total):

```sh
# host: compile server (RCC_DIR = host side of a directory haiku-bfs sees as RCC_CDIR)
RCC_JOBS=12 python3 tools/rcc/rcc-server.py &         # 192.168.64.1:8766
ssh haiku 'mkdir -p /boot/home/rcc/bin /boot/home/node-build'
scp tools/rcc/c++ haiku:/boot/home/rcc/bin/
scp scripts/guest/build-node-native.sh patches/haikuports/nodejs-24.21.0.patchset \
    patches/haikuports/nodejs-24.21.0-arm64.patch haiku:/boot/home/node-build/
ssh haiku 'cd /boot/home/node-build && PATH=/boot/home/rcc/bin:$PATH bash build-node-native.sh'
scp haiku:/boot/home/node-pkgroot.tar out/ && docker cp out/node-pkgroot.tar haiku-bfs:/repo/out/
docker exec haiku-bfs bash /repo/scripts/container/package-nodejs.sh
```

The wrapper compiles locally whenever the server can't be reached or a flag
isn't on its allow-list, so a stopped server only makes the build slow.
