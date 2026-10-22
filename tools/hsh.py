#!/usr/bin/env python3
"""Run a shell command on the Haiku guest over telnet and print its output.

Bootstrap-only: used before OpenSSH exists. On the guest, start telnetd with
    while true; do telnetd -debug 2323; done &
(it logs in as the single Haiku user, which has no password by default).

usage: hsh.py [--host H] [--port P] [--user U] [--send FILE --to GUESTPATH] [command]
"""
import argparse
import base64
import re
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
MARK = "__HSH_DONE__"


class Telnet:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        self.buf = b""

    def _recv(self, timeout):
        self.s.settimeout(timeout)
        try:
            data = self.s.recv(65536)
        except socket.timeout:
            return b""
        if not data:
            raise EOFError("connection closed")
        out = bytearray()
        i = 0
        while i < len(data):
            b = data[i]
            if b == IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (DO, DONT, WILL, WONT) and i + 2 < len(data):
                    opt = data[i + 2]
                    if cmd == DO:
                        self.s.sendall(bytes([IAC, WONT, opt]))
                    elif cmd == WILL:
                        self.s.sendall(bytes([IAC, DONT, opt]))
                    i += 3
                    continue
                if cmd == SB:
                    end = data.find(bytes([IAC, SE]), i)
                    i = len(data) if end < 0 else end + 2
                    continue
                if cmd == IAC:
                    out.append(IAC)
                i += 2
                continue
            out.append(b)
            i += 1
        return bytes(out)

    def read_until(self, pattern, timeout):
        deadline = time.time() + timeout
        rx = re.compile(pattern)
        while time.time() < deadline:
            m = rx.search(self.buf.decode("utf-8", "replace"))
            if m:
                text = self.buf.decode("utf-8", "replace")
                self.buf = b""
                return text
            self.buf += self._recv(0.5)
        raise TimeoutError(f"timed out waiting for {pattern!r}; got: {self.buf[-500:]!r}")

    def send(self, text):
        self.s.sendall(text.encode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.64.4")
    ap.add_argument("--port", type=int, default=2323)
    ap.add_argument("--user", default="baron", help="Haiku login name (`whoami` on the guest)")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--send")
    ap.add_argument("--to")
    ap.add_argument("command", nargs="?")
    a = ap.parse_args()

    t = Telnet(a.host, a.port)
    first = t.read_until(r"(login:|[$#>] ?$)", 20)
    if "login:" in first:
        t.send(a.user + "\r\n")
        if "assword" in t.read_until(r"([$#>] ?$|assword: ?$)", 20):
            t.send("\r\n")
            t.read_until(r"[$#>] ?$", 20)
    # quiet, deterministic shell
    t.send("stty -echo; PS1=''; PS2=''\r\n")
    time.sleep(0.5)
    t.buf = b""; t._recv(0.5)

    if a.send:
        # One short command per chunk, each acknowledged before the next, so
        # the guest's tty input buffer never overruns.
        data = base64.b64encode(open(a.send, "rb").read()).decode()
        t.send(f": > '{a.to}'.b64; echo {MARK}A\r\n")
        t.read_until(MARK + "A", 30)
        for n, i in enumerate(range(0, len(data), 3000)):
            t.send(f"printf %s '{data[i:i + 3000]}' >> '{a.to}'.b64; echo {MARK}{n}\r\n")
            t.read_until(f"{MARK}{n}\\b", 30)
        t.send(f"base64 -d '{a.to}'.b64 > '{a.to}' && rm '{a.to}'.b64 && sha256sum '{a.to}'; echo {MARK}Z\r\n")
        print(t.read_until(MARK + "Z", a.timeout).replace(MARK + "Z", "").strip())

    if a.command:
        t.send(f"{{ {a.command.rstrip(';')} ; }} 2>&1; echo {MARK} $?\r\n")
        out = t.read_until(MARK + r" \d+", a.timeout)
        body, _, rc = out.rpartition(MARK)
        sys.stdout.write(body.replace("\r\n", "\n").lstrip("\n"))
        t.send("exit\r\n")
        sys.exit(int(rc.strip() or 0))


if __name__ == "__main__":
    main()
