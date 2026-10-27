#!/usr/bin/env python3
"""Tiny local HTTP fixture server for the async-fetch file-sink spec.

Serves files from argv[1] on 127.0.0.1 with an ephemeral port, writes
"<port>\\n<pid>\\n" to argv[2], and supports:

  /file.bin      200 + Content-Length, 206 + Content-Range on Range
  /norange.bin   always 200 (ignores Range), to exercise fallback
  /chunked.bin   Transfer-Encoding: chunked

Only used by spec/asyncfetch_spec.lua. Never touched by the plugin.
"""
import http.server
import os
import re
import socketserver
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        name = self.path.lstrip("/").split("?")[0]
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as fh:
            data = fh.read()

        if name == "chunked.bin":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in range(0, len(data), 8192):
                piece = data[i:i + 8192]
                self.wfile.write(("%x\r\n" % len(piece)).encode() + piece + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return

        start, end, partial = 0, len(data) - 1, False
        rng = self.headers.get("Range")
        if rng and name != "norange.bin":
            match = re.match(r"bytes=(\d+)-", rng)
            if match:
                start = int(match.group(1))
                partial = True

        if partial:
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, len(data)))
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    ROOT = sys.argv[1]
    with Server(("127.0.0.1", 0), Handler) as httpd:
        with open(sys.argv[2], "w") as fh:
            fh.write("%d\n%d\n" % (httpd.server_address[1], os.getpid()))
        httpd.serve_forever()
