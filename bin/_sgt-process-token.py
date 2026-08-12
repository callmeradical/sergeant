#!/usr/bin/env python3
"""Retire Linux holders of inherited Sergeant worker marker FDs."""

import os
import re
import signal
import stat
import sys
import time

MARKER_RE = re.compile(r"^[0-9a-f]{32}\|([0-9]+):([0-9]+)\|([0-9]+)$")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def stat_fields(pid):
    data = open(f"/proc/{pid}/stat", "rb").read(8192).decode("ascii", "strict")
    fields = data[data.rfind(") ") + 2 :].split()
    return fields[0], fields[19]


def read_owned_history(path):
    try:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            fail("worker process marker history is not an owned regular file")
        if stat.S_IMODE(before.st_mode) != 0o600:
            fail("worker process marker history mode must be 0600")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                fail("worker process marker history changed before open")
            test_pause = os.environ.get("SGT_PROCESS_TOKEN_TEST_PAUSE_AFTER_OPEN")
            if test_pause:
                open(test_pause + ".opened", "xb").close()
                for _ in range(200):
                    if os.path.exists(test_pause + ".release"):
                        break
                    time.sleep(0.01)
                else:
                    fail("test path-swap release timed out")
            data = os.read(fd, 8193)
            if len(data) > 8192 or os.read(fd, 1):
                fail("worker process marker history exceeds 8192 bytes")
            after = os.lstat(path)
            final = os.fstat(fd)
            stable = (
                "st_dev",
                "st_ino",
                "st_uid",
                "st_mode",
                "st_size",
                "st_mtime_ns",
                "st_ctime_ns",
            )
            if any(getattr(before, key) != getattr(after, key) for key in stable) or any(
                getattr(opened, key) != getattr(final, key) for key in stable
            ) or (after.st_dev, after.st_ino) != (final.st_dev, final.st_ino):
                fail("worker process marker history changed while reading")
            return data
        finally:
            os.close(fd)
    except (FileNotFoundError, PermissionError, OSError) as exc:
        fail(f"cannot read worker process marker history exactly: {exc}")


def load_markers(path, allow_empty=False):
    markers = {}
    data = read_owned_history(path)
    if not data:
        if allow_empty:
            return markers
        fail("worker process marker history is empty")
    if not data.endswith(b"\n") or data.endswith(b"\n\n"):
        fail("worker process marker history requires exactly one terminal LF")
    try:
        lines = data[:-1].decode("ascii", "strict").split("\n")
    except UnicodeDecodeError:
        fail("worker process marker history is not canonical ASCII")
    for line in lines:
        match = MARKER_RE.fullmatch(line)
        if not match:
            fail("malformed durable worker process marker history")
        generation = line.split("|", 1)[0]
        identity = (int(match.group(1)), int(match.group(2)))
        floor = int(match.group(3))
        prior = markers.get(identity)
        if prior is not None and prior != (generation, floor):
            fail("worker process marker identity is reused across generations")
        markers[identity] = (generation, floor)
    return markers


def holds_marker(pid, markers):
    directory = f"/proc/{pid}/fd"
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return False
    for name in names:
        try:
            path = f"{directory}/{name}"
            info = os.stat(path)
            marker = markers.get((info.st_dev, info.st_ino))
            if marker is None:
                continue
            generation, _ = marker
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
            try:
                content = os.pread(fd, 128, 0)
            finally:
                os.close(fd)
            if content == (generation + "\n").encode("ascii"):
                return True
        except FileNotFoundError:
            continue
    return False


def enumerate_holders(markers):
    owners = {}
    uid = os.geteuid()
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            state, start = stat_fields(pid)
            if state == "Z":
                continue
            if os.stat(f"/proc/{pid}").st_uid != uid:
                continue
            # Only processes launched after at least one retained generation
            # can possibly be holders.  Any same-UID fd table in that range is
            # part of the proof boundary: unreadability is ambiguity, not exit.
            if not any(int(start) >= floor for _, floor in markers.values()):
                continue
            if holds_marker(pid, markers):
                owners[pid] = start
        except FileNotFoundError:
            continue
        except PermissionError:
            fail(f"cannot inspect same-UID post-launch PID {pid} fd ownership")
        except OSError as exc:
            fail(f"cannot inspect worker marker holder PID {pid}: {exc}")
    return owners


def load_expected(path):
    expected = {}
    for line in open(path, encoding="utf-8"):
        if not line.startswith("member="):
            continue
        fields = line.removeprefix("member=").strip().split("|")
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].startswith("linux:"):
            expected[int(fields[0])] = fields[1].removeprefix("linux:")
    return expected


