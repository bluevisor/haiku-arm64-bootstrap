#!/bin/bash
# Package the Node.js that scripts/guest/build-node-native.sh built on the
# guest (its configure + mksnapshot have to run natively). Bring the install
# tree over as a tarball first:
#   host: scp haiku:/boot/home/node-pkgroot.tar out/
#         docker cp out/node-pkgroot.tar haiku-bfs:/repo/out/
# The package's own lib/ is read-only (packagefs), so npm's builtin npmrc
# points `npm -g` at /boot/system/non-packaged (bin/ there is on PATH).
# Output: /repo/out/packages/nodejs24-24.21.0-1-arm64.hpkg
set -euxo pipefail

declare -A SHA=() URL=()
source "$(dirname "$0")/hpkg-common.sh"

R=$(dest nodejs24)
tar -xf /repo/out/node-pkgroot.tar -C $R
R=$R$S
mkdir -p $R/develop/headers $R/documentation/packages
mv $R/include/node $R/develop/headers/node && rmdir $R/include
mv $R/share/man $R/documentation/man
mv $R/share/doc/node $R/documentation/packages/nodejs24
rm -rf $R/share
printf 'prefix=/boot/system/non-packaged\n' > $R/lib/node_modules/npm/npmrc
tidy $R
package $R nodejs24 24.21.0 "A JavaScript runtime built on Chrome's V8 Engine" \
	"Node.js 24 LTS with npm and corepack. Bundled V8, ICU (full), libuv, c-ares, brotli, nghttp2, zlib; links the openssl3 package. npm -g installs go to /boot/system/non-packaged." \
	"Node.js contributors, Joyent, Inc. and other Node contributors" "MIT"
