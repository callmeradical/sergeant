#!/usr/bin/env python3
"""Verify that an inherited descriptor is still bound to an owned path."""

import os
import stat
import subprocess
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
    if action not in ("verify", "read", "migrate") or (action == "verify" and len(sys.argv) != 4):
        return None
    expected = sys.argv[5] if len(sys.argv) == 6 else None
    if expected is not None and action not in ("read", "migrate"):
        return None
    if action == "migrate" and expected is None:
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


def run_migration_test_hook(phase, path):
    """Run one explicitly enabled, root-confined migration test hook."""
    if os.environ.get("SGT_TEST_HOOKS") != "1":
        return True
    hook = os.environ.get("_SGT_OWNED_FILE_MIGRATE_HOOK")
    root = os.environ.get("_SGT_OWNED_FILE_HOOK_ROOT")
    if not hook:
        return True
    if not root or not os.path.isabs(root) or not os.path.isabs(hook):
        return False
    if os.path.dirname(hook) != root:
        return False
    try:
        root_stat = os.lstat(root)
        hook_stat = os.lstat(hook)
    except OSError:
        return False
    uid = os.geteuid()
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != uid:
        return False
    if not stat.S_ISREG(hook_stat.st_mode) or hook_stat.st_uid != uid:
        return False
    if hook_stat.st_mode & 0o111 == 0:
        return False
    try:
        completed = subprocess.run(
            [hook, phase, path],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return False
    return completed.returncode == 0


def migrate_record(fd, path, modes, expected):
    """Migrate mode on the inode held by fd without replacing path content.

    Hardlink aliases owned by the same UID name the same inode and therefore
    observe the same mode change.  Link count is not used as a security
    boundary because another same-UID process can change it around fchmod.
    """
    opened = verify_binding(fd, path, modes)
    if opened is None:
        return None
    try:
        os.lseek(fd, 0, os.SEEK_SET)
    except OSError:
        return None
    data = read_text_record(fd, path, modes, expected)
    if data is None:
        return None
    stable_size = opened.st_size
    stable_mtime = opened.st_mtime_ns
    stable_ctime = opened.st_ctime_ns

    if not run_migration_test_hook("before-fchmod", path):
        return None
    # Re-read exact bytes after the test/race boundary.  A same-inode write or
    # pathname replacement fails before mode mutation.
    opened = verify_binding(fd, path, modes)
    if opened is None:
        return None
    if (opened.st_size != stable_size or opened.st_mtime_ns != stable_mtime or
            opened.st_ctime_ns != stable_ctime):
        return None
    try:
        os.lseek(fd, 0, os.SEEK_SET)
    except OSError:
        return None
    if read_text_record(fd, path, modes, expected) != data:
        return None

    try:
        os.fchmod(fd, 0o600)
    except OSError:
        return None

    # fchmod legitimately changes ctime.  Snapshot the resulting binding and
    # metadata before exposing the post-fchmod race seam, then require that
    # exact snapshot afterward.
    chmod_snapshot = verify_binding(fd, path, {0o600})
    if chmod_snapshot is None:
        return None
    if (chmod_snapshot.st_size != stable_size or
            chmod_snapshot.st_mtime_ns != stable_mtime):
        return None
    if not run_migration_test_hook("after-fchmod", path):
        return None

    migrated = verify_binding(fd, path, {0o600})
    if migrated is None:
        return None
    snapshot_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(migrated, field) != getattr(chmod_snapshot, field)
           for field in snapshot_fields):
        return None
    try:
        os.lseek(fd, 0, os.SEEK_SET)
    except OSError:
        return None
    if read_text_record(fd, path, {0o600}, expected) != data:
        return None
    return data


def main() -> int:
    arguments = parse_arguments()
    if arguments is None:
        return 64
    fd, path, modes, action, expected = arguments

    if action in ("read", "migrate"):
        data = (read_text_record(fd, path, modes, expected) if action == "read" else
                migrate_record(fd, path, modes, expected))
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
