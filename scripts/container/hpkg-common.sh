# Shared helpers for the build-*-tools.sh scripts: cross-build a source tree
# for Haiku arm64 and turn its install tree into a .hpkg. Source this after
# declaring the SHA and URL associative arrays (tarball -> sha256 / base URL).
#
# Layout and steps follow HaikuPorts (runConfigure, prepareInstalledDevelLib,
# fixPkgconfig). Packages are zlib-compressed: the arm64 packagefs cannot
# read zstd.

X=/build/haiku/generated.arm64/cross-tools-arm64
export PATH=$X/bin:$PATH
SR=$X/sysroot
H=aarch64-unknown-haiku
HP=/build/haikuports
PATCHES=/repo/patches/haikuports
SRC=/build/core
OUT=${OUT:-/repo/out/packages}
J=-j"$(nproc)"
REV=1
S=/boot/system

mkdir -p $SRC $OUT

pkgtool() {
	LD_LIBRARY_PATH=/build/haiku/generated/objects/linux/lib \
		/build/haiku/generated/objects/linux/arm64/release/tools/package/package "$@"
}

# unpack <archive>: verified fresh source tree in $SRC/build, cwd set to it
unpack() {
	local d=${1%.tar.*}
	d=${d%.zip}
	cd $SRC
	[ -f "$1" ] || wget -q -T 60 "${URL[$1]}/$1"
	echo "${SHA[$1]}  $1" | sha256sum -c -
	rm -rf "$SRC/build/$d" && mkdir -p "$SRC/build"
	case $1 in
	*.zip) unzip -q "$1" -d "$SRC/build" ;;
	*) tar xf "$1" -C "$SRC/build" ;;
	esac
	cd "$SRC/build/$d"
}

# HaikuPorts' runConfigure directory set for the system package location
haiku_configure() {
	local name=$1; shift
	./configure --host=$H --build="$(uname -m)-unknown-linux-gnu" \
		--prefix=$S --exec-prefix=$S --bindir=$S/bin --sbindir=$S/bin \
		--libdir=$S/lib --libexecdir=$S/lib --includedir=$S/develop/headers \
		--datarootdir=$S/data --datadir=$S/data --sysconfdir=$S/settings \
		--localstatedir=$S/var --sharedstatedir=$S/var/com \
		--mandir=$S/documentation/man --infodir=$S/documentation/info \
		--docdir=$S/documentation/packages/$name "$@"
}

# CMake toolchain file for the cross compiler and sysroot
TOOLCHAIN=$SRC/haiku-arm64.cmake
cat > $TOOLCHAIN <<EOF
set(CMAKE_SYSTEM_NAME Haiku)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_SYSROOT $SR)
set(CMAKE_C_COMPILER $X/bin/$H-gcc)
set(CMAKE_CXX_COMPILER $X/bin/$H-g++)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# dest <name>: clean DESTDIR for a package; prints the package root
dest() {
	rm -rf "$SRC/dest/$1" && mkdir -p "$SRC/dest/$1"
	echo "$SRC/dest/$1"
}

