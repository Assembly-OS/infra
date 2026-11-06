#!/usr/bin/env python3
"""Validate a project backup and restore only its uploads and legacy SQLite file."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import time


def validate(root):
    allowed = {"database.dump", "identity.json", "uploads.tar.gz", "assambleya.db", "counts.tsv"}
    checked = set()
    for line in (root / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        if name not in allowed or name in checked or (root / name).is_symlink():
            raise ValueError("Unexpected backup member")
        with (root / name).open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
                raise ValueError("Backup checksum mismatch")
        checked.add(name)
    if not {"database.dump", "identity.json", "uploads.tar.gz"} <= checked:
        raise ValueError("Incomplete project backup")
    identity = json.loads((root / "identity.json").read_text())
    if identity.get("project") != "assembly-os":
        raise ValueError("Backup belongs to another project")
    if (root / "assambleya.db").exists():
        if "assambleya.db" not in checked:
            raise ValueError("Unchecked legacy database")
        with sqlite3.connect(f"file:{root / 'assambleya.db'}?mode=ro", uri=True) as db:
            if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("Legacy SQLite integrity check failed")
    with tarfile.open(root / "uploads.tar.gz", "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("Empty media archive")
        for item in members:
            path = PurePosixPath(item.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] != "uploads" or "\\" in item.name
                    or not (item.isfile() or item.isdir())):
                raise ValueError("Unsafe media archive member")
    return checked


def apply(root, target=Path("/var/lib/assembly-os/data")):
    validate(root)
    stamp = str(time.time_ns())
    # Preserve existing media/SQLite for recovery; never touch a Docker volume.
    with tempfile.TemporaryDirectory(dir=target.parent, prefix="restore-") as temporary:
        with tarfile.open(root / "uploads.tar.gz", "r:gz") as archive:
            archive.extractall(temporary, filter="data")
        extracted = Path(temporary) / "uploads"
        for entry in [extracted, *extracted.rglob("*")]:
            if sys.platform != "win32":
                import os
                os.chown(entry, 10001, 10001)
            entry.chmod(0o750 if entry.is_dir() else 0o640)
        if (target / "uploads").exists():
            (target / "uploads").rename(target / f"uploads.before-{stamp}")
        extracted.rename(target / "uploads")
    if (root / "assambleya.db").exists():
        for name in ("assambleya.db", "assambleya.db-wal", "assambleya.db-shm"):
            if (target / name).exists():
                (target / name).rename(target / f"{name}.before-{stamp}")
        shutil.copyfile(root / "assambleya.db", target / "assambleya.db")
        (target / "assambleya.db").chmod(0o600)
        if sys.platform != "win32":
            import os
            os.chown(target / "assambleya.db", 10001, 10001)


if __name__ == "__main__":
    folder = Path(sys.argv[1]).resolve(strict=True)
    if sys.argv[2] == "--validate":
        validate(folder)
    elif sys.argv[2] == "--apply":
        apply(folder)
    else:
        raise SystemExit("Expected --validate or --apply")
