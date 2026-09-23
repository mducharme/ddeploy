"""Pure git-forge webhook helpers, shared by listener.py (unprivileged,
never holds the real HMAC secret post-A4) and verify_and_spool.py (root
context, the only place that does — see README "Deploy on git push").

No side effects, no environment/file access other than _read_secret's own
explicit path argument. Kept separate so both processes import the exact
same parsing logic rather than two copies that can silently drift.
"""
from __future__ import annotations

import hashlib
import hmac
import re
from pathlib import Path
from typing import Any

PR_ID_RE = re.compile(r"^[1-9][0-9]{0,9}$")


def _pr_id(val: Any) -> str:
    """Digits-only PR number/id, or empty. Never pass forge JSON through."""
    if isinstance(val, bool) or val is None:
        return ""
    if isinstance(val, int) and 0 < val <= 9_999_999_999:
        return str(val)
    s = str(val).strip()
    if PR_ID_RE.fullmatch(s):
        return s
    return ""


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
            "pr": _pr_id(pr.get("number")),
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
            "pr": _pr_id(pr.get("id")),
        }
    return None


def read_secret(path: str) -> bytes:
    if not path:
        return b""
    p = Path(path)
    try:
        if not p.is_file():
            return b""
        return p.read_bytes().strip()
    except PermissionError:
        return b""
