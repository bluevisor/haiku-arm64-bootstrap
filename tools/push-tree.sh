#!/bin/bash
# push-tree.sh STAGE_DIR [SSH_HOST]
#
# Copy a staged install tree (e.g. out/tls/boot/system/non-packaged/...) onto a
# Haiku guest over SFTP, preserving symlinks, then verify every file's SHA-256.
# The guest has no tar, and scp/sftp copy symlink targets in full, so regular
# files go up in one `sftp -b` batch and links are recreated over ssh.
#
#   tools/push-tree.sh out/tls haiku
set -euo pipefail
src=$(cd "$1" && pwd)
host=${2:-haiku}
batch=$(mktemp)
trap 'rm -f "$batch"' EXIT

cd "$src"
{
	find . -type d | sort | while read -r d; do [ "$d" = . ] || echo "-mkdir \"${d#.}\""; done
	find . -type f | sort | while read -r f; do echo "put -p \"$f\" \"${f#.}\""; done
} > "$batch"
echo "pushing $(find . -type f | wc -l | tr -d ' ') files from $src to $host"
sftp -q -b "$batch" "$host" >/dev/null

links=$(find . -type l | while read -r l; do printf "ln -sf '%s' '%s'; " "$(readlink "$l")" "${l#.}"; done)
[ -n "$links" ] && ssh "$host" "$links"

local_sums=$(find . -type f | sed 's|^\.||' | sort | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 ".$f" | cut -d' ' -f1)" "$f"; done)
remote_sums=$(find . -type f | sed 's|^\.||' | sort | ssh "$host" 'while read -r f; do sha256sum "$f"; done')
if [ "$local_sums" = "$remote_sums" ]; then
	echo "verified: all files match"
else
	diff <(echo "$local_sums") <(echo "$remote_sums") | head
	echo "MISMATCH" >&2
	exit 1
fi
