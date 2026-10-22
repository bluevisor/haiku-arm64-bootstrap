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
expected (see findings). Skip `bison`: its arm64 package holds an x86_64 binary.

## 12. Extra packages (diff, tar, xz, zstd, zip, nano, cmake, ninja, …)

Prebuilt in the [haiku-arm64-packages](https://github.com/bluevisor/haiku-arm64-packages)
pkgman repository (GitHub Pages). Needs step 11:

```sh
ssh haiku 'pkgman add-repo https://bluevisor.github.io/haiku-arm64-packages'
ssh haiku 'pkgman install -y diffutils patch tar gzip xz_utils zstd pkgconf'
ssh haiku 'pkgman install -y bzip2 zip unzip nano ninja cmake'   # + libiconv
```

ncurses programs (nano, `clear`) need `TERMINFO_DIRS`: apply
`scripts/guest/UserSetupEnvironment.snippet` (see findings for why).

To rebuild the packages and the index:

```sh
docker exec haiku-bfs bash /repo/scripts/container/build-core-tools.sh  # ~2 min
docker exec haiku-bfs bash /repo/scripts/container/build-dev-tools.sh   # ~8 min (cmake)
docker exec haiku-bfs bash /repo/scripts/container/make-package-repo.sh # out/repo-site
# copy out/repo-site/ into the haiku-arm64-packages checkout, push; Pages serves it
```

Both build scripts share `hpkg-common.sh`. Set `ONLY="cmake"` to rebuild a
subset of `build-dev-tools.sh`.

`pkgconf` searches `develop/lib/pkgconfig` in the system and home locations.
The cross-built libraries from steps 7–8 put their `.pc` files in
`/boot/system/non-packaged/lib/pkgconfig`, so set
`PKG_CONFIG_PATH=/boot/system/non-packaged/lib/pkgconfig` to use them.
