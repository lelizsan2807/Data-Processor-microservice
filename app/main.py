import argparse
import http.server
import socketserver

parser = argparse.ArgumentParser(description="Data Processor API")
parser.add_argument("mode", nargs="?", default="api")
parser.add_argument("--port", type=int, default=5000)
args = parser.parse_args()


class Handler(http.server.SimpleHTTPRequestHandler):
    pass


with socketserver.TCPServer(("0.0.0.0", args.port), Handler) as httpd:
    print(f"Serving at port {args.port}", flush=True)
    httpd.serve_forever()
