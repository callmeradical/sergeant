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


def parse_bytes(data, marker):
    if not data or not data.endswith(b"\n") or data.endswith(b"\n\n"):
        fail("worker marker history requires exactly one terminal LF")
    lines = data[:-1].split(b"\n")
    parsed = []
    for line in lines:
        match = LINE_RE.fullmatch(line)
        if not match:
            fail("worker marker history contains a noncanonical line")
        parsed.append(
            (match.group(1).decode(), match.group(2).decode(), int(match.group(3)))
        )
    selected_floor = None
    if marker is not None:
        match = MARKER_RE.fullmatch(marker)
        matches = [] if not match else [
            record for record in parsed
            if record[:2] == (match.group(1), match.group(2))
        ]
        if len(matches) != 1:
            fail("current marker generation is absent from durable history")
        selected_floor = matches[0][2]
    return hashlib.sha256(data).hexdigest(), selected_floor, any(
        record[2] == 0 for record in parsed
    )


def read_open_fd(fd, path):
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid():
            fail("worker marker history is not an owned regular file")
        if stat.S_IMODE(opened.st_mode) != 0o600:
            fail("worker marker history mode must be 0600")
        data = os.read(fd, 8193)
        if len(data) > 8192 or os.read(fd, 1):
            fail("worker marker history exceeds 8192 bytes")
        final = os.fstat(fd)
        after = os.lstat(path)
        stable = ("st_dev", "st_ino", "st_uid", "st_mode", "st_size", "st_ctime_ns")
        if any(getattr(opened, key) != getattr(final, key) for key in stable) or any(
            getattr(final, key) != getattr(after, key) for key in stable
        ):
            fail("worker marker history changed while inspecting")
        return data
    except (FileNotFoundError, PermissionError, OSError) as exc:
        fail(f"cannot read worker marker history exactly: {exc}")


def main():
    descriptor_mode = len(sys.argv) == 5 and sys.argv[1] == "--fd"
    if descriptor_mode:
        try:
            fd = int(sys.argv[2])
        except ValueError:
            fail("worker marker history descriptor is invalid")
        path = sys.argv[3]
        marker = sys.argv[4]
        data = read_open_fd(fd, path)
        digest, selected_floor, has_portable = parse_bytes(data, marker)
        print(f"{digest}|{selected_floor}|{'true' if has_portable else 'false'}")
        return
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

    digest, _, _ = parse_bytes(data, marker)
    print(digest)


if __name__ == "__main__":
    main()
