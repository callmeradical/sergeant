#!/usr/bin/env python3
"""Verify that an inherited descriptor is still bound to an owned path."""

import os
import stat
import sys
import unicodedata

MAX_RECORD_BYTES = 64 * 1024


def parse_arguments():
    if len(sys.argv) not in (4, 5, 6):
        return None
    fd_text, path, mode_text = sys.argv[1:4]
    if not fd_text.isascii() or not fd_text.isdecimal() or not path:
        return None
    fd = int(fd_text, 10)
    if fd < 0 or fd > 1024:
        return None

    modes = set()
    for value in mode_text.split(","):
        if len(value) not in (3, 4) or any(char not in "01234567" for char in value):
            return None
        modes.add(int(value, 8))
    if not modes:
        return None

    action = "verify" if len(sys.argv) == 4 else sys.argv[4]
    if action not in ("verify", "read") or (action == "verify" and len(sys.argv) != 4):
        return None
    expected = sys.argv[5] if len(sys.argv) == 6 else None
    if expected is not None and action != "read":
        return None
    return fd, path, modes, action, expected


def verify_binding(fd, path, modes):
    """Return fstat metadata when fd and path name the same safe inode."""

    try:
        opened = os.fstat(fd)
        current = os.lstat(path)
    except (OSError, ValueError):
        return None

    expected_uid = os.geteuid()
    if not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(current.st_mode):
        return None
    if opened.st_uid != expected_uid or current.st_uid != expected_uid:
        return None
    if stat.S_IMODE(opened.st_mode) not in modes or stat.S_IMODE(current.st_mode) not in modes:
        return None
    if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        return None
    return opened


def read_text_record(fd, path, modes, expected):
    """Read one bounded, canonical UTF-8 line without Bash normalization."""
    before = verify_binding(fd, path, modes)
    if before is None or before.st_size > MAX_RECORD_BYTES:
        return None

    chunks = []
    remaining = MAX_RECORD_BYTES + 1
    try:
        while remaining:
            chunk = os.read(fd, min(8192, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
    except OSError:
        return None
    data = b"".join(chunks)
    if len(data) > MAX_RECORD_BYTES or len(data) != before.st_size:
        return None

    after = verify_binding(fd, path, modes)
    if after is None:
        return None
    stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        return None

    if not data.endswith(b"\n") or data.endswith(b"\n\n") or b"\n" in data[:-1]:
        return None
    try:
        text = data[:-1].decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    if not text or any(unicodedata.category(char) == "Cc" for char in text):
        return None
    if expected is not None:
        try:
            expected_bytes = expected.encode("utf-8", errors="strict") + b"\n"
        except UnicodeEncodeError:
            return None
        if data != expected_bytes:
            return None
    return data


def main() -> int:
    arguments = parse_arguments()
    if arguments is None:
        return 64
    fd, path, modes, action, expected = arguments

    if action == "read":
        data = read_text_record(fd, path, modes, expected)
        if data is None:
            return 1
        try:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except (BrokenPipeError, OSError):
            return 1
        return 0

    opened = verify_binding(fd, path, modes)
    if opened is None:
        return 1

    print(f"{opened.st_dev}:{opened.st_ino}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
