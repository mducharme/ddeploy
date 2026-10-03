#!/usr/bin/env python3
"""Safely extract an uploads archive (tar, tar.gz or zip) into a directory.

Run by `ddeploy uploads-import` AS THE SITE'S OWN USER, never root, with
the archive on stdin (a regular file, so it's seekable) and an empty
staging directory as the destination. The archive is untrusted input —
a client's export, or anything a web UI user drags in — so before a
single byte is written every member is checked:

  - only regular files and directories (no symlinks, hardlinks, devices,
    fifos): a link is how an archive writes outside its destination
  - no absolute paths, no '..' segments, no NUL or control characters
  - declared sizes add up to at most --max-bytes, and at most
    --max-files members (a zip bomb declares its real sizes or fails
    the size check while being read)
Mac/Windows junk (__MACOSX/, .DS_Store, Thumbs.db) is skipped.

--strip auto drops a single top-level directory when every member is
under it AND it's named like the target (--expect-top): someone zipped
the "uploads" folder itself rather than its contents.

Prints one JSON object: {"files", "dirs", "bytes", "skipped", "stripped"}.
Exits 2 on a refused archive (message on stderr), 1 on other errors.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tarfile
import zipfile
from pathlib import PurePosixPath
from typing import BinaryIO, Iterator

JUNK_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini"}
JUNK_DIRS = {"__MACOSX"}
CHUNK = 1024 * 1024


class Refused(Exception):
    pass


class Member:
    def __init__(self, index: int, name: str, is_dir: bool, size: int):
        self.index = index
        self.name = name
        self.is_dir = is_dir
        self.size = size


def clean_path(raw: str) -> PurePosixPath | None:
    """The member's relative path, or None for the archive root ('./')."""
    if any(ord(c) < 32 for c in raw):
        raise Refused(f"member name with a control character: {raw!r}")
    name = raw.replace("\\", "/")
    if name.startswith("/") or (len(name) > 1 and name[1] == ":"):
        raise Refused(f"absolute path in archive: {raw}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise Refused(f"'..' in archive path: {raw}")
    return PurePosixPath(*parts) if parts else None


SKIP_TAR_TYPES = (tarfile.XHDTYPE, tarfile.XGLTYPE, tarfile.GNUTYPE_LONGNAME, tarfile.GNUTYPE_LONGLINK)


def tar_check(ti: tarfile.TarInfo) -> None:
    if ti.isdir() or ti.isreg() or ti.type in SKIP_TAR_TYPES:
        return
    kind = "symlink" if ti.issym() else "hardlink" if ti.islnk() else "special file"
    raise Refused(f"{kind} in archive (only files and folders are accepted): {ti.name}")


def list_members(src: BinaryIO, is_zip: bool) -> list[Member]:
    out: list[Member] = []
    if is_zip:
        for i, zi in enumerate(zipfile.ZipFile(src).infolist()):
            mode = (zi.external_attr >> 16) & 0xFFFF
            if mode and stat.S_ISLNK(mode):
                raise Refused(f"symlink in archive (only files and folders are accepted): {zi.filename}")
            out.append(Member(i, zi.filename, zi.is_dir(), 0 if zi.is_dir() else zi.file_size))
        return out
    # Streaming mode ("r|*"): one forward pass, no seeking back through
    # a gzip stream.
    with tarfile.open(fileobj=src, mode="r|*") as tf:
        for i, ti in enumerate(tf):
            tar_check(ti)
            if ti.isdir() or ti.isreg():
                out.append(Member(i, ti.name, ti.isdir(), ti.size if ti.isreg() else 0))
    return out


def iter_data(src: BinaryIO, is_zip: bool) -> Iterator[tuple[int, BinaryIO | None]]:
    """(member index, readable data or None for a directory), in archive order."""
    if is_zip:
        zf = zipfile.ZipFile(src)
        for i, zi in enumerate(zf.infolist()):
            yield i, None if zi.is_dir() else zf.open(zi)
        return
    with tarfile.open(fileobj=src, mode="r|*") as tf:
        for i, ti in enumerate(tf):
            tar_check(ti)
            if ti.isreg():
                yield i, tf.extractfile(ti)
            elif ti.isdir():
                yield i, None


def is_junk(path: PurePosixPath) -> bool:
    return any(p in JUNK_DIRS for p in path.parts) or path.name in JUNK_NAMES


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dest")
    ap.add_argument("--max-bytes", type=int, required=True)
    ap.add_argument("--max-files", type=int, default=500_000)
    ap.add_argument("--strip", choices=["auto", "yes", "no"], default="auto")
    ap.add_argument("--expect-top", default="")
    args = ap.parse_args(argv[1:])

    src = sys.stdin.buffer
    head = src.read(4)
    src.seek(0)
    is_zip = head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06")
    try:
        try:
            members = list_members(src, is_zip)
        except tarfile.ReadError:
            raise Refused("not a .zip, .tar or .tar.gz archive")

        # Pass 1: validate everything before writing anything.
        entries: list[tuple[PurePosixPath, Member]] = []
        skipped = 0
        total = 0
        for m in members:
            path = clean_path(m.name)
            if path is None:
                continue
            if is_junk(path):
                skipped += 1
                continue
            entries.append((path, m))
            total += m.size
        if not any(not m.is_dir for _, m in entries):
            raise Refused("the archive has no files in it")
        if len(entries) > args.max_files:
            raise Refused(f"{len(entries)} entries is over the {args.max_files} limit")
        if total > args.max_bytes:
            raise Refused(f"the archive unpacks to {total} bytes, over the {args.max_bytes} byte limit")

        stripped = ""
        tops = {p.parts[0] for p, _ in entries}
        all_nested = all(len(p.parts) > 1 or m.is_dir for p, m in entries)
        if len(tops) == 1 and all_nested and args.strip != "no":
            top = next(iter(tops))
            if args.strip == "yes" or top == args.expect_top:
                stripped = top
                entries = [(PurePosixPath(*p.parts[1:]), m) for p, m in entries if len(p.parts) > 1]
        plan = {m.index: path for path, m in entries}
        declared = {m.index: m.size for _, m in entries}

        # Pass 2: extract, in archive order. Paths are clean and relative,
        # and nothing in the destination can be a link (it starts empty and
        # only gets real directories), so joining can't leave it.
        dest = os.path.realpath(args.dest)
        written = 0
        nfiles = ndirs = 0
        src.seek(0)
        for i, data in iter_data(src, is_zip):
            path = plan.get(i)
            if path is None:
                continue
            target = os.path.join(dest, *path.parts)
            if data is None:
                os.makedirs(target, mode=0o750, exist_ok=True)
                ndirs += 1
                continue
            os.makedirs(os.path.dirname(target), mode=0o750, exist_ok=True)
            remaining = declared[i]
            with data as fin, open(target, "wb") as fout:
                while True:
                    chunk = fin.read(CHUNK)
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    written += len(chunk)
                    if remaining < 0 or written > args.max_bytes:
                        raise Refused(f"{path} is larger than the archive declares")
                    fout.write(chunk)
            os.chmod(target, 0o640)
            nfiles += 1
    except Refused as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    except (zipfile.BadZipFile, tarfile.TarError, EOFError) as e:
        print(f"refused: the archive is damaged or truncated ({e})", file=sys.stderr)
        return 2

    json.dump({"files": nfiles, "dirs": ndirs, "bytes": written, "skipped": skipped, "stripped": stripped}, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
