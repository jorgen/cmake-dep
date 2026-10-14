"""Minimal content-addressed mirror server for the cmake-dep tests.

    python3 mirror_server.py <root> <port-file> [<required Authorization header>]

Serves <root> over HTTP on 127.0.0.1 (random port, written to <port-file>):
  GET  /<path>          static files (404 if missing)
  PUT  /<path>          store the request body at <root>/<path> (atomic)
  GET  /shutdown        stop the server

If an Authorization value is given, every path outside /upstream/ requires it
(401 otherwise). /upstream/ plays the "real" upstream server: if a request to
it carries an Authorization header, <root>/LEAKED is created, so the tests can
assert that mirror credentials are never sent upstream.

Not a production server -- see examples/mirror-servers for real setups.
"""
import http.server
import os
import sys
import threading

root, port_file = sys.argv[1], sys.argv[2]
required_auth = sys.argv[3] if len(sys.argv) > 3 else ""


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=root, **kwargs)

    def log_message(self, *args):
        pass

    def _authorized(self):
        if self.path.startswith("/upstream/"):
            if self.headers.get("Authorization"):
                open(os.path.join(root, "LEAKED"), "w").close()
            return True
        if required_auth and self.headers.get("Authorization") != required_auth:
            self.send_error(401)
            return False
        return True

    def do_GET(self):
        if self.path == "/shutdown":
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=server.shutdown, daemon=True).start()
            return
        if self._authorized():
            super().do_GET()

    def do_HEAD(self):
        if self._authorized():
            super().do_HEAD()

    def do_PUT(self):
        if not self._authorized():
            return
        target = self.translate_path(self.path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        length = int(self.headers.get("Content-Length", 0))
        tmp = target + ".upload"
        with open(tmp, "wb") as f:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        os.replace(tmp, target)
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
tmp_port = port_file + ".tmp"
with open(tmp_port, "w") as f:
    f.write(str(server.server_address[1]))
os.replace(tmp_port, port_file)
# Safety net so a crashed test run never leaves the server behind.
threading.Timer(300, server.shutdown).start()
server.serve_forever()
os._exit(0)
