"""Answers after a short pause, since sing-box reads a test that took 0 ms as no result at all."""
import http.server
import sys
import time


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(0.05)
        self.send_response(204)
        self.end_headers()

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[1])), Page).serve_forever()
