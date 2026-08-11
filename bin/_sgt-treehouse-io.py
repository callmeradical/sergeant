#!/usr/bin/env python3
"""Bounded, durable Treehouse v2.1 I/O for Sergeant lease operations."""

import json
import hashlib
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time
import uuid

LIMIT = 65536
RECEIPT_RING = 4
RECEIPT_ATTEMPT_LIMIT = 12000
MAX_RECEIPT_ATTEMPTS = (1 << 63) - 1
PIPE_DRAIN_TIMEOUT = 1.0
COMMAND_TIMEOUT = 300.0
ENVELOPE_KEYS = {"version", "total_attempts", "count_saturated",
                 "history_sha256", "identity", "attempts"}
EVIDENCE_SCAN_LIMIT = 1024
EVIDENCE_SCAN_SECONDS = 5.0


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cleanup_orphan_temps(targets, return_raw_prefix=None):
    patterns = []
    parents = set()
    for value in targets:
        target = Path(value)
        parent = target.parent.resolve(strict=True)
        if parent != target.parent or parent.is_symlink():
            raise SystemExit("unsafe Treehouse evidence directory")
        parents.add(parent)
        patterns.append(re.compile(re.escape(target.name) + r"\.tmp\.(\d+)$"))
    if return_raw_prefix:
        prefix = Path(return_raw_prefix)
        parent = prefix.parent.resolve(strict=True)
        if parent != prefix.parent or parent.is_symlink():
            raise SystemExit("unsafe Treehouse evidence directory")
        parents.add(parent)
        patterns.append(re.compile(
            re.escape(prefix.name) +
            r"\.[0-9a-f]{32}(?:\.stderr)?\.tmp\.(\d+)$"))
    for parent in parents:
        started = time.monotonic()
        candidates = []
        for entry_count, candidate in enumerate(parent.iterdir(), start=1):
            if (entry_count > EVIDENCE_SCAN_LIMIT or
                    time.monotonic() - started > EVIDENCE_SCAN_SECONDS):
                raise SystemExit("Treehouse evidence directory scan limit exceeded")
            candidates.append(candidate)
        for candidate in candidates:
            matched = None
            for pattern in patterns:
                matched = pattern.fullmatch(candidate.name)
                if matched is not None:
                    break
            if not matched:
                continue
            info = candidate.lstat()
            if (candidate.is_symlink() or not candidate.is_file() or
                    info.st_uid != os.getuid() or info.st_nlink != 1):
                raise SystemExit("unsafe orphan Treehouse evidence")
            pid = int(matched.group(1))
            if pid == os.getpid() or not process_alive(pid):
                candidate.unlink()


