#!/usr/bin/env python3
"""Unprivileged git-forge webhook listener.

Deliberately minimal — this is the process a compromised dependency or a
bug in forge-payload handling would put at risk, so it does the least
possible: enforce a size limit, capture the raw request, and spool it.

It does NOT verify HMAC and does NOT hold the webhook secret at all
(unlike an earlier version of this tool, which did both here) — the
secret file is root:root 600, unreadable by this process's own user
(WEBHOOK_USER). Verification and forge-payload parsing happen later, in
verify_and_spool.py, invoked by the root worker (provision.sh
hook-worker) when it drains the spool. That split is the whole point:
with HMAC's symmetric key, any process that can verify a signature can
also forge one, so a process that holds the real secret is exactly as
dangerous, if compromised, as one with no auth check at all. Keeping the
secret out of this process entirely means compromising IT specifically
buys nothing — every job still has to pass real verification, done by a
process this one never touches, before the root worker acts on it.

Consequence: this listener can no longer tell a good signature from a
bad one, so every structurally-valid POST gets 202 "queued for
verification" — a bad/missing signature is rejected later, asynchronously,
not with a synchronous 401 the way it used to be. See README "Deploy on
git push" for what that means operationally (a typo'd secret in GitHub's
webhook settings shows as "delivered" in GitHub's own UI; check this
tool's own logs, not the forge's, to catch that).

Environment (set by /etc/ddeploy/hook.env):
  DDEPLOY_HOOK_LISTEN    host:port, default 127.0.0.1:8787
  DDEPLOY_HOOK_SPOOL     directory for new job files
"""
from __future__ import annotations

import base64
import json
import os
import sys
import tempfile
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hookparse import canonicalize_git_url  # noqa: E402

MAX_BODY = 1_000_000


def _spool_raw(spool: Path, envelope: dict[str, Any]) -> None:
    spool.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=str(spool))
    try:
        os.write(fd, json.dumps(envelope, separators=(",", ":")).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o640)
    # raw-, not job-: this is an UNVERIFIED envelope — the root worker's
    # verify_and_spool.py has to authenticate and parse it into an actual
    # job before hook_process_job (lib/cmd_hook.sh) ever sees one.
    dest = spool / ("raw-%s.json" % uuid.uuid4().hex)
    os.replace(tmp, dest)


def _log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


class HookHandler(BaseHTTPRequestHandler):
    spool = Path("/var/lib/ddeploy/queue/new")

    def log_message(self, fmt: str, *args: Any) -> None:
        _log("%s - %s" % (self.address_string(), fmt % args))

    def _send(self, code: int, body: str = "") -> None:
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send(200, "ok\n")
            return
        self._send(404, "not found\n")

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/github":
            provider = "github"
            sig_header = self.headers.get("X-Hub-Signature-256") or ""
            forge_event = self.headers.get("X-GitHub-Event") or ""
        elif path == "/bitbucket":
            provider = "bitbucket"
            sig_header = self.headers.get("X-Hub-Signature") or ""
            forge_event = self.headers.get("X-Event-Key") or ""
        else:
            self._send(404, "not found\n")
            return

        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self._send(400, "bad content-length\n")
            return
        if length < 0 or length > MAX_BODY:
            self._send(413, "payload too large\n")
            return
        body = self.rfile.read(length)

        # Structural checks only — no signature check, this process
        # never holds the secret needed to do one. A signature header is
        # still required to exist (a request with none is never going to
        # verify anyway, and rejecting it here means the spool isn't
        # filled with envelopes that can never possibly pass).
        if not sig_header:
            self._send(401, "missing signature\n")
            return
        try:
            json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, "invalid json\n")
            return

        _spool_raw(
            self.spool,
            {
                "provider": provider,
                "sig_header": sig_header,
                "forge_event": forge_event,
                "body_b64": base64.b64encode(body).decode("ascii"),
            },
        )
        _log("queued (unverified) provider=%s forge_event=%s" % (provider, forge_event))
        self._send(202, "queued\n")


def serve() -> None:
    listen = os.environ.get("DDEPLOY_HOOK_LISTEN", "127.0.0.1:8787")
    spool = Path(os.environ.get("DDEPLOY_HOOK_SPOOL", "/var/lib/ddeploy/queue/new"))

    host, port_s = listen.rsplit(":", 1)
    port = int(port_s)
    HookHandler.spool = spool
    spool.mkdir(parents=True, exist_ok=True)

    httpd = ThreadingHTTPServer((host, port), HookHandler)
    _log("listening on %s spool=%s (unverified — real HMAC check happens in hook-worker)" % (listen, spool))
    httpd.serve_forever()


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "--canonicalize":
        sys.stdout.write(canonicalize_git_url(argv[2]) + "\n")
        return 0
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
