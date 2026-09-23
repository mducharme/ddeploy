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
  0  verified. A job was produced: printed as JSON on stdout.
     No job (ping, deleted branch, closed-but-uninteresting PR, ...):
     nothing on stdout — still success, just nothing to do.
  2  HMAC verification failed — not a real, correctly-signed delivery.
  1  malformed envelope / secret file missing / other unexpected error.
"""
from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hookparse import parse_bitbucket, parse_github, read_secret, verify_hmac  # noqa: E402

ALLOWED_EVENTS = frozenset({"push_head", "preview_upsert", "preview_remove"})


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("envelope")
    ap.add_argument("--secret", required=True)
    ap.add_argument("--secret-bitbucket", default="")
    args = ap.parse_args(argv[1:])

    try:
        raw = json.loads(Path(args.envelope).read_text(encoding="utf-8"))
        provider = raw["provider"]
        sig_header = raw.get("sig_header") or ""
        forge_event = raw.get("forge_event") or ""
        body = base64.b64decode(raw["body_b64"])
    except Exception as exc:  # noqa: BLE001 — any malformed envelope is the same outcome
        sys.stderr.write("malformed envelope: %s\n" % exc)
        return 1

    if provider == "bitbucket":
        secret = read_secret(args.secret_bitbucket) or read_secret(args.secret)
    else:
        secret = read_secret(args.secret)
    if not secret:
        sys.stderr.write("no usable secret for provider=%s\n" % provider)
        return 1

    if not verify_hmac(sig_header, body, secret):
        sys.stderr.write("hmac failed provider=%s\n" % provider)
        return 2

    try:
        data = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        sys.stderr.write("invalid json body: %s\n" % exc)
        return 1
    if not isinstance(data, dict):
        sys.stderr.write("invalid json body: not an object\n")
        return 1

    if provider == "github":
        job = parse_github(forge_event, data)
    else:
        job = parse_bitbucket(forge_event, data)

    if job is None or job.get("event") not in ALLOWED_EVENTS:
        return 0

    sys.stdout.write(json.dumps(job, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