def atomic_json(path, value, failpoint=None):
    target = Path(path)
    temp = target.with_name(f"{target.name}.tmp.{os.getpid()}")
    with temp.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    if failpoint and os.environ.get("SGT_DISPATCH_FAIL_POINT") == failpoint:
        raise SystemExit(90)
    os.replace(temp, target)
    directory = os.open(target.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def load_receipt(path):
    receipt = strict_json(Path(path).read_bytes())
    if (not isinstance(receipt, dict) or set(receipt) != ENVELOPE_KEYS or
            receipt.get("version") != 1 or isinstance(receipt.get("version"), bool)):
        raise ValueError("invalid receipt envelope")
    attempts = receipt.get("attempts")
    if not isinstance(attempts, list) or len(attempts) > RECEIPT_RING:
        raise ValueError("invalid receipt attempt ring")
    for attempt in attempts:
        if not isinstance(attempt, dict):
            raise ValueError("invalid receipt attempt")
        encoded = json.dumps(attempt, sort_keys=True, separators=(",", ":")).encode()
        if len(encoded) > RECEIPT_ATTEMPT_LIMIT:
            raise ValueError("oversized receipt attempt")
        validate_attempt(attempt)
    identity = receipt.get("identity")
    validate_receipt_identity(identity)
    if any(attempt_identity(attempt) != identity for attempt in attempts):
        raise ValueError("mixed Treehouse receipt attempt identity")
    total = receipt.get("total_attempts", len(attempts))
    digest = receipt.get("history_sha256", "0" * 64)
    saturated = receipt.get("count_saturated")
    if (not isinstance(total, int) or isinstance(total, bool) or total < len(attempts)
            or total > MAX_RECEIPT_ATTEMPTS):
        raise ValueError("invalid receipt attempt count")
    if (not isinstance(saturated, bool) or
            (saturated and total != MAX_RECEIPT_ATTEMPTS)):
        raise ValueError("invalid receipt saturation state")
    if (not isinstance(digest, str) or len(digest) != 64 or
            any(char not in "0123456789abcdef" for char in digest)):
        raise ValueError("invalid receipt history digest")
    return {"version": 1, "total_attempts": total,
            "count_saturated": saturated, "history_sha256": digest,
            "identity": identity, "attempts": attempts}


def attempt_identity(attempt):
    keys = {
        "get": ("operation", "repo", "lease_holder"),
        "status": ("operation", "repo"),
        "return": ("operation", "repo", "path", "lease_id", "lease_holder"),
    }[attempt["operation"]]
    return {key: attempt[key] for key in keys}


def validate_receipt_identity(identity):
    if not isinstance(identity, dict) or identity.get("operation") not in {
            "get", "status", "return"}:
        raise ValueError("invalid receipt identity")
    operation = identity["operation"]
    expected = {
        "get": {"operation", "repo", "lease_holder"},
        "status": {"operation", "repo"},
        "return": {"operation", "repo", "path", "lease_id", "lease_holder"},
    }[operation]
    if set(identity) != expected:
        raise ValueError("invalid receipt identity schema")
    for value in identity.values():
        if not isinstance(value, str) or not value or len(value.encode()) > 4096:
            raise ValueError("invalid receipt identity value")


def validate_attempt(attempt):
    operation = attempt.get("operation")
    state = attempt.get("state")
    identity_keys = {
        "get": {"repo", "lease_holder"},
        "status": {"repo"},
        "return": {"repo", "path", "lease_id", "lease_holder"},
    }
    if operation not in identity_keys or state not in ("started", "completed"):
        raise ValueError("invalid receipt operation or state")
    keys = {"attempt_id", "state", "raw_path", "operation"} | identity_keys[operation]
    if state == "completed":
        keys |= {"returncode", "signal", "stdout_overflow", "stderr_overflow",
                 "timed_out", "pipe_timeout"}
    if set(attempt) != keys:
        raise ValueError("invalid receipt attempt schema")
    attempt_id = attempt["attempt_id"]
    if (not isinstance(attempt_id, str) or
            not re.fullmatch(r"[0-9a-f]{32}", attempt_id)):
        raise ValueError("invalid receipt attempt id")
    for key in identity_keys[operation] | {"raw_path"}:
        value = attempt[key]
        if not isinstance(value, str) or not value or len(value.encode()) > 4096:
            raise ValueError("invalid receipt identity")
    raw_path = attempt["raw_path"]
    if not os.path.isabs(raw_path) or os.path.normpath(raw_path) != raw_path:
        raise ValueError("invalid receipt raw path")
    if state == "completed":
        returncode = attempt["returncode"]
        caught_signal = attempt["signal"]
        if returncode is not None and (isinstance(returncode, bool) or
                                       not isinstance(returncode, int) or returncode < 0):
            raise ValueError("invalid receipt return code")
        if caught_signal is not None and (isinstance(caught_signal, bool) or
                                          not isinstance(caught_signal, int) or caught_signal <= 0):
            raise ValueError("invalid receipt signal")
        if (returncode is None) == (caught_signal is None):
            raise ValueError("receipt must contain exactly one outcome")
        for key in ("stdout_overflow", "stderr_overflow", "timed_out", "pipe_timeout"):
            if not isinstance(attempt[key], bool):
                raise ValueError("invalid receipt outcome flag")


def remove_completed_return_evidence(evicted, newest_raw):
    newest = Path(newest_raw)
    prefix = newest.name.rsplit(".", 1)[0]
    candidates = []
    for attempt in evicted:
        if attempt.get("operation") != "return" or attempt.get("state") != "completed":
            continue
        raw = Path(attempt["raw_path"])
        if (raw.parent != newest.parent or
                not re.fullmatch(re.escape(prefix) + r"\.[0-9a-f]{32}", raw.name)):
            raise SystemExit("unsafe completed Treehouse evidence path")
        candidates.extend((raw, Path(str(raw) + ".stderr")))
    metadata = []
    for candidate in candidates:
        if not candidate.exists() and not candidate.is_symlink():
            continue
        info = candidate.lstat()
        if (candidate.is_symlink() or not candidate.is_file() or
                info.st_uid != os.getuid() or info.st_nlink != 1):
            raise SystemExit("unsafe completed Treehouse evidence file")
        metadata.append(candidate)
    for candidate in metadata:
        candidate.unlink()


def append_receipt(path, attempt):
    target = Path(path)
    try:
        validate_attempt(attempt)
    except ValueError as error:
        raise SystemExit(f"invalid Treehouse receipt identity: {error}") from error
    encoded_attempt = json.dumps(attempt, sort_keys=True,
                                 separators=(",", ":")).encode()
    if len(encoded_attempt) > RECEIPT_ATTEMPT_LIMIT:
        raise SystemExit("Treehouse receipt identity is too large")
    receipt = {"version": 1, "total_attempts": 0,
               "count_saturated": False, "history_sha256": "0" * 64,
               "identity": attempt_identity(attempt), "attempts": []}
    if target.exists():
        try:
            receipt = load_receipt(target)
        except (ValueError, OSError, UnicodeDecodeError, json.JSONDecodeError):
            raise SystemExit("invalid preserved Treehouse receipt")
    if attempt_identity(attempt) != receipt["identity"]:
        raise SystemExit("Treehouse receipt identity changed")
    attempts = receipt["attempts"] + [attempt]
    evicted = []
    digest = receipt["history_sha256"]
    while len(attempts) > RECEIPT_RING:
        evicted_attempt = attempts.pop(0)
        evicted.append(evicted_attempt)
        canonical_attempt = json.dumps(
            evicted_attempt, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(bytes.fromhex(digest) + canonical_attempt).hexdigest()
    saturated = receipt["count_saturated"]
    if saturated or receipt["total_attempts"] == MAX_RECEIPT_ATTEMPTS:
        total = MAX_RECEIPT_ATTEMPTS
        saturated = True
    else:
        total = receipt["total_attempts"] + 1
    updated = {"version": 1, "total_attempts": total,
               "count_saturated": saturated, "history_sha256": digest,
               "identity": receipt["identity"], "attempts": attempts}
    atomic_json(target, updated)
    if attempt.get("operation") == "return":
        remove_completed_return_evidence(evicted, attempt["raw_path"])


def finish_receipt(path, attempt_id, returncode, stdout_overflow, stderr_overflow,
                   timed_out, pipe_timeout):
    receipt = load_receipt(path)
    attempts = receipt["attempts"]
    if not attempts or attempts[-1].get("attempt_id") != attempt_id:
        raise SystemExit("Treehouse receipt attempt changed")
    attempts[-1]["state"] = "completed"
    attempts[-1]["returncode"] = returncode if returncode >= 0 else None
    attempts[-1]["signal"] = -returncode if returncode < 0 else None
    attempts[-1]["stdout_overflow"] = stdout_overflow
    attempts[-1]["stderr_overflow"] = stderr_overflow
    attempts[-1]["timed_out"] = timed_out
    attempts[-1]["pipe_timeout"] = pipe_timeout
    atomic_json(path, receipt)


def run_bounded(command, cwd, raw_path, receipt_path, identity, failpoint=None):
    is_return = identity.get("operation") == "return"
    cleanup_orphan_temps(
        [receipt_path, raw_path, raw_path + ".stderr"],
        return_raw_prefix=raw_path if is_return else None)
    attempt_id = uuid.uuid4().hex
    if is_return:
        target = Path(f"{raw_path}.{attempt_id}")
    else:
        target = Path(raw_path)
    attempt = {"attempt_id": attempt_id, "state": "started",
               "raw_path": str(target), **identity}
    append_receipt(receipt_path, attempt)
    temp = target.with_name(f"{target.name}.tmp.{os.getpid()}")
    error_target = target.with_name(f"{target.name}.stderr")
    error_temp = error_target.with_name(f"{error_target.name}.tmp.{os.getpid()}")
    with temp.open("xb") as output, error_temp.open("xb") as error_output:
        process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        leader_pidfd = os.pidfd_open(process.pid)
        overflow = {"stdout": False, "stderr": False}
        assert process.stdout is not None and process.stderr is not None
        streams = selectors.DefaultSelector()
        captured = {"stdout": 0, "stderr": 0}
        total = {"stdout": 0, "stderr": 0}
        for source, destination, name in (
                (process.stdout, output, "stdout"),
                (process.stderr, error_output, "stderr")):
            os.set_blocking(source.fileno(), False)
            streams.register(source, selectors.EVENT_READ, (destination, name))
        timed_out = False
        command_deadline = time.monotonic() + COMMAND_TIMEOUT
        drain_deadline = None
        while streams.get_map() or process.poll() is None:
            now = time.monotonic()
            if process.poll() is None and now >= command_deadline:
                timed_out = True
                try:
                    signal.pidfd_send_signal(leader_pidfd, signal.SIGKILL)
                except OSError:
                    pass
                command_deadline = float("inf")
            if process.poll() is not None and drain_deadline is None:
                drain_deadline = now + PIPE_DRAIN_TIMEOUT
            if drain_deadline is not None and now >= drain_deadline:
                break
            wait_for = 0.1
            if drain_deadline is not None:
                wait_for = max(0.0, min(wait_for, drain_deadline - now))
            for key, _ in streams.select(wait_for):
                destination, name = key.data
                try:
                    chunk = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    streams.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                total[name] += len(chunk)
                remaining = LIMIT + 1 - captured[name]
                if remaining > 0:
                    kept = chunk[:remaining]
                    destination.write(kept)
                    captured[name] += len(kept)
                if total[name] > LIMIT:
                    overflow[name] = True
        pipe_timeout = bool(streams.get_map())
        for key in list(streams.get_map().values()):
            streams.unregister(key.fileobj)
            key.fileobj.close()
        streams.close()
        returncode = process.wait()
        os.close(leader_pidfd)
        output.flush()
        os.fsync(output.fileno())
        error_output.flush()
        os.fsync(error_output.fileno())
    if (identity.get("operation") == "get" and
            os.environ.get("SGT_DISPATCH_FAIL_POINT") == "treehouse-raw-created"):
        raise SystemExit(90)
    os.replace(temp, target)
    os.replace(error_temp, error_target)
    directory = os.open(target.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    if (identity.get("operation") == "get" and
            os.environ.get("SGT_DISPATCH_FAIL_POINT") == "treehouse-raw-published"):
        raise SystemExit(90)
    if failpoint and os.environ.get("SGT_CLEANUP_FAIL_POINT") == failpoint:
        os.kill(os.getpid(), signal.SIGKILL)
    finish_receipt(receipt_path, attempt_id, returncode,
                   overflow["stdout"], overflow["stderr"], timed_out, pipe_timeout)
    ambiguous = (overflow["stdout"] or overflow["stderr"] or
                 timed_out or pipe_timeout)
    return returncode, target, ambiguous


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def controls(value):
    if isinstance(value, str):
        return any(ord(char) < 32 or ord(char) == 127 for char in value)
    if isinstance(value, dict):
        return any(controls(key) or controls(item) for key, item in value.items())
    if isinstance(value, list):
        return any(controls(item) for item in value)
    return False


def strict_json(raw):
    if not raw or len(raw) > LIMIT:
        raise ValueError("empty or oversized JSON")
    def reject_constant(value):
        raise ValueError(f"non-JSON constant: {value}")

    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                       parse_constant=reject_constant)
    if controls(value):
        raise ValueError("control character in JSON string")
    return value


def canonical(path):
    candidate = Path(path)
    if not candidate.is_absolute():
        raise ValueError("path is not absolute")
    resolved = str(candidate.resolve(strict=True))
    if resolved != path:
        raise ValueError("path is not canonical")
    return resolved


def git_common(path, expected_top=None, pass_fds=()):
    top = subprocess.run(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        pass_fds=pass_fds).stdout.rstrip("\n")
    if controls(top) or (expected_top is not None and top != expected_top):
        raise ValueError("unexpected git top-level")
    common = subprocess.run(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        pass_fds=pass_fds).stdout.rstrip("\n")
    return canonical(common)


def git_directory(path, pass_fds=()):
    directory = subprocess.run(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        pass_fds=pass_fds).stdout.rstrip("\n")
    return canonical(directory)


def same_repository(repo, checkout):
    repo = canonical(repo)
    checkout = canonical(checkout)
    repo_common = git_common(repo, repo)
    checkout_common = git_common(checkout, checkout)
    left = os.stat(repo_common, follow_symlinks=False)
    right = os.stat(checkout_common, follow_symlinks=False)
    if (left.st_dev, left.st_ino) != (right.st_dev, right.st_ino):
        raise ValueError("checkout belongs to another repository")


def checkout_branch(repo, checkout, branch, record_path):
    repo = canonical(repo)
    if not os.path.isabs(checkout) or os.path.normpath(checkout) != checkout:
        raise ValueError("invalid checkout path")
    if controls(branch) or not branch or len(branch.encode()) > 1024:
        raise ValueError("invalid branch")
    descriptor = os.open(checkout, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        descriptor_path = f"/proc/self/fd/{descriptor}"
        if os.path.realpath(descriptor_path) != checkout:
            raise ValueError("checkout path changed before open")
        record = strict_json(Path(record_path).read_bytes())
        required = {"version", "repo", "path", "path_canonical",
                    "path_is_canonical", "lease_id", "lease_holder",
                    "checkout_dev", "checkout_ino", "git_dir",
                    "git_dir_dev", "git_dir_ino", "identity_verified"}
        if (not isinstance(record, dict) or set(record) != required or
                record.get("version") != 1 or record.get("repo") != repo or
                record.get("path") != checkout or
                record.get("path_canonical") != checkout or
                record.get("path_is_canonical") is not True or
                record.get("identity_verified") is not True or
                record.get("checkout_dev") != opened.st_dev or
                record.get("checkout_ino") != opened.st_ino):
            raise ValueError("checkout allocation identity changed")
        repo_common = git_common(repo, repo)
        checkout_common = git_common(
            descriptor_path, checkout, pass_fds=(descriptor,))
        checkout_git_dir = git_directory(descriptor_path, pass_fds=(descriptor,))
        git_info = os.stat(checkout_git_dir, follow_symlinks=False)
        if (record.get("git_dir") != checkout_git_dir or
                record.get("git_dir_dev") != git_info.st_dev or
                record.get("git_dir_ino") != git_info.st_ino):
            raise ValueError("checkout Git directory changed")
        left = os.stat(repo_common, follow_symlinks=False)
        right = os.stat(checkout_common, follow_symlinks=False)
        if (left.st_dev, left.st_ino) != (right.st_dev, right.st_ino):
            raise ValueError("checkout belongs to another repository")
        exists = subprocess.run(
            ["git", "-C", descriptor_path, "show-ref", "--verify", "--quiet",
             f"refs/heads/{branch}"], pass_fds=(descriptor,)).returncode == 0
        command = ["git", "-C", descriptor_path, "checkout"]
        command.extend([branch] if exists else ["-b", branch])
        result = subprocess.run(command, pass_fds=(descriptor,))
        try:
            post_common = git_common(
                descriptor_path, checkout, pass_fds=(descriptor,))
            post_git_dir = git_directory(descriptor_path, pass_fds=(descriptor,))
            post_common_info = os.stat(post_common, follow_symlinks=False)
            post_git_info = os.stat(post_git_dir, follow_symlinks=False)
            if ((post_common_info.st_dev, post_common_info.st_ino) !=
                    (left.st_dev, left.st_ino) or
                    post_git_dir != record["git_dir"] or
                    (post_git_info.st_dev, post_git_info.st_ino) !=
                    (record["git_dir_dev"], record["git_dir_ino"])):
                raise ValueError("checkout Git identity changed during mutation")
            current = os.stat(checkout, follow_symlinks=False)
            same_object = ((opened.st_dev, opened.st_ino) ==
                           (current.st_dev, current.st_ino))
            same_repository(repo, checkout)
        except (ValueError, OSError, subprocess.CalledProcessError):
            return 1
        return 0 if result.returncode == 0 and same_object else 1
    finally:
        os.close(descriptor)


def allocation(raw_path, record_path, repo, holder):
    value = strict_json(Path(raw_path).read_bytes())
    if not isinstance(value, dict):
        raise ValueError("allocation is not an object")
    fields = [value.get(name) for name in ("path", "lease_id", "lease_holder")]
    if not all(isinstance(item, str) and item for item in fields):
        raise ValueError("allocation identity is incomplete")
    path, lease_id, actual_holder = fields
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise ValueError("allocation path is not absolute and normalized")
    repo = canonical(repo)
    if actual_holder != holder:
        raise ValueError("allocation holder mismatch")
    canonical_path = str(Path(path).resolve(strict=True))
    candidate = {"version": 1, "repo": repo, "path": path,
                 "path_canonical": canonical_path,
                 "path_is_canonical": canonical_path == path,
                 "identity_verified": False,
                 "checkout_dev": None, "checkout_ino": None,
                 "git_dir": None, "git_dir_dev": None, "git_dir_ino": None,
                 "lease_id": lease_id, "lease_holder": actual_holder}
    atomic_json(record_path, candidate)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        checkout_info = os.fstat(descriptor)
        descriptor_path = f"/proc/self/fd/{descriptor}"
        canonical_path = os.path.realpath(descriptor_path)
        checkout_common = git_common(
            descriptor_path, path, pass_fds=(descriptor,))
        repo_common = git_common(repo, repo)
        left = os.stat(repo_common, follow_symlinks=False)
        right = os.stat(checkout_common, follow_symlinks=False)
        if (left.st_dev, left.st_ino) != (right.st_dev, right.st_ino):
            raise ValueError("allocation belongs to another repository")
        checkout_git_dir = git_directory(descriptor_path, pass_fds=(descriptor,))
        git_info = os.stat(checkout_git_dir, follow_symlinks=False)
        current = os.stat(path, follow_symlinks=False)
        if ((checkout_info.st_dev, checkout_info.st_ino) !=
                (current.st_dev, current.st_ino)):
            raise ValueError("allocation path changed")
    finally:
        os.close(descriptor)
    atomic_json(record_path, {"version": 1, "repo": repo, "path": path,
                              "path_canonical": canonical_path,
                              "path_is_canonical": canonical_path == path,
                              "identity_verified": True,
                              "checkout_dev": checkout_info.st_dev,
                              "checkout_ino": checkout_info.st_ino,
                              "git_dir": checkout_git_dir,
                              "git_dir_dev": git_info.st_dev,
                              "git_dir_ino": git_info.st_ino,
                              "lease_id": lease_id, "lease_holder": actual_holder},
                "treehouse-record-created")
    if os.environ.get("SGT_DISPATCH_FAIL_POINT") == "treehouse-record-published":
        raise SystemExit(90)
    return path, lease_id


def main():
    mode = sys.argv[1]
    if mode == "get":
        repo, raw, receipt, record, holder = sys.argv[2:]
        cleanup_orphan_temps([record])
        rc, _, overflow = run_bounded(
            ["treehouse", "get", "--lease", "--lease-holder", holder, "--json"],
            repo, raw, receipt,
            {"operation": "get", "repo": repo, "lease_holder": holder})
        try:
            path, lease_id = allocation(raw, record, repo, holder)
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError,
                subprocess.CalledProcessError):
            return 12
        return 0 if rc == 0 and not overflow else 10
    if mode == "verify-checkout":
        repo, checkout = sys.argv[2:]
        try:
            same_repository(repo, checkout)
        except (ValueError, OSError, subprocess.CalledProcessError):
            return 1
        return 0
    if mode == "checkout-branch":
        repo, checkout, branch, record = sys.argv[2:]
        try:
            return checkout_branch(repo, checkout, branch, record)
        except (ValueError, OSError, subprocess.CalledProcessError):
            return 1
    if mode == "return":
        repo, raw, receipt, path, lease_id, holder = sys.argv[2:]
        # Treehouse v2.1 compares these conditions under its pool lock.  A
        # matching identity succeeds once; a missing lease or mismatch is
        # nonzero and status exposes no historical return receipt.  Keep our
        # started attempt durable so callers fail closed across that ambiguity.
        rc, attempt_raw, overflow = run_bounded(
            ["treehouse", "return", "--force", "--if-lease-id", lease_id,
             "--if-lease-holder", holder, path], repo, raw, receipt,
            {"operation": "return", "repo": repo, "path": path,
             "lease_id": lease_id, "lease_holder": holder},
            "treehouse-return-before-receipt")
        if rc == 0 and not overflow:
            sys.stdout.buffer.write(attempt_raw.read_bytes())
        return 0 if rc == 0 and not overflow else 1
    if mode == "status":
        repo, raw, receipt, state_path, path, lease_id, holder = sys.argv[2:]
        cleanup_orphan_temps([state_path])
        Path(state_path).unlink(missing_ok=True)
        rc, _, overflow = run_bounded(
            ["treehouse", "status", "--json"], repo, raw, receipt,
            {"operation": "status", "repo": repo})
        if rc != 0 or overflow:
            return 1
        try:
            data = strict_json(Path(raw).read_bytes())
            if not isinstance(data, list):
                raise ValueError("status is not an array")
            expected = canonical(path)
            matches = []
            for entry in data:
                if not isinstance(entry, dict):
                    raise ValueError("status entry is not an object")
                entry_path = entry.get("path")
                entry_id = entry.get("lease_id")
                entry_holder = entry.get("lease_holder")
                if not isinstance(entry_path, str) or not isinstance(entry_id, str) or not isinstance(entry_holder, str):
                    raise ValueError("status identity has wrong type")
                if (not os.path.isabs(entry_path) or
                        os.path.normpath(entry_path) != entry_path):
                    raise ValueError("status path is not canonical")
                if entry_path == expected:
                    matches.append(entry)
            if len(matches) > 1:
                raise ValueError("duplicate path in status")
            state = "different"
            if len(matches) == 1 and matches[0]["lease_id"] == lease_id and matches[0]["lease_holder"] == holder:
                same_repository(repo, path)
                state = "matched"
            atomic_json(state_path, {"state": state})
        except (ValueError, OSError, UnicodeDecodeError, json.JSONDecodeError,
                subprocess.CalledProcessError):
            return 1
        return 0
    raise SystemExit("unsupported Treehouse I/O mode")


if __name__ == "__main__":
    sys.exit(main())
