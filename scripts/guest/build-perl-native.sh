#!/bin/sh
# Native Perl 5.42.2 build on Haiku arm64 (HaikuPorts patchset already applied).
# Flags follow dev-lang/perl/perl-5.42.2.recipe, with prefix /boot/system/non-packaged.
set -e
P=/boot/system/non-packaged
V=5.42.2
SV=5.42
cd /boot/home/src/perl-$V
started=$(date +%s)
# Over ssh LIBRARY_PATH is empty, and perl's makefile runs miniperl with
# LIBRARY_PATH=$PWD:$LIBRARY_PATH -- on Haiku a set LIBRARY_PATH replaces the
# default search path, so libnetwork.so etc. would not be found.
export LIBRARY_PATH="%A/lib:/boot/home/config/non-packaged/lib:/boot/home/config/lib:/boot/system/non-packaged/lib:/boot/system/lib"

[ -f config.sh ] && [ -f Makefile ] || ./Configure \
	-Dprefix=$P \
	-Dprivlib=$P/lib/perl5/$V \
	-Dsiteprefix=$P \
	-Dsitelib=$P/lib/perl5/site_perl/$SV \
	-Dvendorprefix=$P \
	-Dvendorlib=$P/lib/perl5/vendor_perl/$SV \
	-Dman1dir=none -Dman3dir=none \
	-Dsiteman1dir=none -Dsiteman3dir=none \
	-Dvendorman1dir=none -Dvendorman3dir=none \
	-Uusenm -Duseshrplib -Dusethreads -Uusemymalloc \
	-Dlibpth="/boot/system/develop/lib /boot/system/lib $P/lib" \
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
make
echo "== MAKE_DONE after $(( $(date +%s) - started ))s"
LIBRARY_PATH=$PWD:$LIBRARY_PATH ./perl -Ilib -V:archname -V:version -e 'print "smoke: ", join(",", map { $_ * 2 } 1..3), "\n"'
make install
# with -Ddont_use_nlink installperl copies perl/perlthanks and drops the exec bit
chmod 755 $P/bin/perl $P/bin/perlthanks
echo "== BUILD_OK"
