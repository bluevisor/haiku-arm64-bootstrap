#!/bin/bash
# Find the network printers the Mac sees over Bonjour and, optionally, add
# them to the Haiku VM.
#
#   scripts/host/find-printers.sh                    list them
#   scripts/host/find-printers.sh --add [options]    also add them to the VM
#
# Options:
#   --host H        ssh host of the VM (default haiku-dbg)
#   --default NAME  make NAME the VM's default printer
#   --only REGEX    only printers whose name matches REGEX (grep -E)
#   --skip REGEX    leave out printers whose name matches REGEX
#   --replace       re-create printers that already exist on the VM
#   --shared        include queues another Mac shares ("Name @ Computer"),
#                   which are left out by default
#   --wait SECONDS  how long to browse (default 4)
#
# The VM sits behind QEMU's user-mode NAT, which passes no multicast, so it
# cannot browse for printers itself: the Mac browses (dns-sd), resolves each
# printer to an IPv4 address and hands Haiku an ipp:// or ipps:// URI. DHCP
# can move a printer to a new address; run this again (with --replace) then.
#
# Driver choice, from the printer's advertised formats (TXT pdl=):
#   application/postscript -> "PS Compatible"
#   image/pwg-raster       -> "IPP Everywhere" (PWG raster, patch 0021)
#   anything else (only image/urf or vendor formats) -> skipped, no driver
# The URI is plain ipp:// when the printer answers IPP over HTTP, and
# ipps:// (TLS) on the same port when it refuses with "426 Upgrade
# Required" (Epson) or does not answer; TLS on the advertised _ipps port is
# the last resort (some, e.g. Canon SELPHY, fail the TLS handshake there).
#
# Adding needs printerctl on the VM; it is built from
# guest-tools/printerctl/printerctl.cpp when missing.
set -euo pipefail

HOST=haiku-dbg
ADD=0
DEFAULT=
ONLY=
SKIP=
REPLACE=0
SHARED=0
WAIT=4
while [ $# -gt 0 ]; do
	case "$1" in
		--add) ADD=1 ;;
		--host) HOST=$2; shift ;;
		--default) DEFAULT=$2; shift ;;
		--only) ONLY=$2; shift ;;
		--skip) SKIP=$2; shift ;;
		--replace) REPLACE=1 ;;
		--shared) SHARED=1 ;;
		--wait) WAIT=$2; shift ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run dns-sd (which never exits on its own) for a few seconds
