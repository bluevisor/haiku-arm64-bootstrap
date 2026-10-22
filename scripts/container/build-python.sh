#!/bin/bash
# Cross-build CPython 3.12.15 (HaikuPorts patchset) for Haiku arm64, with OpenSSL.
# Runs inside the build container with this repo at /repo; needs
# build-cross-tools.sh and build-tls.sh (OpenSSL in the sysroot) first.
# Output: /repo/out/python.
set -euxo pipefail

V=3.12.15
X=/build/haiku/generated.arm64/cross-tools-arm64
export PATH=$X/bin:$PATH
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
STAGE=/repo/out/python
PKG=/build/haiku/generated/objects/linux/arm64/release/tools/package/package
BP=https://eu.hpkg.haiku-os.org/haikuports/master/build-packages/packages
J=-j"$(nproc)"

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq autoconf-archive pkg-config >/dev/null 2>&1
mkdir -p /build/py /repo/out && cd /build/py
[ -f Python-$V.tar.xz ] || wget -q https://www.python.org/ftp/python/$V/Python-$V.tar.xz

# 1. Same-version Python for the build machine (cross builds require it).
if [ ! -x /opt/py312/bin/python3.12 ]; then
	rm -rf host && mkdir host && tar xJf Python-$V.tar.xz -C host
	(cd host/Python-$V && ./configure --prefix=/opt/py312 >/dev/null && make $J >/dev/null && make install >/dev/null)
fi
/opt/py312/bin/python3.12 -V

# 2. Haiku arm64 dev packages into the sysroot (runtime libs too: devel symlinks point at them).
while read -r f sum; do
	[ -f "$f" ] || wget -q -O "$f" "$BP/$f"
	echo "$sum  $f" | sha256sum -c --quiet
	LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib $PKG extract -C $SR/boot/system "$f"
done <<'EOF'
libffi-3.4.6_bootstrap-1-arm64.hpkg 56ae065ad90ade4acec944de12e24f0f78ec3659d738684b879b1a6ed881ac30
libffi_devel-3.4.6_bootstrap-1-arm64.hpkg f39e2f6c1551b57dcd0866c89c40919c98270bb9487f31d18d8f5165758c7e02
ncurses6-6.6_bootstrap-1-arm64.hpkg e2f898e011cbd09919deddf044acb3309aae1bc477ebd7be6d7df3e0648f7f7d
ncurses6_devel-6.6_bootstrap-1-arm64.hpkg 31677095a1ac64203196b3fa1d48a0a813e3672b79302563c6d205cbf79f5079
expat-2.5.0_bootstrap-1-arm64.hpkg 0765994bfac2bb4fb25149eb8f22c36165acc531de291ec38d4cf38c926807c5
expat_devel-2.5.0_bootstrap-1-arm64.hpkg 5ff4d346eb23aa173fea39265fc81698310c3f7fd5321860a31adaa003989db2
EOF

# 3. Cross build.
rm -rf Python-$V && tar xJf Python-$V.tar.xz && cd Python-$V
patch -p1 < /repo/patches/haikuports/python3.12-3.12.15.patchset
# Upstream maps Haiku for MACHDEP but not in the _host_cpu block, so a cross
# build dies with "cross build not supported for aarch64-unknown-haiku".
python3 - <<'PY'
p = "configure.ac"; s = open(p).read()
old = """	*-*-vxworks*)
		_host_cpu=$host_cpu
		;;"""
new = old + """
	*-*-haiku*)
		_host_cpu=$host_cpu
		;;"""
assert s.count(old) == 1; open(p, "w").write(s.replace(old, new))
PY
autoreconf -fi >/dev/null 2>&1
# Prefix is already non-packaged: stop the haiku install scheme from doubling it.
# Must happen before make: site.py is deep-frozen into the binary.
python3 /repo/scripts/container/fix-nonpackaged-scheme.py Lib
cat > config.site <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
EOF
export PKG_CONFIG=/bin/false
CONFIG_SITE=$PWD/config.site BASECFLAGS="-pipe -D_BSD_SOURCE" OPT="-Wall -O2" \
CPPFLAGS="-I$SR/boot/system/develop/headers/ncursesw" \
LIBFFI_CFLAGS="-I$SR/boot/system/develop/headers" LIBFFI_LIBS="-lffi" \
CURSES_CFLAGS="-I$SR/boot/system/develop/headers/ncursesw" CURSES_LIBS="-lncursesw" \
PANEL_CFLAGS="-I$SR/boot/system/develop/headers/ncursesw" PANEL_LIBS="-lpanelw" \
./configure --build=aarch64-linux-gnu --host=aarch64-unknown-haiku \
	--prefix=/boot/system/non-packaged \
	--with-build-python=/opt/py312/bin/python3.12 \
	--enable-shared --without-static-libpython --with-ensurepip=no \
	--with-system-expat --with-openssl=$NP --with-readline=no \
	--with-tzpath=/boot/system/data/zoneinfo > /repo/out/python-configure.log 2>&1
make $J > /repo/out/python-make.log 2>&1
rm -rf $STAGE && make install DESTDIR=$STAGE > /repo/out/python-install.log 2>&1

# 4. Trim: the test suite is ~half the size and isn't needed on the VM.
L=$STAGE/boot/system/non-packaged/lib/python3.12
rm -rf $L/test $L/idlelib/idle_test $L/tkinter/test
find $STAGE -type f \( -name '*.so' -o -name '*.so.*' -o -path '*/bin/python3.12' \) \
	-exec sh -c 'file "$1" | grep -q ELF && aarch64-unknown-haiku-strip --strip-unneeded "$1"' _ {} \;
echo "== modules that did not build:"
grep -A40 -E "^The necessary bits|^Following modules built successfully|missing|failed to build" /repo/out/python-make.log | grep -v '^\s*$' | head -30 || true
du -sh $STAGE; find $STAGE -type f | wc -l; find $STAGE -type l -exec ls -l {} \; | awk '{print $(NF-2), $NF}'

