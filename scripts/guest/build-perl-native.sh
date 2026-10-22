#!/bin/sh
# Native Perl 5.42.2 build on Haiku arm64 (HaikuPorts patchset already applied).
# Flags follow dev-lang/perl/perl-5.42.2.recipe.
#   default: install into /boot/system/non-packaged (guide step 9)
#   PKG=1:   the package layout (prefix /boot/system, site_perl in
#            non-packaged), installed into DESTDIR (default
#            /boot/home/perl-pkgroot) for scripts/container/package-perl.sh.
#            Use a fresh source tree: an existing config.sh is reused.
set -e
V=5.42.2
SV=5.42
SRCDIR=${SRCDIR:-/boot/home/src/perl-$V}
if [ -n "$PKG" ]; then
	P=/boot/system
	SITE=/boot/system/non-packaged
	DEST=${DESTDIR:-/boot/home/perl-pkgroot}
else
	P=/boot/system/non-packaged
	SITE=$P
	DEST=
fi
cd "$SRCDIR"
started=$(date +%s)
# Over ssh LIBRARY_PATH is empty, and perl's makefile runs miniperl with
# LIBRARY_PATH=$PWD:$LIBRARY_PATH -- on Haiku a set LIBRARY_PATH replaces the
# default search path, so libnetwork.so etc. would not be found.
export LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"

[ -f config.sh ] && [ -f Makefile ] || ./Configure \
	-Dprefix=$P \
	-Dprivlib=$P/lib/perl5/$V \
	-Dsiteprefix=$SITE \
	-Dsitelib=$SITE/lib/perl5/site_perl/$SV \
	-Dvendorprefix=$P \
	-Dvendorlib=$P/lib/perl5/vendor_perl/$SV \
	-Dman1dir=none -Dman3dir=none \
	-Dsiteman1dir=none -Dsiteman3dir=none \
	-Dvendorman1dir=none -Dvendorman3dir=none \
	-Uusenm -Duseshrplib -Dusethreads -Uusemymalloc \
	-Dlibpth="/boot/system/develop/lib /boot/system/lib $SITE/lib" \
	-Dusrinc=/boot/system/develop/headers/posix \
	-Dlocinc=/boot/system/develop/headers \
	-Dlibc=/boot/system/lib/libroot.so \
	-Dlibs=-lnetwork -Dcc=gcc -Dld=gcc \
	-Ud_link -Ddont_use_nlink -Ud_syserrlst \
	-Dldlibpthname=LIBRARY_PATH \
	-Dusesitecustomize \
	-de

# same fix as the recipe: don't hard-code /bin/sed
sed -i -e 's/LOC_SED\s*"\/bin\/sed/LOC_SED "sed/' config.h

# Configure bakes "LDLIBPTH = LIBRARY_PATH=<builddir>" into the makefiles when
# LIBRARY_PATH was empty; append the runtime value so libnetwork.so etc. resolve.
for f in makefile Makefile pod/Makefile; do
	sed -i "s|^LDLIBPTH = LIBRARY_PATH=$PWD\$|LDLIBPTH = LIBRARY_PATH=$PWD:\$(LIBRARY_PATH)|" $f
done

echo "== CONFIGURE_DONE after $(( $(date +%s) - started ))s"
make -j"${JOBS:-8}"
echo "== MAKE_DONE after $(( $(date +%s) - started ))s"
LIBRARY_PATH=$PWD:$LIBRARY_PATH ./perl -Ilib -V:archname -V:version -e 'print "smoke: ", join(",", map { $_ * 2 } 1..3), "\n"'
if [ -n "$DEST" ]; then
	rm -rf "$DEST"
	make install DESTDIR="$DEST"
else
	make install
fi
# with -Ddont_use_nlink installperl copies perl/perlthanks and drops the exec bit
chmod 755 $DEST$P/bin/perl $DEST$P/bin/perlthanks
echo "== BUILD_OK"
