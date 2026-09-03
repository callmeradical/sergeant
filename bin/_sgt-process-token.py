#!/usr/bin/env python3
"""Retire Linux holders of inherited Sergeant worker marker FDs."""

import ctypes
import errno
import os
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

MARKER_RE = re.compile(r"^[0-9a-f]{32}\|([0-9]+):([0-9]+)\|([0-9]+)$")


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def force_pidfd_syscall():
    return (os.environ.get("SGT_TEST_HOOKS") == "1" and
            os.environ.get("SGT_TEST_FORCE_PIDFD_SYSCALL") == "1")


def pidfd_syscall_numbers():
    machine = platform.machine().lower()
    common_numbering = {
        "aarch64", "amd64", "arm64", "armv6l", "armv7l", "i386", "i686",
        "loongarch64", "ppc64", "ppc64le", "riscv64", "s390x", "x86_64",
    }
    if machine in common_numbering:
        return 434, 424
    return None


_LIBC_WITH_ERRNO = None

def libc_pidfd_function(name):
    if force_pidfd_syscall():
        return None
    global _LIBC_WITH_ERRNO
    if _LIBC_WITH_ERRNO is None:
        _LIBC_WITH_ERRNO = ctypes.CDLL(None, use_errno=True)
    return getattr(_LIBC_WITH_ERRNO, name, None)


_LIBC_NO_ERRNO = None

def pidfd_available():
    if (not force_pidfd_syscall() and hasattr(os, "pidfd_open") and
            hasattr(signal, "pidfd_send_signal")):
        return True
    if not sys.platform.startswith("linux"):
        return False
    global _LIBC_NO_ERRNO
    if _LIBC_NO_ERRNO is None:
        _LIBC_NO_ERRNO = ctypes.CDLL(None)
    if (not force_pidfd_syscall() and hasattr(_LIBC_NO_ERRNO, "pidfd_open") and
            hasattr(_LIBC_NO_ERRNO, "pidfd_send_signal")):
        return True
    return hasattr(_LIBC_NO_ERRNO, "syscall") and pidfd_syscall_numbers() is not None


def pidfd_open(pid):
    if not force_pidfd_syscall() and hasattr(os, "pidfd_open"):
        return os.pidfd_open(pid, 0)
    function = libc_pidfd_function("pidfd_open")
    if function is not None:
        function.argtypes = (ctypes.c_int, ctypes.c_uint)
        function.restype = ctypes.c_int
        descriptor = function(pid, 0)
    else:
        numbers = pidfd_syscall_numbers()
        if numbers is None:
            raise NotImplementedError
        # ⚡ Bolt: Cache CDLL instance instead of reloading it every time for
        # significant performance gains during thousands of process iterations
        global _LIBC_WITH_ERRNO
        if _LIBC_WITH_ERRNO is None:
            _LIBC_WITH_ERRNO = ctypes.CDLL(None, use_errno=True)
        syscall = _LIBC_WITH_ERRNO.syscall
        syscall.restype = ctypes.c_long
        descriptor = syscall(numbers[0], pid, 0)
    if descriptor < 0:
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            raise ProcessLookupError(error, os.strerror(error))
        raise OSError(error, os.strerror(error))
    return descriptor


