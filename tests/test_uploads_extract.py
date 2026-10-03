"""Tests for lib/uploads_extract.py — hostile archives first.

    python3 -m unittest tests/test_uploads_extract.py
"""
from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

EXTRACT = Path(__file__).resolve().parent.parent / "lib" / "uploads_extract.py"


def tar_bytes(entries, gz=False) -> bytes:
    """entries: (name, data | None for a dir, extra TarInfo attrs)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz" if gz else "w") as tf:
        for name, data, attrs in entries:
            ti = tarfile.TarInfo(name)
            for k, v in (attrs or {}).items():
                setattr(ti, k, v)
            if data is None and not attrs:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            elif data is None:
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def zip_bytes(entries) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data, mode in entries:
            zi = zipfile.ZipInfo(name)
            if mode:
                zi.external_attr = mode << 16
            zf.writestr(zi, data)
    return buf.getvalue()


class Extract(unittest.TestCase):
    def run_extract(self, archive: bytes, *args: str, max_bytes: int = 10_000_000):
        self.dest = tempfile.mkdtemp()
        src = tempfile.NamedTemporaryFile(delete=False)
        src.write(archive)
        src.close()
        with open(src.name, "rb") as stdin:
            p = subprocess.run([sys.executable, str(EXTRACT), self.dest, "--max-bytes", str(max_bytes), *args],
                               stdin=stdin, capture_output=True, text=True)
        os.unlink(src.name)
        return p

    def files(self) -> list[str]:
        out = []
        for root, dirs, files in os.walk(self.dest):
            for f in files:
                out.append(os.path.relpath(os.path.join(root, f), self.dest))
        return sorted(out)

    def assertRefused(self, p, fragment: str):
        self.assertEqual(p.returncode, 2, p.stderr + p.stdout)
        self.assertIn(fragment, p.stderr)
        self.assertEqual(self.files(), [], "nothing may be written for a refused archive")

    # --- accepted ---

    def test_tar(self):
        p = self.run_extract(tar_bytes([("a.jpg", b"A", None), ("2024/b.jpg", b"BB", None)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.files(), ["2024/b.jpg", "a.jpg"])
        self.assertEqual(json.loads(p.stdout), {"files": 2, "dirs": 0, "bytes": 3, "skipped": 0, "stripped": ""})

    def test_tar_gz_and_modes(self):
        p = self.run_extract(tar_bytes([("x/y.txt", b"hello", {"mode": 0o777})], gz=True))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.dest, "x/y.txt")).st_mode), 0o640)

    def test_zip(self):
        p = self.run_extract(zip_bytes([("docs/a.pdf", b"%PDF", 0), ("b.txt", b"b", 0)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.files(), ["b.txt", "docs/a.pdf"])

    def test_strips_a_wrapper_folder_named_like_the_target(self):
        p = self.run_extract(tar_bytes([("uploads/", None, None), ("uploads/a.jpg", b"A", None)]), "--expect-top", "uploads")
        self.assertEqual(self.files(), ["a.jpg"])
        self.assertEqual(json.loads(p.stdout)["stripped"], "uploads")

    def test_keeps_a_single_top_folder_with_another_name(self):
        self.run_extract(tar_bytes([("2024/a.jpg", b"A", None)]), "--expect-top", "uploads")
        self.assertEqual(self.files(), ["2024/a.jpg"])

    def test_strip_no(self):
        self.run_extract(tar_bytes([("uploads/a.jpg", b"A", None)]), "--expect-top", "uploads", "--strip", "no")
        self.assertEqual(self.files(), ["uploads/a.jpg"])

    def test_skips_mac_and_windows_junk(self):
        p = self.run_extract(zip_bytes([("a.jpg", b"A", 0), ("__MACOSX/._a.jpg", b"x", 0), ("sub/.DS_Store", b"x", 0), ("Thumbs.db", b"x", 0)]))
        self.assertEqual(self.files(), ["a.jpg"])
        self.assertEqual(json.loads(p.stdout)["skipped"], 3)

    def test_long_and_unicode_names(self):
        long = "d" * 120 + "/" + "é" * 60 + ".txt"
        p = self.run_extract(tar_bytes([(long, b"x", None)]))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.files(), [long])

    # --- refused ---

    def test_symlink(self):
        self.assertRefused(self.run_extract(tar_bytes([("a.jpg", b"A", None), ("evil", None, {"type": tarfile.SYMTYPE, "linkname": "/etc"})])), "symlink")

    def test_hardlink(self):
        self.assertRefused(self.run_extract(tar_bytes([("evil", None, {"type": tarfile.LNKTYPE, "linkname": "/etc/passwd"})])), "hardlink")

    def test_device(self):
        self.assertRefused(self.run_extract(tar_bytes([("dev", None, {"type": tarfile.CHRTYPE})])), "special file")

    def test_dotdot(self):
        self.assertRefused(self.run_extract(tar_bytes([("ok.jpg", b"A", None), ("../../escape.txt", b"x", None)])), "'..'")

    def test_absolute(self):
        self.assertRefused(self.run_extract(tar_bytes([("/etc/cron.d/evil", b"x", None)])), "absolute path")

    def test_zip_dotdot(self):
        self.assertRefused(self.run_extract(zip_bytes([("../x", b"x", 0)])), "'..'")

    def test_zip_symlink(self):
        self.assertRefused(self.run_extract(zip_bytes([("link", b"/etc/passwd", stat.S_IFLNK | 0o777)])), "symlink")

    def test_windows_absolute(self):
        self.assertRefused(self.run_extract(zip_bytes([("C:/Windows/x", b"x", 0)])), "absolute path")

    def test_over_size_limit(self):
        self.assertRefused(self.run_extract(tar_bytes([("big.bin", b"x" * 2000, None)]), max_bytes=1000), "byte limit")

    def test_zip_bomb_declared_size(self):
        self.assertRefused(self.run_extract(zip_bytes([("bomb.bin", b"\0" * 5_000_000, 0)]), max_bytes=1_000_000), "byte limit")

    def test_not_an_archive(self):
        self.assertRefused(self.run_extract(b"just some text, not an archive" * 50), "not a .zip")

    def test_truncated(self):
        good = tar_bytes([("a.bin", os.urandom(50_000), None)], gz=True)
        p = self.run_extract(good[: len(good) // 2])
        self.assertEqual(p.returncode, 2, p.stderr)

    def test_empty(self):
        self.assertRefused(self.run_extract(tar_bytes([("onlydir/", None, None)])), "no files")


if __name__ == "__main__":
    unittest.main()
