#!/usr/bin/env python3
"""Serialize one response-lock compare/retire/install transition."""

import fcntl
import os
import stat
import sys


def fail(code=2):
    raise SystemExit(code)


def read_bounded(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail()
        data = os.read(descriptor, 4097)
        if len(data) > 4096 or os.read(descriptor, 1):
            fail()
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            fail()
        text = data.decode("utf-8", "strict")
        return text[:-1] if text.endswith("\n") else text
    finally:
        os.close(descriptor)


def current_record(lock_path):
    try:
        info = os.lstat(lock_path)
    except FileNotFoundError:
        return "absent", None
    if stat.S_ISDIR(info.st_mode):
        try:
            if os.listdir(lock_path) != ["pid"]:
                fail()
            return "directory", read_bounded(os.path.join(lock_path, "pid"))
        except (FileNotFoundError, NotADirectoryError):
            return "changed", None
    if stat.S_ISLNK(info.st_mode):
        return "symlink", os.readlink(lock_path)
    if stat.S_ISREG(info.st_mode):
        return "file", read_bounded(lock_path)
    fail()


def main():
    if len(sys.argv) != 4:
        fail()
    lock_path, candidate, expected = sys.argv[1:]
    gate_path = lock_path + ".transition"
    gate_flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    gate_flags |= getattr(os, "O_NOFOLLOW", 0)
    gate = os.open(gate_path, gate_flags, 0o600)
    try:
        fcntl.flock(gate, fcntl.LOCK_EX)
        layout, observed = current_record(lock_path)
        if expected == "--absent":
            if layout != "absent":
                fail(3)
        else:
            if layout == "changed" or observed != expected:
                fail(3)
            if layout == "directory":
                os.unlink(os.path.join(lock_path, "pid"))
                os.rmdir(lock_path)
            elif layout in ("file", "symlink"):
                os.unlink(lock_path)
            else:
                fail(3)
        os.link(candidate, lock_path)
    finally:
        os.close(gate)


if __name__ == "__main__":
    main()
