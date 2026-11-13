"""Answers with the address a request came from, after holding it for the seconds in /wait/SECONDS, a minute for /wait. Takes a port and an address to listen on."""
import http.server
import sys
import time


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "wait":
            time.sleep(int(parts[1]) if len(parts) > 1 else 60)
        body = self.client_address[0].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


address = sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0"
http.server.ThreadingHTTPServer((address, int(sys.argv[1])), Page).serve_forever()
