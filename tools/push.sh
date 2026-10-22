#!/bin/bash
# push.sh LOCAL REMOTE [MODE]
#
# Bootstrap file transfer before OpenSSH exists: serve LOCAL once from the host
# and have the guest fetch it with `rx` (tools/rx.c, pushed first with
# `hsh.py --send`). Much faster than base64 over telnet.
#   HOST_IP: the host's address on the VM network (UTM shared: 192.168.64.1)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOST_IP=${HOST_IP:-192.168.64.1}
RX=${RX:-/boot/home/bin/rx}
port=$((9100 + RANDOM % 800))
python3 -I -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[3], int(sys.argv[2]))); s.listen(1); s.settimeout(60)
c, _ = s.accept(); c.sendall(open(sys.argv[1], "rb").read()); c.close()' "$1" $port "$HOST_IP" &
srv=$!
sleep 0.3
python3 -I "$here/hsh.py" "mkdir -p \"\$(dirname '$2')\" && $RX $HOST_IP $port '$2' ${3:-644} && sha256sum '$2' | cut -c1-16"
wait $srv
echo "host: $(shasum -a 256 "$1" | cut -c1-16)"
