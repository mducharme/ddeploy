#!/usr/bin/env python3
"""Unprivileged git-forge webhook listener.

Verifies HMAC, maps GitHub / Bitbucket Cloud payloads to an internal job,
writes that job to a spool directory, and returns 202. Deploy work is the
root worker's job (provision.sh hook-worker), not this process.

Environment (set by /etc/ddeploy/hook.env):
  DDEPLOY_HOOK_SECRET              path to HMAC secret (required)
  DDEPLOY_HOOK_SECRET_BITBUCKET    optional override for POST /bitbucket
  DDEPLOY_HOOK_LISTEN              host:port, default 127.0.0.1:8787
  DDEPLOY_HOOK_SPOOL               directory for new job files
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import sys
import tempfile
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

MAX_BODY = 1_000_000
ALLOWED_EVENTS = frozenset({"push_head", "preview_upsert", "preview_remove"})


def canonicalize_git_url(url: str) -> str:
    """host/path form, no scheme, user, or trailing .git — comparable across forges."""
    s = (url or "").strip().rstrip("/")
    if not s:
        return ""
    if "://" not in s and "@" in s:
        # git@host:path  (scp-like)
        s = s.split("@", 1)[1].replace(":", "/", 1)
    else:
        s = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", "", s)
        if "@" in s:
            s = s.split("@", 1)[1]
    if s.endswith(".git"):
        s = s[:-4]
    return s.lower()


def _uniq_urls(urls: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for u in urls:
        c = canonicalize_git_url(u)
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out


def verify_hmac(header: str | None, body: bytes, secret: bytes) -> bool:
    if not header or not secret:
        return False
    if not header.startswith("sha256="):
        return False
    got = header[7:].strip()
    expect = hmac.new(secret, body, hashlib.sha256).hexdigest()
    if len(got) != len(expect):
        return False
    return hmac.compare_digest(got.lower(), expect.lower())


def _github_urls(data: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    for obj in (
        data.get("repository") or {},
        (data.get("pull_request") or {}).get("base", {}).get("repo") or {},
    ):
        for key in ("clone_url", "ssh_url", "git_url", "html_url"):
            val = obj.get(key)
            if val:
                urls.append(val)
    return _uniq_urls(urls)


def _bitbucket_urls(*objs: dict[str, Any]) -> list[str]:
    urls: list[str] = []
    for obj in objs:
        links = (obj.get("links") or {}).get("clone") or []
        if isinstance(links, list):
            for item in links:
                href = (item or {}).get("href")
                if href:
                    urls.append(href)
        html = ((obj.get("links") or {}).get("html") or {}).get("href")
        if html:
            urls.append(html)
        full = obj.get("full_name")
        if full:
            urls.append(f"https://bitbucket.org/{full}.git")
    return _uniq_urls(urls)


def parse_github(event: str, data: dict[str, Any]) -> dict[str, Any] | None:
    """Return an internal job dict, or None to accept-and-ignore."""
    if event == "ping":
        return None
    urls = _github_urls(data)
    if event == "push":
        ref = data.get("ref") or ""
        if data.get("deleted") or not ref.startswith("refs/heads/"):
            return None
        branch = ref[len("refs/heads/") :]
        if not branch:
            return None
        return {
            "provider": "github",
            "event": "push_head",
            "repo_urls": urls,
            "branches": [branch],
            "sha": data.get("after") or "",
        }
    if event == "pull_request":
        pr = data.get("pull_request") or {}
        action = data.get("action") or ""
        head = pr.get("head") or {}
        base = pr.get("base") or {}
        head_repo = (head.get("repo") or {}).get("full_name") or ""
        base_repo = (base.get("repo") or {}).get("full_name") or ""
        if not head_repo or not base_repo or head_repo != base_repo:
            return None
        branch = head.get("ref") or ""
        if not branch:
            return None
        if action in ("opened", "synchronize", "reopened"):
            ev = "preview_upsert"
        elif action == "closed":
            ev = "preview_remove"
        else:
            return None
        return {
            "provider": "github",
            "event": ev,
            "repo_urls": urls,
            "branches": [branch],
            "sha": head.get("sha") or "",
        }
    return None


def parse_bitbucket(event_key: str, data: dict[str, Any]) -> dict[str, Any] | None:
    repo = data.get("repository") or {}
    if event_key == "repo:push":
        branches: list[str] = []
        sha = ""
        for change in (data.get("push") or {}).get("changes") or []:
            new = change.get("new")
            if not new or new.get("type") != "branch":
                continue
            name = new.get("name") or ""
            if name and name not in branches:
                branches.append(name)
            if not sha:
                sha = ((new.get("target") or {}).get("hash")) or ""
        if not branches:
            return None
        return {
            "provider": "bitbucket",
            "event": "push_head",
            "repo_urls": _bitbucket_urls(repo),
            "branches": branches,
            "sha": sha,
        }
    if event_key in (
        "pullrequest:created",
        "pullrequest:updated",
        "pullrequest:fulfilled",
        "pullrequest:rejected",
    ):
        pr = data.get("pullrequest") or {}
        source = pr.get("source") or {}
        dest = pr.get("destination") or {}
        src_repo = source.get("repository") or {}
        dst_repo = dest.get("repository") or repo
        src_id = src_repo.get("uuid") or src_repo.get("full_name") or ""
        dst_id = dst_repo.get("uuid") or dst_repo.get("full_name") or ""
        if not src_id or not dst_id or src_id != dst_id:
            return None
        branch = (source.get("branch") or {}).get("name") or ""
        if not branch:
            return None
        ev = (
            "preview_remove"
            if event_key in ("pullrequest:fulfilled", "pullrequest:rejected")
            else "preview_upsert"
        )
        sha = ((source.get("commit") or {}).get("hash")) or ""
        return {
            "provider": "bitbucket",
            "event": ev,
            "repo_urls": _bitbucket_urls(repo, dst_repo),
            "branches": [branch],
            "sha": sha,
        }
    return None


def _read_secret(path: str) -> bytes:
    if not path:
        return b""
    p = Path(path)
    if not p.is_file():
        return b""
    return p.read_bytes().strip()


def _spool_job(spool: Path, job: dict[str, Any]) -> None:
    spool.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=str(spool))
    try:
        os.write(fd, json.dumps(job, separators=(",", ":")).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o640)
    dest = spool / ("job-%s.json" % uuid.uuid4().hex)
    os.replace(tmp, dest)


def _log(msg: str) -> None:
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


class HookHandler(BaseHTTPRequestHandler):
    secret_github = b""
    secret_bitbucket = b""
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
            sig_header = self.headers.get("X-Hub-Signature-256")
            secret = self.secret_github
            forge_event = self.headers.get("X-GitHub-Event") or ""
        elif path == "/bitbucket":
            provider = "bitbucket"
            sig_header = self.headers.get("X-Hub-Signature")
            secret = self.secret_bitbucket or self.secret_github
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

        if not verify_hmac(sig_header, body, secret):
            _log("hmac failed provider=%s path=%s" % (provider, path))
            self._send(401, "unauthorized\n")
            return

        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, "invalid json\n")
            return
        if not isinstance(data, dict):
            self._send(400, "invalid json\n")
            return

        if provider == "github":
            job = parse_github(forge_event, data)
        else:
            job = parse_bitbucket(forge_event, data)

        if job is None:
            _log("ignored provider=%s forge_event=%s" % (provider, forge_event))
            self._send(202, "ignored\n")
            return
        if job.get("event") not in ALLOWED_EVENTS:
            self._send(202, "ignored\n")
            return

        _spool_job(self.spool, job)
        _log(
            "queued provider=%s event=%s branches=%s urls=%s"
            % (
                job["provider"],
                job["event"],
                ",".join(job["branches"]),
                ",".join(job["repo_urls"]),
            )
        )
        self._send(202, "queued\n")


def serve() -> None:
    secret_path = os.environ.get("DDEPLOY_HOOK_SECRET", "")
    bb_path = os.environ.get("DDEPLOY_HOOK_SECRET_BITBUCKET", "")
    listen = os.environ.get("DDEPLOY_HOOK_LISTEN", "127.0.0.1:8787")
    spool = Path(os.environ.get("DDEPLOY_HOOK_SPOOL", "/var/lib/ddeploy/queue/new"))

    secret = _read_secret(secret_path)
    if not secret:
        sys.stderr.write("DDEPLOY_HOOK_SECRET missing or empty — refusing to listen\n")
        sys.exit(1)

    host, port_s = listen.rsplit(":", 1)
    port = int(port_s)
    HookHandler.secret_github = secret
    HookHandler.secret_bitbucket = _read_secret(bb_path) if bb_path else secret
    HookHandler.spool = spool
    spool.mkdir(parents=True, exist_ok=True)

    httpd = ThreadingHTTPServer((host, port), HookHandler)
    _log("listening on %s spool=%s" % (listen, spool))
    httpd.serve_forever()


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "--canonicalize":
        sys.stdout.write(canonicalize_git_url(argv[2]) + "\n")
        return 0
    serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