dnssd() {
	local out=$1; shift
	dns-sd "$@" > "$out" 2>&1 &
	local pid=$!
	sleep "$WAIT"
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

browse() {
	# instance names, which may contain spaces, start at field 7
	awk '$2 == "Add" { n = $7; for (i = 8; i <= NF; i++) n = n " " $i; print n }' "$1" \
		| sort -u
}

dnssd "$TMP/ipp" -B _ipp._tcp local &
dnssd "$TMP/ipps" -B _ipps._tcp local &
wait
browse "$TMP/ipp" > "$TMP/names"
browse "$TMP/ipps" > "$TMP/tls-names"

if [ ! -s "$TMP/names" ]; then
	echo "no IPP printers found" >&2
	exit 1
fi

# resolve every instance (host, port, TXT) in parallel
i=0
while IFS= read -r name; do
	i=$((i + 1))
	printf '%s\n' "$name" > "$TMP/name.$i"
	dnssd "$TMP/ipp.$i" -L "$name" _ipp._tcp local &
	if grep -qxF -- "$name" "$TMP/tls-names"; then
		dnssd "$TMP/ipps.$i" -L "$name" _ipps._tcp local &
	fi
done < "$TMP/names"
wait
count=$i

# hostname -> IPv4
for ((i = 1; i <= count; i++)); do
	target=$(grep -o 'can be reached at [^ ]*' "$TMP/ipp.$i" | head -1 \
		| sed 's/can be reached at //') || true
	host=${target%:*}
	[ -n "$host" ] || continue
	printf '%s\n' "$host" > "$TMP/host.$i"
	dnssd "$TMP/addr.$i" -G v4 "$host" &
done
wait

txt() {	# txt <file> <key>
	grep -o " $2=[^ ]*" "$1" | head -1 | sed "s/^ $2=//"
}

be16() {	# two-byte big-endian length, as printf escapes
	printf '\\x%02x\\x%02x' $(($1 >> 8)) $(($1 & 255))
}

# HTTP status of an IPP Get-Printer-Attributes over plain HTTP
probe() {	# probe <address> <port> <resource path>
	local uri="ipp://$1:$2/$3"
	local request
	request='\x01\x01\x00\x0b\x00\x00\x00\x01\x01'
	request+='\x47\x00\x12attributes-charset\x00\x05utf-8'
	request+='\x48\x00\x1battributes-natural-language\x00\x02en'
	request+="\\x45\\x00\\x0bprinter-uri$(be16 ${#uri})$uri\\x03"
	printf "$request" > "$TMP/request"
	curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
		-H 'Content-Type: application/ipp' --data-binary @"$TMP/request" \
		"http://$1:$2/$3" || true
}

printf '%-34s %-15s %-15s %s\n' NAME ADDRESS DRIVER URI
: > "$TMP/add"
for ((i = 1; i <= count; i++)); do
	name=$(cat "$TMP/name.$i")
	# Haiku printer names are folder names: no "/", no Bonjour id suffix
	label=$(printf '%s' "$name" | sed -E 's/ \[[0-9A-Fa-f]+\]$//; s#/#-#g')
	[ -n "$ONLY" ] && ! printf '%s' "$label" | grep -Eq -- "$ONLY" && continue
	[ -n "$SKIP" ] && printf '%s' "$label" | grep -Eq -- "$SKIP" && continue
	[ "$SHARED" = 0 ] && [[ "$label" == *" @ "* ]] && continue

	[ -f "$TMP/host.$i" ] || { printf '%-34s (did not resolve)\n' "$label"; continue; }
	address=$(awk '$2 == "Add" && $6 ~ /^[0-9.]+$/ { print $6; exit }' "$TMP/addr.$i")
	[ -n "$address" ] || { printf '%-34s (no IPv4 address)\n' "$label"; continue; }

	target=$(grep -o 'can be reached at [^ ]*' "$TMP/ipp.$i" | head -1 \
		| sed 's/can be reached at //')
	port=${target##*:}
	rp=$(txt "$TMP/ipp.$i" rp)
	pdl=$(txt "$TMP/ipp.$i" pdl)
	rp=${rp:-ipp/print}
	case $(probe "$address" "$port" "$rp") in
		200) uri="ipp://$address:$port/$rp" ;;
		426) uri="ipps://$address:$port/$rp" ;;
		*)
			uri="ipps://$address:$port/$rp"
			tls=
			if [ -f "$TMP/ipps.$i" ]; then
				tls=$(grep -o 'can be reached at [^ ]*' "$TMP/ipps.$i" | head -1 \
					| sed 's/can be reached at //') || true
			fi
			[ -n "$tls" ] && uri="ipps://$address:${tls##*:}/$rp"
			;;
	esac

	case ",$pdl," in
		*,application/postscript,*) driver="PS Compatible" ;;
		*,image/pwg-raster,*) driver="IPP Everywhere" ;;
		*) driver= ;;
	esac
	if [ -z "$driver" ]; then
		printf '%-34s %-15s %-15s %s\n' "$label" "$address" "-" "no Haiku driver for: $pdl"
		continue
	fi
	printf '%-34s %-15s %-15s %s\n' "$label" "$address" "$driver" "$uri"
	printf '%s\t%s\t%s\n' "$label" "$driver" "$uri" >> "$TMP/add"
done

[ "$ADD" = 1 ] || exit 0

# printerctl on the VM: build it from guest-tools when missing
PATH_VM='PATH=$PATH:$HOME/config/non-packaged/bin'
if ! ssh "$HOST" "$PATH_VM; command -v printerctl" > /dev/null 2>&1; then
	echo "building printerctl on $HOST"
	scp -q "$REPO/guest-tools/printerctl/printerctl.cpp" "$HOST:/tmp/printerctl.cpp"
	ssh "$HOST" 'mkdir -p ~/config/non-packaged/bin && g++ -O2 -Wall \
		-I/boot/system/develop/headers/private/print /tmp/printerctl.cpp -lbe \
		-o ~/config/non-packaged/bin/printerctl'
fi

if ! ssh "$HOST" 'for d in ~/config/non-packaged/add-ons/Print /boot/system/add-ons/Print; do
		[ -e "$d/IPP Everywhere" ] && exit 0; done; exit 1'; then
	echo "warning: the IPP Everywhere driver is not installed on $HOST" >&2
fi

existing=$(ssh "$HOST" "$PATH_VM; printerctl list" | cut -f1)
while IFS=$'\t' read -r label driver uri; do
	if printf '%s\n' "$existing" | grep -qxF -- "$label"; then
		if [ "$REPLACE" = 0 ]; then
			echo "exists:  $label"
			continue
		fi
		ssh -n "$HOST" "$PATH_VM; printerctl remove $(printf '%q' "$label")"
	fi
	ssh -n "$HOST" "$PATH_VM; printerctl add $(printf '%q ' "$label" "$driver" IPP "$uri")"
done < "$TMP/add"

if [ -n "$DEFAULT" ]; then
	ssh "$HOST" "$PATH_VM; printerctl default $(printf '%q' "$DEFAULT")"
	echo "default: $DEFAULT"
fi
