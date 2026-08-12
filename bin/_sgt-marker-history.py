#!/usr/bin/env python3
"""Validate and hash exact owned worker marker-history bytes."""

import hashlib
import os
import re
import stat
import sys

LINE_RE = re.compile(rb"([0-9a-f]{32})\|([0-9]+:[0-9]+)\|([0-9]+)")
MARKER_RE = re.compile(r"([0-9a-f]{32})\|([0-9]+:[0-9]+)\|198\|.+")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) not in (2, 3):
        fail("usage: _sgt-marker-history.py <history> [current-marker]")
    path = sys.argv[1]
    marker = sys.argv[2] if len(sys.argv) == 3 else None
    try:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            fail("worker marker history is not an owned regular file")
        if stat.S_IMODE(before.st_mode) != 0o600:
            fail("worker marker history mode must be 0600")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                fail("worker marker history changed before open")
            data = os.read(fd, 8193)
            if len(data) > 8192 or os.read(fd, 1):
                fail("worker marker history exceeds 8192 bytes")
            after = os.lstat(path)
            final = os.fstat(fd)
            stable = ("st_dev", "st_ino", "st_uid", "st_mode", "st_size", "st_ctime_ns")
            if any(getattr(before, key) != getattr(after, key) for key in stable) or any(
                getattr(opened, key) != getattr(final, key) for key in stable
            ) or (after.st_dev, after.st_ino) != (final.st_dev, final.st_ino):
                fail("worker marker history changed while hashing")
        finally:
            os.close(fd)
    except (FileNotFoundError, PermissionError, OSError) as exc:
        fail(f"cannot read worker marker history exactly: {exc}")

    if not data or not data.endswith(b"\n") or data.endswith(b"\n\n"):
        fail("worker marker history requires exactly one terminal LF")
    lines = data[:-1].split(b"\n")
    parsed = []
    for line in lines:
        match = LINE_RE.fullmatch(line)
        if not match:
            fail("worker marker history contains a noncanonical line")
        parsed.append((match.group(1).decode(), match.group(2).decode()))
    if marker is not None:
        match = MARKER_RE.fullmatch(marker)
        if not match or (match.group(1), match.group(2)) not in parsed:
            fail("current marker generation is absent from durable history")
    print(hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main()
