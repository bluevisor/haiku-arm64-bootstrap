#!/bin/bash
# Standalone cross-build of cargo for aarch64-unknown-haiku (run after build-rust.sh),
# linking the system libcurl (needs HTTP/2: cargo enables curl's http2 feature),
# OpenSSL and zlib dynamically, as the DeBeOS haiku-rust-bake does. x.py would
# build cargo "all-static", compiling OpenSSL and curl for a target they don't know.
set -euo pipefail
T=aarch64-unknown-haiku
X=/build/haiku/generated.arm64/cross-tools-arm64
SR=$X/sysroot
SY=$SR/boot/system
NP=$SY/non-packaged
BIN=/build/rust-bin
J=${J:-6}

# Snapshot stage1 (rustc for Linux + std for Haiku) so a later x.py run cannot change it mid-build.
rm -rf /build/stage1-snap && cp -a /build/rust/build/host/stage1 /build/stage1-snap
export RUSTC=/build/stage1-snap/bin/rustc
CARGO=/build/rust/build/aarch64-unknown-linux-gnu/stage0/bin/cargo

# curl-sys runs `curl-config --features` to decide whether the system libcurl
# has HTTP2 (cargo requires it); the real script is plain sh and answers truthfully.
cat > $BIN/curl-config <<SH
#!/bin/sh
exec sh $NP/bin/curl-config "\$@"
SH
chmod +x $BIN/curl-config
export PATH=$BIN:$PATH

U=AARCH64_UNKNOWN_HAIKU; L=aarch64_unknown_haiku
export CARGO_TARGET_${U}_LINKER=$BIN/haiku-rust-gcc
export CC_$L=$BIN/haiku-rust-gcc CXX_$L=$BIN/haiku-rust-g++ AR_$L=$X/bin/aarch64-unknown-haiku-ar
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_LIBDIR=$NP/lib/pkgconfig:$SY/develop/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$SR
export OPENSSL_LIB_DIR=$NP/lib OPENSSL_INCLUDE_DIR=$NP/include
export CARGO_TARGET_DIR=/build/cargo-target

(cd /build/rust && git submodule update --init --depth 1 src/tools/cargo)
cd /build/rust/src/tools/cargo
$RUSTC -V
"$CARGO" build --release --locked --target $T --bin cargo -j "$J"
out=/build/cargo-target/$T/release/cargo
file "$out"
mkdir -p /repo/out/rust && cp "$out" /repo/out/rust/cargo && $X/bin/aarch64-unknown-haiku-strip /repo/out/rust/cargo
$X/bin/aarch64-unknown-haiku-readelf -d "$out" | grep NEEDED
