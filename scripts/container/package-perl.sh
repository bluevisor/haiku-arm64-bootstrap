#!/bin/bash
# Package the Perl that scripts/guest/build-perl-native.sh built on the guest
# with PKG=1 (Perl's Configure has to run natively). Bring its DESTDIR over
# as a tarball first:
#   guest: tar -C /boot/home/perl-pkgroot -cf /boot/home/perl-pkgroot.tar .
#   host:  scp haiku:/boot/home/perl-pkgroot.tar out/
#          docker cp out/perl-pkgroot.tar haiku-bfs:/repo/out/
# Output: /repo/out/packages/perl-5.42.2-1-arm64.hpkg
set -euxo pipefail

declare -A SHA=() URL=()
source "$(dirname "$0")/hpkg-common.sh"

R=$(dest perl)
tar -xf /repo/out/perl-pkgroot.tar -C $R
R=$R$S
# site_perl lives in non-packaged; a package must not ship that tree
rm -rf $R/non-packaged
tidy $R
package $R perl 5.42.2 "Larry Wall's Practical Extraction and Report Language" \
	"Perl 5.42 with threads and a shared libperl. cpan installs go to /boot/system/non-packaged/lib/perl5/site_perl." \
	"1987-2026 Larry Wall and others" "GNU GPL v1" "Artistic"