# tidy <root>: Haiku layout fixes (HaikuPorts prepareInstalledDevelLib,
# fixPkgconfig), drop libtool/charset/info-dir files, strip ELF files
tidy() {
	local r=$1 f so
	rm -f "$r"/lib/*.la "$r"/lib/charset.alias "$r"/documentation/info/dir
	for f in "$r"/lib/lib*.so; do
		[ -L "$f" ] || continue
		so=$($H-readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		mkdir -p "$r/develop/lib"
		rm "$f" && ln -s "../../lib/$so" "$r/develop/lib/${f##*/}"
	done
	if [ -d "$r/lib/pkgconfig" ]; then
		mkdir -p "$r/develop/lib/pkgconfig"
		mv "$r"/lib/pkgconfig/*.pc "$r/develop/lib/pkgconfig/"
		rmdir "$r/lib/pkgconfig"
	fi
	# also .pc files installed straight into develop/lib/pkgconfig (ncurses)
	if compgen -G "$r/develop/lib/pkgconfig/*.pc" >/dev/null; then
		sed -i --follow-symlinks "s|^libdir=.*|libdir=$S/develop/lib|" "$r"/develop/lib/pkgconfig/*.pc
		# headers moved to develop/headers (OpenSSL installs to $prefix/include)
		sed -i --follow-symlinks -E \
			"s#^includedir=(\\\$\\{prefix\\}|$S)/include[[:space:]]*\$#includedir=$S/develop/headers#" \
			"$r"/develop/lib/pkgconfig/*.pc
	fi
	find "$r" -type f -exec sh -c \
		'head -c4 "$1" | grep -q "^.ELF" && '$H'-strip --strip-unneeded "$1"' _ {} \;
	rmdir "$r"/lib 2>/dev/null || true
}

# to_sysroot <root>: install a tidied package's libraries and headers into the
# sysroot, for later builds to link against (the cross linker searches
# develop/lib, so a plain `make install DESTDIR=$SR` is not enough)
to_sysroot() {
	local d
	for d in lib develop; do
		[ -d "$1/$d" ] && cp -a "$1/$d" $SR/boot/system/
	done
	return 0
}

# package <root> <name> <version> <summary> <description> <copyright> <licenses...>
# provides: <name>, cmd: per bin/ entry, lib:/devel: per shared library (at
# the library's own version, e.g. libpkgconf.so.7.0.0 -> 7.0.0 compat >= 7).
# requires: haiku, plus lib: for every NEEDED library from another package.
# Optional env: REV (package revision), ARCH (default arm64; "any" for data),
# EXTRA_PROVIDES (raw provides lines), EXTRA_REQUIRES (more requires
# entries), EXTRA_INFO (raw .PackageInfo text:
# users, groups, global_writable_files, post_install_scripts, ...).
package() {
	local r=$1 name=$2 ver=$3 summary=$4 desc=$5 copy=$6; shift 6
	local arch=${ARCH:-arm64}
	local f b so lib libver prov req=() l
	prov="	$name = $ver compat >= ${ver%%.*}"
	for f in "$r"/bin/*; do
		[ -e "$f" ] || continue
		b=${f##*/}
		prov+=$'\n'"	cmd:${b//-/_} = $ver compat >= ${ver%%.*}"
	done
	for f in "$r"/lib/lib*.so.*; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		so=$($H-readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
		lib=${so%%.so*}; libver=${f##*.so.}
		prov+=$'\n'"	lib:$lib = $libver compat >= ${so##*.so.}"
		[ -e "$r/develop/lib/$lib.so" ] && prov+=$'\n'"	devel:$lib = $libver compat >= ${so##*.so.}"
	done
	while IFS= read -r -d '' f; do
		head -c4 "$f" | grep -q '^.ELF' || continue
		for l in $($H-readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(lib[^.]*\)\.so.*\]/\1/p'); do
			case $l in libroot|libbe|libnetwork|libbnetapi|libbsd|libgnu) continue ;; # haiku
			esac
			# this package (anywhere: libperl.so lives in perl5/.../CORE)
			[ -n "$(find "$r" -name "$l.so*" -print -quit)" ] && continue
			req+=("lib:$l")
		done
	done < <(find "$r" -type f -print0)
	[ -z "${EXTRA_PROVIDES:-}" ] || prov+=$'\n'"$EXTRA_PROVIDES"
	req+=(${EXTRA_REQUIRES:-})
	local licenses=""
	for l in "$@"; do licenses+=" \"$l\""; done
	{
		printf 'name\t\t\t%s\nversion\t\t\t%s-%s\narchitecture\t%s\n' "$name" "$ver" $REV $arch
		printf 'summary\t\t\t"%s"\ndescription\t\t"%s"\n' "$summary" "$desc"
		printf 'packager\t\t"haiku-arm64-bootstrap"\nvendor\t\t\t"haiku-arm64-bootstrap"\n'
		printf 'copyrights\t\t{ "%s" }\nlicenses\t\t{%s }\n' "$copy" "$licenses"
		printf 'provides {\n%s\n}\n' "$prov"
		printf 'requires {\n\thaiku\n'
		[ ${#req[@]} -eq 0 ] || printf '\t%s\n' $(printf '%s\n' "${req[@]}" | sort -u)
		printf '}\n'
		[ -z "${EXTRA_INFO:-}" ] || printf '%s\n' "$EXTRA_INFO"
	} > "$r/.PackageInfo"
	cat "$r/.PackageInfo"
	(cd "$r" && pkgtool create -q -z zlib -i .PackageInfo "$OUT/$name-$ver-$REV-$arch.hpkg")
}
