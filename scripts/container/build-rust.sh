#!/bin/bash
# Build a Haiku-hosted Rust toolchain (rustc + rust-std) for aarch64-unknown-haiku,
# cross-compiled from aarch64 Linux with Rust's own bootstrap.
#
# Needs build-cross-tools.sh (cross gcc + sysroot incl. gcc_syslibs) and
# build-tls.sh (OpenSSL/curl in the sysroot, for cargo). Output:
# /repo/out/rust/{rustc,rust-std}-nightly-aarch64-unknown-haiku.tar.gz
#
# Phases (~35 min on 12 cores, ~28 GB RAM recommended):
#   std   x.py build library  -- LLVM for Linux, stage1 rustc, std for Haiku (~16 min)
#   dist  x.py dist rustc rust-std -- LLVM cross-built for Haiku, Haiku-hosted rustc (~17 min)
#
# Prior art: felipedbene/Haiku-Graviton (graviton/scripts/haiku-rust-bake) and
# rainygirl/renkuos-rchromium-arm64 (rust/) did the same; this follows their
# approach. aarch64-unknown-haiku is not an upstream target.
set -euxo pipefail

RUST_COMMIT=${RUST_COMMIT:-1a2c4797ef2570bd76ca5dee34449169bc7dc457}   # nightly 2026-10-22, 1.101.0
T=aarch64-unknown-haiku
X=/build/haiku/generated.arm64/cross-tools-arm64
SR=$X/sysroot
NP=$SR/boot/system/non-packaged
BIN=/build/rust-bin
OUT=/repo/out/rust

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake ninja-build curl git python3 g++ pkg-config >/dev/null 2>&1

mkdir -p /build/rust && cd /build/rust
[ -d .git ] || { git init -q . && git remote add origin https://github.com/rust-lang/rust.git; }
if [ "$(git rev-parse HEAD 2>/dev/null)" != "$RUST_COMMIT" ]; then
	git fetch -q --depth 1 origin "$RUST_COMMIT" && git checkout -q FETCH_HEAD
fi
# File::lock must be wired to flock() on Haiku (rust-lang/rust#164031, nightly >= 2026-10-13);
# otherwise it returns Unsupported and cargo silently skips its locking.
[ "$(grep -c 'target_os = "haiku"' library/std/src/sys/fs/unix.rs)" -ge 10 ]

# The target: AArch64 ELF layout (as aarch64-unknown-freebsd) + the existing Haiku options.
cat > compiler/rustc_target/src/spec/targets/aarch64_unknown_haiku.rs <<'EOF'
use crate::spec::{Arch, StackProbeType, Target, TargetMetadata, TargetOptions, base};

pub(crate) fn target() -> Target {
    Target {
        llvm_target: "aarch64-unknown-haiku".into(),
        metadata: TargetMetadata {
            description: Some("ARM64 Haiku".into()),
            tier: Some(3),
            host_tools: Some(true),
            std: Some(true),
        },
        pointer_width: 64,
        // AArch64 ELF layout, as aarch64-unknown-freebsd.
        data_layout: "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32".into(),
        arch: Arch::AArch64,
        options: TargetOptions {
            features: "+v8a".into(),
            max_atomic_width: Some(128),
            stack_probes: StackProbeType::Inline,
            // Haiku executables are ET_DYN; the runtime loader expects PIE,
            // the same as on x86_64 Haiku.
            position_independent_executables: true,
            ..base::haiku::opts()
        },
    }
}
EOF
python3 - <<'PY'
p = "compiler/rustc_target/src/spec/mod.rs"; s = open(p).read()
anchor = '    ("i686-unknown-haiku", i686_unknown_haiku),'
if "aarch64_unknown_haiku" not in s:
    assert s.count(anchor) == 1
    open(p, "w").write(s.replace(anchor, '    ("aarch64-unknown-haiku", aarch64_unknown_haiku),\n' + anchor))
PY

# Cross compiler wrappers. Haiku keeps BSD/socket/glibc-compat functions in
# libbsd/libnetwork/libgnu; they must follow rustc's own object list.
mkdir -p $BIN
for t in gcc g++; do
	cat > $BIN/haiku-rust-$t <<EOF
#!/bin/sh
exec $X/bin/aarch64-unknown-haiku-$t -D_DEFAULT_SOURCE -L$NP/lib "\$@" -lbsd -lnetwork -lgnu
EOF
	chmod +x $BIN/haiku-rust-$t
done

cat > bootstrap.toml <<EOF
change-id = "ignore"

[llvm]
# Must be false: when cross-building host tools, rustc_llvm rewrites the build
# host's llvm-config paths to the target's, which only works if both LLVMs are
# built locally the same way (see haiku-rust-bake for the full explanation).
download-ci-llvm = false
ninja = true
link-jobs = 4

[build]
build = "aarch64-unknown-linux-gnu"
host = ["$T"]
target = ["$T"]
docs = false
compiler-docs = false
extended = false
tools = ["rustdoc"]   # cargo is built separately (build-cargo.sh), linking system libcurl
locked-deps = true
vendor = false
jobs = $(nproc)

[rust]
channel = "nightly"
download-rustc = false
debug = false
debuginfo-level = 0
backtrace = true
incremental = false

[dist]
compression-formats = ["gz"]

[target.aarch64-unknown-linux-gnu]
cc = "gcc"
cxx = "g++"

[target.$T]
cc = "$BIN/haiku-rust-gcc"
cxx = "$BIN/haiku-rust-g++"
linker = "$BIN/haiku-rust-gcc"
ar = "$X/bin/aarch64-unknown-haiku-ar"
ranlib = "$X/bin/aarch64-unknown-haiku-ranlib"
crt-static = false
EOF

# stage0 is an upstream nightly that has never heard of this target.
export BOOTSTRAP_SKIP_TARGET_SANITY=1
python3 x.py build library --target $T
python3 x.py dist rustc rust-std

mkdir -p $OUT && cp build/dist/rustc-nightly-$T.tar.gz build/dist/rust-std-nightly-$T.tar.gz $OUT/
ls -la $OUT
