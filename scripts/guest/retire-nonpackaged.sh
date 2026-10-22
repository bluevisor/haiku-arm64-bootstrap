#!/bin/sh
# Move hand-installed files out of /boot/system/non-packaged once the same
# software is installed as a package (they shadow packaged files: non-packaged
# comes first on PATH and the library path).
#
#   retire-nonpackaged.sh MANIFEST...
#
# A manifest lists paths relative to /boot/system/non-packaged, one per line,
# e.g. from a release tarball: tar -tzf X.tar.gz | sed -n 's|^boot/system/non-packaged/||p'
# Files are moved (not deleted) to /boot/home/nonpackaged-retired/<stamp>/,
# keeping their layout; put one back with mv to undo. Python site-packages
# and Perl site_perl (pip/cpan installs) are left alone.
set -e
NP=/boot/system/non-packaged
DEST=/boot/home/nonpackaged-retired/$(date +%Y%m%d-%H%M%S)
moved=0 missing=0
for m in "$@"; do
	while IFS= read -r p; do
		case $p in ''|*/|*site-packages*|*site_perl*) continue ;; esac
		if [ -e "$NP/$p" ] || [ -L "$NP/$p" ]; then
			mkdir -p "$DEST/$(dirname "$p")"
			mv "$NP/$p" "$DEST/$p"
			moved=$((moved + 1))
		else
			missing=$((missing + 1))
		fi
	done < "$m"
done
# drop directories the moves left empty (never non-packaged itself)
find "$NP" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
echo "moved $moved files to $DEST ($missing already absent)"
