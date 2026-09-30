#!/usr/bin/env python3
"""Root-context counterpart to the unprivileged listener.py.

Invoked once per raw-*.json envelope by hook-worker (lib/cmd_hook.sh,
already root). Does the actual HMAC verification and forge-payload
parsing — the two things listener.py deliberately no longer does — using
secret files that are root:root 600, never readable by WEBHOOK_USER
(the listener's own, unprivileged identity). See hookparse.py's own
module docstring for why the secret has to live entirely outside the
listener process to mean anything.

usage: verify_and_spool.py <envelope.json> --secret <path> [--secret-bitbucket <path>]

Exit codes (distinct so the bash caller can tell these apart):
  0  verified. Either a job was produced, or there was nothing to do
     (ping, deleted branch, closed-but-uninteresting PR, ...) — success.
  2  HMAC verification failed — not a real, correctly-signed delivery.
  1  malformed envelope / secret file missing / other unexpected error.

Whatever the exit code, stdout is one JSON report for the worker's
webhook log (logs/webhook.log):
  {"result": "job" | "ignored" | "hmac_failed" | "malformed" | "error",
   "reason": "...", "meta": {...}, "job": {...} | null}
meta holds display-only strings (provider, forge event, delivery id,
repo, branch, ...), each reduced to a short run of printable characters
— some come from an unverified envelope, so they're for a human reading
the log, never for deciding anything. Only "job" is acted on, and only
with exit code 0.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hookparse import parse_bitbucket, parse_github, read_secret, verify_hmac  # noqa: E402

ALLOWED_EVENTS = frozenset({"push_head", "preview_upsert", "preview_remove"})
_UNSAFE = re.compile(r"[^A-Za-z0-9._:/@+#-]")


def _clean(val: Any, limit: int = 100) -> str:
    """Log-safe: printable, no whitespace (the log is space-separated)."""
    if val is None or isinstance(val, (dict, list)):
        return ""
    return _UNSAFE.sub("_", str(val))[:limit]


def _dig(data: Any, *path: Any) -> Any:
    for key in path:
        if isinstance(data, dict):
            data = data.get(key)
        elif isinstance(data, list) and isinstance(key, int) and len(data) > key:
            data = data[key]
        else:
            return None
    return data


def _payload_meta(provider: str, data: dict[str, Any]) -> dict[str, str]:
    """Repo/branch/actor from an already-verified payload, for the log."""
    meta = {"repo": _clean(_dig(data, "repository", "full_name"))}
    if provider == "github":
        ref = _dig(data, "ref") or _dig(data, "pull_request", "head", "ref") or ""
        meta["branch"] = _clean(str(ref).removeprefix("refs/heads/"))
        meta["action"] = _clean(_dig(data, "action"))
        meta["actor"] = _clean(_dig(data, "sender", "login")
                               or _dig(data, "pusher", "name"))
    else:
        branch = (_dig(data, "push", "changes", 0, "new", "name")
                  or _dig(data, "push", "changes", 0, "old", "name")
                  or _dig(data, "pullrequest", "source", "branch", "name"))
        meta["branch"] = _clean(branch)
        meta["actor"] = _clean(_dig(data, "actor", "display_name")
                               or _dig(data, "actor", "nickname"))
    return {k: v for k, v in meta.items() if v}


def _report(result: str, reason: str, meta: dict[str, str], job: Any = None) -> None:
    report = {"result": result, "reason": reason, "meta": meta, "job": job}
    sys.stdout.write(json.dumps(report, separators=(",", ":")))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("envelope")
    ap.add_argument("--secret", required=True)
    ap.add_argument("--secret-bitbucket", default="")
    args = ap.parse_args(argv[1:])

    meta: dict[str, str] = {}
    try:
        raw = json.loads(Path(args.envelope).read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            for key in ("provider", "forge_event", "delivery", "received_at", "remote"):
                if raw.get(key):
                    meta[key] = _clean(raw.get(key))
        provider = raw["provider"]
        sig_header = raw.get("sig_header") or ""
        forge_event = raw.get("forge_event") or ""
        body = base64.b64decode(raw["body_b64"])
    except Exception as exc:  # noqa: BLE001 — any malformed envelope is the same outcome
        sys.stderr.write("malformed envelope: %s\n" % exc)
        _report("malformed", "malformed envelope", meta)
        return 1

    if provider == "bitbucket":
        secret = read_secret(args.secret_bitbucket) or read_secret(args.secret)
    else:
        secret = read_secret(args.secret)
    if not secret:
        sys.stderr.write("no usable secret for provider=%s\n" % provider)
        _report("error", "no usable webhook secret on this server", meta)
        return 1

    if not verify_hmac(sig_header, body, secret):
        sys.stderr.write("hmac failed provider=%s\n" % provider)
        _report("hmac_failed", "signature does not match the webhook secret", meta)
        return 2

    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        sys.stderr.write("invalid json body: %s\n" % exc)
        _report("malformed", "invalid JSON body", meta)
        return 1
    if not isinstance(data, dict):
        sys.stderr.write("invalid json body: not an object\n")
        _report("malformed", "JSON body is not an object", meta)
        return 1

    meta.update(_payload_meta(provider, data))

    if provider == "github":
        job = parse_github(forge_event, data)
    else:
        job = parse_bitbucket(forge_event, data)

    if job is None or job.get("event") not in ALLOWED_EVENTS:
        _report("ignored", "nothing to do for event '%s'" % _clean(forge_event), meta)
        return 0

    _report("job", str(job.get("event")), meta, job)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
