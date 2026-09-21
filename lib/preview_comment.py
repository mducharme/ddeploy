#!/usr/bin/env python3
"""Post or update a ddeploy preview URL on a GitHub/Bitbucket PR.

Called by lib/preview_comment.sh after a successful webhook preview
upsert. Tokens and API roots come from the environment (never argv).
Repo and PR are charset-validated here again so a bad job file cannot
point the token at an arbitrary URL.
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

MARKER = "<!-- ddeploy-preview -->"
REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
PR_RE = re.compile(r"^[1-9][0-9]{0,9}$")
USER_AGENT = "ddeploy-preview-comment"


def _fail(msg: str) -> int:
    sys.stderr.write(msg + "\n")
    return 1


def _api_root(raw: str, default: str) -> str:
    s = (raw or default).strip().rstrip("/")
    if not s:
        return default
    parsed = urllib.parse.urlparse(s)
    if parsed.scheme not in ("https", "http"):
        raise ValueError("api root must be http(s)")
    if parsed.scheme == "http" and parsed.hostname not in ("127.0.0.1", "localhost"):
        raise ValueError("http API root is only allowed on localhost")
    if not parsed.netloc:
        raise ValueError("api root missing host")
    return s


def _request(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict[str, Any] | None = None,
) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = resp.read()
            status = getattr(resp, "status", 200)
    except urllib.error.HTTPError as exc:
        raw = exc.read() if exc.fp else b""
        status = exc.code
        if status >= 400:
            raise
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        raise
    if not raw:
        return status, None
    try:
        return status, json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        return status, None


def _github_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": "Bearer %s" % token,
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _bitbucket_headers(user: str, password: str, token: str) -> dict[str, str]:
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = "Bearer %s" % token
    else:
        basic = base64.b64encode(("%s:%s" % (user, password)).encode("utf-8")).decode("ascii")
        headers["Authorization"] = "Basic %s" % basic
    return headers


def github_upsert(api: str, repo: str, pr: str, token: str, body: str) -> None:
    headers = _github_headers(token)
    quoted = urllib.parse.quote(repo, safe="/")
    list_url = "%s/repos/%s/issues/%s/comments?per_page=100" % (api, quoted, pr)
    _status, comments = _request("GET", list_url, headers)
    existing = None
    if isinstance(comments, list):
        for item in comments:
            if MARKER in str((item or {}).get("body") or ""):
                existing = item
                break
    payload = {"body": body}
    if existing and existing.get("id") is not None:
        cid = str(int(existing["id"]))
        url = "%s/repos/%s/issues/comments/%s" % (api, quoted, cid)
        _request("PATCH", url, headers, payload)
        return
    post_url = "%s/repos/%s/issues/%s/comments" % (api, quoted, pr)
    _request("POST", post_url, headers, payload)


def bitbucket_upsert(
    api: str, repo: str, pr: str, user: str, password: str, token: str, body: str
) -> None:
    headers = _bitbucket_headers(user, password, token)
    quoted = urllib.parse.quote(repo, safe="/")
    list_url = "%s/2.0/repositories/%s/pullrequests/%s/comments?pagelen=50" % (api, quoted, pr)
    _status, data = _request("GET", list_url, headers)
    values = data.get("values") if isinstance(data, dict) else None
    existing = None
    if isinstance(values, list):
        for item in values:
            raw = ((item or {}).get("content") or {}).get("raw") or ""
            if MARKER in str(raw):
                existing = item
                break
    payload = {"content": {"raw": body}}
    if existing and existing.get("id") is not None:
        cid = str(int(existing["id"]))
        url = "%s/2.0/repositories/%s/pullrequests/%s/comments/%s" % (api, quoted, pr, cid)
        _request("PUT", url, headers, payload)
        return
    post_url = "%s/2.0/repositories/%s/pullrequests/%s/comments" % (api, quoted, pr)
    _request("POST", post_url, headers, payload)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        return _fail("usage: preview_comment.py <github|bitbucket> <owner/repo> <pr>")
    provider, repo, pr = argv[1], argv[2], argv[3]
    if provider not in ("github", "bitbucket"):
        return _fail("unknown provider")
    if not REPO_RE.fullmatch(repo):
        return _fail("invalid repo")
    if not PR_RE.fullmatch(pr):
        return _fail("invalid pr")

    body = os.environ.get("DDEPLOY_COMMENT_BODY", "")
    if MARKER not in body:
        return _fail("comment body missing marker")

    try:
        if provider == "github":
            token = os.environ.get("DDEPLOY_GITHUB_TOKEN", "").strip()
            if not token:
                return 2
            api = _api_root(os.environ.get("DDEPLOY_GITHUB_API", ""), "https://api.github.com")
            github_upsert(api, repo, pr, token, body)
        else:
            user = os.environ.get("DDEPLOY_BITBUCKET_USER", "").strip()
            password = os.environ.get("DDEPLOY_BITBUCKET_PASSWORD", "").strip()
            token = os.environ.get("DDEPLOY_BITBUCKET_TOKEN", "").strip()
            if not token and not (user and password):
                return 2
            api = _api_root(
                os.environ.get("DDEPLOY_BITBUCKET_API", ""), "https://api.bitbucket.org"
            )
            bitbucket_upsert(api, repo, pr, user, password, token, body)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError, TypeError) as exc:
        return _fail("comment failed: %s" % type(exc).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
