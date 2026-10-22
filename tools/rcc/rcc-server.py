#!/usr/bin/env python3
"""Compile server for tools/rcc/c++ (the guest-side wrapper).

GCC on Haiku arm64 is ~20x slower than the same GCC 13.3 on Linux for big
translation units (a V8 file: 159 s on the guest, 7.6 s in haiku-bfs), while
preprocessing on the guest takes under a second. So the guest preprocesses
and POSTs the .ii here; this runs the identical cross compiler
(aarch64-unknown-haiku-g++ from build-cross-tools.sh) in the haiku-bfs
container and sends the object back. Only flags on the allow-list below are
accepted; the wrapper compiles locally when the server is unreachable.

  python3 tools/rcc/rcc-server.py        # listens on 192.168.64.1:8766

RCC_DIR must be the host side of a directory the container sees as
RCC_CDIR (default: bfs-build/rcc, mounted at /work/rcc).
"""
import http.server
import os
import re
import subprocess
import threading
import uuid

HOST = os.environ.get("RCC_HOST", "192.168.64.1")
PORT = int(os.environ.get("RCC_PORT", "8766"))
DIR = os.environ.get("RCC_DIR", os.path.expanduser("~/Downloads/haiku-arm64-hrev60290/bfs-build/rcc"))
CDIR = os.environ.get("RCC_CDIR", "/work/rcc")
CONTAINER = os.environ.get("RCC_CONTAINER", "haiku-bfs")
CXX = "/build/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-g++"

OK = re.compile(r"-(O[0-3sgz]?|std=[\w+]+|f[\w=+.,-]+|m[\w=+.,-]+|W[\w=+-]*|w|g\w*|pthread)")
BAD = re.compile(r"-(W[lap],|fplugin|fdump|fprofile|f\w*-prefix-map|frecord)")
slots = threading.BoundedSemaphore(int(os.environ.get("RCC_JOBS", os.cpu_count() or 8)))
stats = {"ok": 0, "error": 0, "rejected": 0}


class Handler(http.server.BaseHTTPRequestHandler):
	def do_POST(self):
		flags = self.headers.get("X-Flags", "").split()
		bad = [f for f in flags if not OK.fullmatch(f) or BAD.match(f)]
		if self.path != "/compile" or bad:
			stats["rejected"] += 1
			return self.reply(400, ("rejected flags: %s\n" % " ".join(bad)).encode())
		body = self.rfile.read(int(self.headers["Content-Length"]))
		job = uuid.uuid4().hex
		ii, obj = os.path.join(DIR, job + ".ii"), os.path.join(DIR, job + ".o")
		with open(ii, "wb") as f:
			f.write(body)
		try:
			with slots:
				r = subprocess.run(
					["docker", "exec", "-w", CDIR, CONTAINER, CXX, *flags,
					 "-x", "c++-cpp-output", "-c", job + ".ii", "-o", job + ".o"],
					capture_output=True)
			if r.returncode == 0:
				stats["ok"] += 1
				with open(obj, "rb") as f:
					return self.reply(200, f.read())
			stats["error"] += 1
			self.reply(422, r.stderr + r.stdout)
		finally:
			for p in (ii, obj):
				try:
					os.remove(p)
				except FileNotFoundError:
					pass

	def do_GET(self):
		self.reply(200, ("%(ok)d ok, %(error)d errors, %(rejected)d rejected\n" % stats).encode())

	def reply(self, code, data):
		self.send_response(code)
		self.send_header("Content-Length", str(len(data)))
		self.end_headers()
		self.wfile.write(data)

	def log_message(self, fmt, *args):
		pass


if __name__ == "__main__":
	os.makedirs(DIR, exist_ok=True)
	print("rcc-server on %s:%d, %d jobs" % (HOST, PORT, slots._initial_value), flush=True)
	http.server.ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
