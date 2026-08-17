"""
Minimal HTTP endpoint for platforms that validate a deployment by connecting to
a port.

Clever Cloud marks a (non-task) application as failed when nothing listens on
CC_DOCKER_EXPOSED_HTTP_PORT, which a celery worker never does. Running this
next to the worker satisfies that check without exposing anything: every
request gets a plain 200, and no filesystem is served (unlike http.server).

Usage: python deploy/healthcheck_server.py [port]
"""

import sys
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer


class HealthCheckHandler(BaseHTTPRequestHandler):
    """Answers 200 to any path, and serves nothing else."""

    protocol_version = "HTTP/1.1"

    def _respond(self, include_body):
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        self._respond(include_body=True)

    def do_HEAD(self):
        self._respond(include_body=False)

    def log_message(self, format, *args):
        """Silence per-request logging: health checks would flood the logs."""


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), HealthCheckHandler).serve_forever()  # noqa: S104


if __name__ == "__main__":
    main()
