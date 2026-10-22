#!/bin/bash
# Build a pkgman repository from the packages in /repo/out/packages (from
# build-core-tools.sh), in the layout Haiku's own repositories use:
#   repo.info     name/vendor/summary/priority/baseurl/identifier/architecture
#   repo          binary index (package_repo create), with each package's checksum
#   repo.sha256   sha256 of repo, hex + newline
#   packages/<file>.hpkg
# The output is a static site. Serve it at $BASEURL (GitHub Pages:
# bluevisor/haiku-arm64-packages), then on the guest:
#   pkgman add-repo $BASEURL
#
# Needs build-bfs-shell.sh's host tools (package_repo is built here if missing).
# Output: /repo/out/repo-site
set -euxo pipefail

BASEURL=${BASEURL:-https://bluevisor.github.io/haiku-arm64-packages}
SITE=/repo/out/repo-site
T=/build/haiku/generated/objects/linux/arm64/release/tools
export LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib

[ -x $T/package_repo/package_repo ] || (cd /build/haiku/generated && jam -q '<build>package_repo')

rm -rf $SITE && mkdir -p $SITE/packages
# package_repo rejects packages whose vendor differs from the repo's, so
# openssl3-3.5.9-1 (vendor "The OpenSSL Project") stays in the release only
cp /repo/out/packages/*.hpkg $SITE/packages/
cat > $SITE/repo.info <<EOF
name haiku-arm64-bootstrap
vendor "haiku-arm64-bootstrap"
summary "Extra packages for Haiku arm64 (github.com/bluevisor/haiku-arm64-bootstrap)"
priority 1
baseurl $BASEURL
identifier tag:bluevisor.github.io,2026:repositories/haiku-arm64-packages/arm64
architecture arm64
EOF
cd $SITE
$T/package_repo/package_repo create -q repo.info packages/*.hpkg
sha256sum repo | cut -d' ' -f1 > repo.sha256
touch .nojekyll
$T/package_repo/package_repo list repo
ls -la $SITE $SITE/packages
