# Third-party software

The release binaries are builds of the following upstream projects, unmodified
except for the listed patches. The exact upstream source archives are attached
to the same release (`sources-*.tar*`), with their SHA-256 in `SHA256SUMS`.

| Component | Version | License | Patches |
|---|---|---|---|
| OpenSSH portable | 10.6p1 | BSD-style (see `LICENCE` in source) | HaikuPorts `openssh-10.6p1.patchset` |
| OpenSSL | 3.5.9 | Apache-2.0 | new `Configurations/60-haiku-aarch64.conf` (in `build-tls.sh`) |
| curl | 8.23.0 | curl (MIT-style) | HaikuPorts `curl-8.23.0.patchset` |
| git | 2.56.0 | **GPL-2.0** | HaikuPorts `git-2.56.0.patchset` |
| CPython | 3.12.15 | PSF-2.0 | HaikuPorts `python3.12-3.12.15.patchset`, `fix-nonpackaged-scheme.py`, configure.ac `_host_cpu` fix (in `build-python.sh`) |
| Perl | 5.42.2 | **GPL-1.0+ or Artistic-1.0** | HaikuPorts `perl-5.42.2.patchset`, makefile `LDLIBPTH` fix (in `build-perl-native.sh`) |
| Mozilla CA certificates | 2025-12-02 (HaikuPorts `ca_root_certificates`) | MPL-2.0 | none |
| zlib, libffi, ncurses, expat | Haiku bootstrap packages | zlib / MIT / MIT / MIT | linked at runtime only, not redistributed |

The HaikuPorts patchsets in `patches/haikuports/` come from
<https://github.com/haikuports/haikuports> (MIT; individual patches credit their authors).

Haiku's BFS sources patched by `patches/bfs-resize-fixes.patch` are MIT
(<https://github.com/haiku/haiku>, commit `b33d698431f0`).

The scripts, tools and documentation in this repository are MIT (`LICENSE`).