def ensure_expected_holds(expected, holders, markers):
    for pid, start in expected.items():
        try:
            state, actual = stat_fields(pid)
            if state == "Z":
                continue
            if actual == start and pid not in holders:
                try:
                    holds = holds_marker(pid, markers)
                except PermissionError:
                    fail(f"cannot inspect attributable worker PID {pid} fd ownership")
                if not holds:
                    fail(f"attributable worker PID {pid} closed its ownership marker FD")
        except FileNotFoundError:
            continue


def retire(markers, expected):
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        fail("exact pidfd worker retirement is unavailable on this platform")
    held = {}
    prior = None
    for _ in range(40):
        owners = enumerate_holders(markers)
        ensure_expected_holds(expected, owners, markers)
        for pid, start in owners.items():
            if pid in held:
                if held[pid][0] != start:
                    fail(f"PID identity changed during worker retirement: {pid}")
                continue
            try:
                fd = os.pidfd_open(pid, 0)
                state, confirmed = stat_fields(pid)
                if confirmed != start or not holds_marker(pid, markers):
                    os.close(fd)
                    fail(f"PID identity changed before pidfd marker proof: {pid}")
                if state == "Z":
                    os.close(fd)
                    continue
                held[pid] = (start, fd)
            except ProcessLookupError:
                continue
        for pid, (_, fd) in list(held.items()):
            try:
                signal.pidfd_send_signal(fd, signal.SIGSTOP)
            except ProcessLookupError:
                os.close(fd)
                del held[pid]
        time.sleep(0.01)
        current = enumerate_holders(markers)
        ensure_expected_holds(expected, current, markers)
        if current == prior and set(current).issubset(held):
            if all(stat_fields(pid)[0] in ("T", "t", "Z") for pid in current):
                break
        prior = current
    else:
        fail("worker marker holder set did not stabilize while stopped")
    for pid, (_, fd) in held.items():
        try:
            state, _ = stat_fields(pid)
            if state != "Z":
                if state not in ("T", "t"):
                    fail(f"worker marker holder was not stopped before KILL: {pid}")
                signal.pidfd_send_signal(fd, signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError):
            pass
        finally:
            os.close(fd)
    for _ in range(40):
        if not enumerate_holders(markers):
            return
        time.sleep(0.025)
    fail("live worker marker holders remain after pidfd retirement")


def compact(path, markers):
    holders = enumerate_holders(markers) if markers else {}
    live = set()
    for pid in holders:
        directory = f"/proc/{pid}/fd"
        for name in os.listdir(directory):
            try:
                info = os.stat(f"{directory}/{name}")
                identity = (info.st_dev, info.st_ino)
                if identity in markers and holds_marker(pid, {identity: markers[identity]}):
                    live.add(identity)
            except FileNotFoundError:
                continue
    if len(live) > 64:
        fail("too many live worker marker generations; retire workers before relaunch")
    temporary = f"{path}.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(temporary, flags, 0o600)
    try:
        for identity, (generation, floor) in markers.items():
            if identity in live:
                os.write(fd, f"{generation}|{identity[0]}:{identity[1]}|{floor}\n".encode("ascii"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)


def main():
    if len(sys.argv) == 6 and sys.argv[1] == "check":
        history, pid_text, start, identity = sys.argv[2:]
        markers = load_markers(history)
        if not pid_text.isdigit() or not re.fullmatch(r"[0-9]+:[0-9]+", identity):
            fail("invalid worker marker check request")
        pid = int(pid_text)
        state, actual = stat_fields(pid)
        if state == "Z" or actual != start or not holds_marker(pid, markers):
            fail(f"worker process marker conflicts with supervisor PID {pid}")
        if tuple(map(int, identity.split(":"))) not in markers:
            fail("current worker marker is absent from durable history")
        return
    if len(sys.argv) == 3 and sys.argv[1] in ("holders", "compact"):
        markers = load_markers(sys.argv[2], allow_empty=sys.argv[1] == "compact")
        if sys.argv[1] == "holders":
            for pid, start in sorted(enumerate_holders(markers).items() if markers else []):
                print(f"{pid}|linux:{start}")
        else:
            compact(sys.argv[2], markers)
        return
    if len(sys.argv) != 4 or sys.argv[1] != "retire":
        fail("invalid worker marker retirement request")
    markers = load_markers(sys.argv[2])
    retire(markers, load_expected(sys.argv[3]))


if __name__ == "__main__":
    main()