def pidfd_send_signal(descriptor, signum):
    if not force_pidfd_syscall() and hasattr(signal, "pidfd_send_signal"):
        signal.pidfd_send_signal(descriptor, signum)
        return
    function = libc_pidfd_function("pidfd_send_signal")
    if function is not None:
        function.argtypes = (
            ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(descriptor, signum, None, 0)
    else:
        numbers = pidfd_syscall_numbers()
        if numbers is None:
            raise NotImplementedError
        # ⚡ Bolt: Cache CDLL instance instead of reloading it every time for
        # significant performance gains during thousands of process iterations
        global _LIBC_WITH_ERRNO
        if _LIBC_WITH_ERRNO is None:
            _LIBC_WITH_ERRNO = ctypes.CDLL(None, use_errno=True)
        syscall = _LIBC_WITH_ERRNO.syscall
        syscall.restype = ctypes.c_long
        result = syscall(numbers[1], descriptor, signum, None, 0)
    if result < 0:
        error = ctypes.get_errno()
        if error == errno.ESRCH:
            raise ProcessLookupError(error, os.strerror(error))
        raise OSError(error, os.strerror(error))


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
    except (FileNotFoundError, ProcessLookupError):
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
        except (FileNotFoundError, ProcessLookupError):
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
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            fail(f"cannot inspect same-UID post-launch PID {pid} fd ownership")
        except OSError as exc:
            fail(f"cannot inspect worker marker holder PID {pid}: {exc}")
    return owners


def enumerate_portable_holders(markers, target_pid=None, descriptor_details=False):
    """Return lsof-proven marker holders without inventing process identity."""
    command = [
        "lsof", "-w", "-nP", "-a", "-u", str(os.geteuid()),
        "-d", "0-2147483647", "-F", "pDfin",
    ]
    if target_pid is not None:
        command[4:4] = ["-p", str(target_pid)]
    try:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
    except FileNotFoundError as exc:
        fail(f"cannot inspect portable worker marker holders with lsof: {exc}")

    streams = selectors.DefaultSelector()
    streams.register(process.stdout, selectors.EVENT_READ, "stdout")
    streams.register(process.stderr, selectors.EVENT_READ, "stderr")
    output = {"stdout": bytearray(), "stderr": bytearray()}
    deadline = time.monotonic() + 10
    # A fixed 1 MiB limit is exceeded by ordinary, correctly-functioning
    # developer machines: this scans every open descriptor of every process
    # the invoking user owns (not just the marker-holding candidates), so its
    # size scales with total host fd-table volume, which is unrelated to how
    # many workers Sergeant itself has running. Overridable for hosts that
    # still need more headroom without a code change; still bounded, per the
    # requirement that this remain a real, finite limit, not removed.
    limit = int(os.environ.get("SERGEANT_PORTABLE_MARKER_LSOF_LIMIT", 16 * 1024 * 1024))
    try:
        while streams.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.wait()
                fail("cannot inspect portable worker marker holders with lsof: timed out")
            ready = streams.select(remaining)
            if not ready:
                continue
            for key, _ in ready:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    streams.unregister(key.fileobj)
                    continue
                output[key.data].extend(chunk)
                if sum(map(len, output.values())) > limit:
                    process.kill()
                    process.wait()
                    fail("portable lsof marker evidence exceeds 1048576 bytes")
        returncode = process.wait()
    finally:
        streams.close()
    stdout = bytes(output["stdout"])
    stderr = bytes(output["stderr"])
    if stderr or returncode not in (0, 1):
        detail = stderr.decode("utf-8", "replace").strip()
        fail(
            "cannot inspect portable worker marker holders with lsof: "
            f"{detail or returncode}"
        )
    try:
        lines = stdout.decode("ascii", "strict").splitlines()
    except UnicodeDecodeError:
        fail("portable lsof marker evidence is not canonical ASCII")

    owners = {}
    pid = None
    descriptor = None
    device = None
    inode = None
    name = None

    def finish_descriptor():
        nonlocal descriptor, device, inode, name
        if descriptor is None:
            return
        if (pid is None or not descriptor.isdecimal() or
                device is None or inode is None):
            # An unrelated descriptor can close while lsof is collecting its
            # system-wide snapshot.  It contributes no ownership proof; the
            # required marker descriptor must appear in two complete scans.
            descriptor = device = inode = name = None
            return
        identity = (device, inode)
        if identity in markers:
            if descriptor_details:
                owners.setdefault(pid, {}).setdefault(identity, set()).add(
                    (int(descriptor), name)
                )
            else:
                owners.setdefault(pid, set()).add(identity)
        descriptor = device = inode = name = None

    for line in lines:
        if not line or line[0] not in "pfDin":
            fail("portable lsof marker evidence is malformed")
        key, value = line[0], line[1:]
        if key == "p":
            finish_descriptor()
            if not value.isascii() or not value.isdecimal() or int(value) <= 0:
                fail("portable lsof marker PID is malformed")
            pid = int(value)
        elif key == "f":
            finish_descriptor()
            descriptor = value.rstrip("rwu-")
        elif key == "D":
            if descriptor is None or device is not None:
                fail("portable lsof marker device is malformed")
            try:
                device = int(value, 0)
            except ValueError:
                fail("portable lsof marker device is malformed")
        elif key == "i":
            if descriptor is None or inode is not None or not value.isdecimal():
                fail("portable lsof marker inode is malformed")
            inode = int(value)
        elif key == "n":
            if descriptor is None or name is not None:
                fail("portable lsof marker name is malformed")
            # An empty name is real, valid lsof output for descriptor types
            # that have none to report (an anonymous pipe, a deleted file, a
            # socket with no bound path) -- not evidence of corrupt evidence.
            # Identity is proven by (device, inode) alone; name is cosmetic
            # detail only ever surfaced via descriptor_details, so an empty
            # string here is a harmless, valid value, not a reason to abort
            # marker verification entirely.
            name = value
    finish_descriptor()
    if returncode == 1 and lines:
        fail("portable lsof returned partial marker evidence")
    return owners


def portable_descriptor_is_exclusive(history, pid, generation, identity):
    """Bind an unlinked descriptor to its durable generation and sole holder."""
    markers = load_markers(history)
    if markers.get(identity) != (generation, 0):
        fail("portable marker claim is absent from durable worker history")
    target = enumerate_portable_holders(
        {identity: (generation, 0)}, pid, descriptor_details=True
    )
    descriptors = target.get(pid, {}).get(identity, set())
    if not any(descriptor == 198 for descriptor, _ in descriptors):
        fail("portable marker capability is not held on durable worker fd198")
    expected = {pid: {identity}}
    holders = enumerate_portable_holders({identity: (generation, 0)})
    confirmed = enumerate_portable_holders({identity: (generation, 0)})
    if holders != expected or confirmed != expected:
        fail("portable marker capability is absent, cloned, or unverifiable")


def load_expected(path):
    expected = {}
    for line in open(path, encoding="utf-8"):
        if not line.startswith("member="):
            continue
        fields = line[len("member=") :].strip().split("|")
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].startswith("linux:"):
            expected[int(fields[0])] = fields[1][len("linux:") :]
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
    if not pidfd_available():
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
                fd = pidfd_open(pid)
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
                pidfd_send_signal(fd, signal.SIGSTOP)
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
                pidfd_send_signal(fd, signal.SIGKILL)
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


