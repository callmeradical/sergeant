#!/usr/bin/env python3
"""Verify that an inherited descriptor is still bound to an owned path."""

import os
import stat
import sys


def main() -> int:
    if len(sys.argv) != 4:
        return 64

    fd_text, path, mode_text = sys.argv[1:]
    if not fd_text.isascii() or not fd_text.isdecimal() or not path:
        return 64
    fd = int(fd_text, 10)
    if fd < 0 or fd > 1024:
        return 64

    modes = set()
    for value in mode_text.split(","):
        if len(value) not in (3, 4) or any(char not in "01234567" for char in value):
            return 64
        modes.add(int(value, 8))
    if not modes:
        return 64

    try:
        opened = os.fstat(fd)
        current = os.lstat(path)
    except (OSError, ValueError):
        return 1

    expected_uid = os.geteuid()
    if not stat.S_ISREG(opened.st_mode) or not stat.S_ISREG(current.st_mode):
        return 1
    if opened.st_uid != expected_uid or current.st_uid != expected_uid:
        return 1
    if stat.S_IMODE(opened.st_mode) not in modes or stat.S_IMODE(current.st_mode) not in modes:
        return 1
    if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
        return 1

    print(f"{opened.st_dev}:{opened.st_ino}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
