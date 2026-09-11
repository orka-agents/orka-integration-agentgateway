"""Local conformance fixtures. Synthetic token equality is not token verification."""

import hashlib
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread


MAX_BODY_BYTES = 1024 * 1024


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address, mode, credentials):
        self.mode = mode
        self.credentials = credentials
        super().__init__(address, FixtureHandler)

    def handle_error(self, request, client_address):
        # Avoid tracebacks containing untrusted request data or credentials.
        pass


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Request headers, paths, bodies, and credential material are never logged.
        pass

    def send_error(self, code, message=None, explain=None):
        self._respond(code, {"error": "invalid fixture request"})

    def _respond(self, status, payload, headers=None):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(body)

    def _body(self):
        encoding = self.headers.get("Transfer-Encoding", "").lower()
        if encoding == "chunked":
            body = bytearray()
            while True:
                size = int(self.rfile.readline(128).split(b";", 1)[0], 16)
                if size < 0 or len(body) + size > MAX_BODY_BYTES:
                    raise ValueError("invalid body length")
                if size == 0:
                    return bytes(body)
                chunk = self.rfile.read(size)
                if len(chunk) != size or self.rfile.read(2) != b"\r\n":
                    raise ValueError("invalid chunk")
                body.extend(chunk)
        if encoding:
            raise ValueError("unsupported transfer encoding")
        size = int(self.headers.get("Content-Length", "0"))
        if size < 0 or size > MAX_BODY_BYTES:
            raise ValueError("invalid body length")
        body = self.rfile.read(size)
        if len(body) != size:
            raise ValueError("incomplete body")
        return body

    def _matches_credential(self, header, key):
        values = self.headers.get_all(header, [])
        return len(values) == 1 and hmac.compare_digest(
            values[0].encode(), self.server.credentials[key]
        )

    def _handle(self):
        self.connection.settimeout(5)
        if self.path == "/healthz":
            self._respond(200, {"ok": True})
            return
        if self.server.mode == "ext-authz":
            if self.path != "/authorize":
                self._respond(404, {"error": "unknown fixture endpoint"})
            elif self._matches_credential("Txn-Token", "txn-token"):
                self._respond(
                    200,
                    {"authorized": True},
                    {"x-orka-transaction-id": "fixture-transaction"},
                )
            else:
                self._respond(403, {"authorized": False})
            return
        if self.path != "/v1/resource?version=1":
            self._respond(404, {"error": "unknown fixture endpoint"})
            return
        try:
            body = self._body()
        except (ValueError, TimeoutError, OSError):
            self._respond(400, {"error": "invalid fixture request"})
            return
        idempotency = self.headers.get("Idempotency-Key", "").encode()
        self._respond(
            200,
            {
                "authorization_replaced": self._matches_credential(
                    "Authorization", "downstream-authorization"
                ),
                # Avoid token/secret field names: Orka redacts their values,
                # including booleans, before returning the Tool response.
                "governance_header_absent": not self.headers.get_all("Txn-Token"),
                "method": self.command,
                "host": "example.com"
                if self.headers.get("Host") == "example.com"
                else "unexpected",
                "path": self.path,
                "body_sha256": hashlib.sha256(body).hexdigest(),
                "idempotency_key_sha256": hashlib.sha256(idempotency).hexdigest(),
            },
        )

    do_GET = _handle
    do_HEAD = _handle
    do_POST = _handle
    do_PUT = _handle
    do_PATCH = _handle
    do_DELETE = _handle
    do_OPTIONS = _handle


def main():
    credential_dir = Path(os.environ.get("FIXTURE_SECRET_DIR", "/var/run/fixture"))
    credentials = {
        name: (credential_dir / name).read_bytes().strip()
        for name in ("txn-token", "upstream-authorization", "downstream-authorization")
    }
    if not all(credentials.values()) or len(set(credentials.values())) != 3:
        raise SystemExit("fixture credentials must be nonempty and distinct")
    downstream = FixtureServer(("0.0.0.0", 8080), "downstream", credentials)
    ext_authz = FixtureServer(("0.0.0.0", 9000), "ext-authz", credentials)
    Thread(target=ext_authz.serve_forever, daemon=True).start()
    downstream.serve_forever()


if __name__ == "__main__":
    main()
