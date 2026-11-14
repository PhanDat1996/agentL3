#!/usr/bin/env python3
# inventory-api: tiny HTTP service for the lab
import http.server, json, os, time
_report_cache = []   # memoised report chunks

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health"):
            body = b'{"status":"ok"}'
        elif self.path.startswith("/report"):
            chunk = bytearray(110 * 1024 * 1024)
            for i in range(0, len(chunk), 4096):
                chunk[i] = 1
            _report_cache.append(chunk)
            body = json.dumps({"rows": len(_report_cache) * 50000, "generated": time.time()}).encode()
        else:
            body = b'{"items":[]}'
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("0.0.0.0", 8088), H).serve_forever()
