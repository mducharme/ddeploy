#!/usr/bin/env python3
"""Register the ddeploy git-push webhook on a GitHub org or Bitbucket
workspace via each forge's REST API.

Neither forge exposes this the same way in its web UI: Bitbucket Cloud
has no workspace-level webhook screen at all (only per-repository, which
doesn't scale to "one hook covers every client repo"), and while GitHub's
org webhook UI does work, the API is used here too for consistency and
so this is scriptable the same way on both. Called by
`provision.sh configure webhook` (lib/cmd_configure.sh). Tokens come from
the environment, never argv or a saved file — this is a one-time
registration action, not an ongoing credential ddeploy manages.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

USER_AGENT = "ddeploy-register-webhook"


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


def _request(method: str, url: str, headers: dict[str, str], body: dict[str, Any]) -> tuple[int, str]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read()
            status = getattr(resp, "status", 200)
    except urllib.error.HTTPError as exc:
        raw = exc.read() if exc.fp else b""
        status = exc.code
    return status, raw.decode("utf-8", "replace")


def register_github(api: str, org: str, url: str, secret: str, token: str) -> tuple[int, str]:
    headers = {
        "Authorization": "Bearer %s" % token,
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    body = {
        "name": "web",
        "active": True,
        "events": ["push", "pull_request"],
        "config": {
            "url": url,
            "content_type": "json",
            "secret": secret,
            "insecure_ssl": "0",
        },
    }
    return _request("POST", "%s/orgs/%s/hooks" % (api, org), headers, body)


def register_bitbucket(api: str, workspace: str, url: str, secret: str, user: str, password: str) -> tuple[int, str]:
    basic = base64.b64encode(("%s:%s" % (user, password)).encode("utf-8")).decode("ascii")
    headers = {
        "Authorization": "Basic %s" % basic,
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": USER_AGENT,
    }
    body = {
        "description": "ddeploy",
        "url": url,
        "active": True,
        "secret": secret,
        "events": [
            "repo:push",
            "pullrequest:created",
            "pullrequest:updated",
            "pullrequest:fulfilled",
            "pullrequest:rejected",
        ],
    }
    return _request("POST", "%s/2.0/workspaces/%s/hooks" % (api, workspace), headers, body)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: register_webhook.py <github|bitbucket> <org-or-workspace>\n")
        return 1
    provider, target = argv[1], argv[2]

    url = os.environ.get("DDEPLOY_WEBHOOK_URL", "")
    secret = os.environ.get("DDEPLOY_WEBHOOK_SECRET", "")
    if not url or not secret:
        sys.stderr.write("missing DDEPLOY_WEBHOOK_URL/DDEPLOY_WEBHOOK_SECRET\n")
        return 1

    try:
        if provider == "github":
            token = os.environ.get("DDEPLOY_GITHUB_TOKEN", "")
            if not token:
                sys.stderr.write("missing DDEPLOY_GITHUB_TOKEN\n")
                return 1
            api = _api_root(os.environ.get("DDEPLOY_GITHUB_API", ""), "https://api.github.com")
            status, raw = register_github(api, target, url, secret, token)
        elif provider == "bitbucket":
            user = os.environ.get("DDEPLOY_BITBUCKET_USER", "")
            password = os.environ.get("DDEPLOY_BITBUCKET_PASSWORD", "")
            if not user or not password:
                sys.stderr.write("missing DDEPLOY_BITBUCKET_USER/DDEPLOY_BITBUCKET_PASSWORD\n")
                return 1
            api = _api_root(os.environ.get("DDEPLOY_BITBUCKET_API", ""), "https://api.bitbucket.org")
            status, raw = register_bitbucket(api, target, url, secret, user, password)
        else:
            sys.stderr.write("unknown provider: %s\n" % provider)
            return 1
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        sys.stderr.write("request failed: %s\n" % exc)
        return 1

    sys.stdout.write(raw + "\n")
    if 200 <= status < 300:
        return 0
    sys.stderr.write("HTTP %s\n" % status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