def compact_portable(path, markers):
    holders = enumerate_portable_holders(markers) if markers else {}
    live = set().union(*holders.values()) if holders else set()
    if len(live) > 64:
        fail("too many live worker marker generations; retire workers before relaunch")
    temporary = f"{path}.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(temporary, flags, 0o600)
    try:
        for identity, (generation, floor) in markers.items():
            if identity in live:
                os.write(
                    fd,
                    f"{generation}|{identity[0]}:{identity[1]}|{floor}\n".encode("ascii"),
                )
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)


def main():
    if len(sys.argv) == 6 and sys.argv[1] == "portable-check":
        history, pid_text, generation, identity = sys.argv[2:]
        if (not pid_text.isdigit() or int(pid_text) <= 0 or
                not re.fullmatch(r"[0-9a-f]{32}", generation) or
                not re.fullmatch(r"[0-9]+:[0-9]+", identity)):
            fail("invalid portable worker marker check request")
        marker_identity = tuple(map(int, identity.split(":")))
        portable_descriptor_is_exclusive(
            history, int(pid_text), generation, marker_identity
        )
        return
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
    if len(sys.argv) == 3 and sys.argv[1] in (
        "holders", "compact", "portable-holders", "portable-compact"
    ):
        markers = load_markers(
            sys.argv[2], allow_empty=sys.argv[1] in ("compact", "portable-compact")
        )
        if sys.argv[1] == "holders":
            for pid, start in sorted(enumerate_holders(markers).items() if markers else []):
                print(f"{pid}|linux:{start}")
        elif sys.argv[1] == "compact":
            compact(sys.argv[2], markers)
        elif sys.argv[1] == "portable-holders":
            holders = enumerate_portable_holders(markers) if markers else {}
            for pid, identities in sorted(holders.items()):
                for device, inode in sorted(identities):
                    print(f"{pid}|portable:{device}:{inode}")
        else:
            compact_portable(sys.argv[2], markers)
        return
    if len(sys.argv) != 4 or sys.argv[1] != "retire":
        fail("invalid worker marker retirement request")
    markers = load_markers(sys.argv[2])
    retire(markers, load_expected(sys.argv[3]))


if __name__ == "__main__":
    main()
