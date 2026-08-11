#!/usr/bin/env python3
"""Retire one Linux worker ownership token through held pidfds."""

import os
import re
import signal
import sys
import time

TOKEN_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_ENVIRON = 1024 * 1024


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def stat_fields(pid):
    data = open(f"/proc/{pid}/stat", "rb").read(8192).decode("ascii", "strict")
    fields = data[data.rfind(") ") + 2 :].split()
    return fields[0], fields[19]


def owns_token(pid, token, uid):
    path = f"/proc/{pid}"
    if os.stat(path).st_uid != uid:
        return False
    with open(f"{path}/environ", "rb", buffering=0) as stream:
        data = stream.read(MAX_ENVIRON + 1)
    if len(data) > MAX_ENVIRON:
        fail(f"worker token environment exceeds {MAX_ENVIRON} bytes for PID {pid}")
    return f"SERGEANT_WORKER_PROCESS_TOKEN={token}".encode() in data.split(b"\0")


def enumerate_owners(token, minimum_start):
    owners = {}
    uid = os.geteuid()
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            state, start = stat_fields(pid)
            if int(start) < minimum_start:
                continue
            if state == "Z":
                continue
            if not owns_token(pid, token, uid):
                continue
            owners[pid] = start
        except FileNotFoundError:
            continue
        except PermissionError:
            fail(f"cannot read /proc/{pid}/environ while proving worker token ownership")
        except OSError as exc:
            fail(f"cannot inspect worker token owner PID {pid}: {exc}")
    return owners


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "check":
        token, pid_text, start = sys.argv[2:]
        if not TOKEN_RE.fullmatch(token) or not pid_text.isdigit():
            fail("invalid worker token check request")
        pid = int(pid_text)
        try:
            state, actual_start = stat_fields(pid)
            owned = owns_token(pid, token, os.geteuid())
        except PermissionError:
            fail(f"cannot read /proc/{pid}/environ while proving worker token ownership")
        if state == "Z" or actual_start != start or not owned:
            fail(f"worker process token conflicts with supervisor PID {pid}")
        return
    if len(sys.argv) != 4 or sys.argv[1] != "retire" or not TOKEN_RE.fullmatch(sys.argv[2]) or not sys.argv[3].isdigit():
        fail("invalid or missing Sergeant worker process token")
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        fail("exact pidfd worker retirement is unavailable on this platform")
    token = sys.argv[2]
    minimum_start = int(sys.argv[3])
    held = {}
    prior = None
    for _ in range(40):
        owners = enumerate_owners(token, minimum_start)
        for pid, start in owners.items():
            if pid in held:
                if held[pid][0] != start:
                    fail(f"PID identity changed during worker retirement: {pid}")
                continue
            try:
                fd = os.pidfd_open(pid, 0)
                state, confirmed = stat_fields(pid)
                if confirmed != start or not owns_token(pid, token, os.geteuid()):
                    os.close(fd)
                    fail(f"PID identity changed before pidfd ownership proof: {pid}")
                if state == "Z":
                    os.close(fd)
                    continue
                held[pid] = (start, fd)
            except ProcessLookupError:
                continue
            except PermissionError:
                fail(f"cannot read /proc/{pid}/environ while confirming pidfd ownership")
        for pid, (_, fd) in list(held.items()):
            try:
                signal.pidfd_send_signal(fd, signal.SIGSTOP)
            except ProcessLookupError:
                os.close(fd)
                del held[pid]
        time.sleep(0.01)
        current = enumerate_owners(token, minimum_start)
        if current == prior and set(current).issubset(held):
            if all(stat_fields(pid)[0] in ("T", "t", "Z") for pid in current):
                break
        prior = current
    else:
        fail("worker token owner set did not stabilize while stopped")

    # Every terminal signal goes through the already-held descriptor and only
    # after the exact process was observed stopped (or dead as a zombie).
    for pid, (_, fd) in list(held.items()):
        try:
            state, _ = stat_fields(pid)
            if state != "Z":
                if state not in ("T", "t"):
                    fail(f"worker token owner was not stopped before KILL: {pid}")
                signal.pidfd_send_signal(fd, signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError):
            pass
        finally:
            os.close(fd)
    for _ in range(40):
        if not enumerate_owners(token, minimum_start):
            return
        time.sleep(0.025)
    fail("live worker token owners remain after pidfd retirement")


if __name__ == "__main__":
    main()
