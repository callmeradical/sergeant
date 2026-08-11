#!/usr/bin/env python3
"""Bounded, durable Treehouse v2.1 I/O for Sergeant lease operations."""

import json
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import uuid

LIMIT = 65536
RECEIPT_RING = 4
RECEIPT_ATTEMPT_LIMIT = 12000
MAX_RECEIPT_ATTEMPTS = (1 << 63) - 1


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
    if not isinstance(receipt, dict) or receipt.get("version") != 1:
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
    total = receipt.get("total_attempts", len(attempts))
    digest = receipt.get("history_sha256", "0" * 64)
    if (not isinstance(total, int) or isinstance(total, bool) or total < len(attempts)
            or total > MAX_RECEIPT_ATTEMPTS):
        raise ValueError("invalid receipt attempt count")
    if (not isinstance(digest, str) or len(digest) != 64 or
            any(char not in "0123456789abcdef" for char in digest)):
        raise ValueError("invalid receipt history digest")
    return {"version": 1, "total_attempts": total,
            "history_sha256": digest, "attempts": attempts}


def rotate_return_evidence(attempts, newest_raw):
    newest = Path(newest_raw)
    base_name = newest.name.rsplit(".", 1)[0]
    keep = set()
    for attempt in attempts:
        raw = attempt.get("raw_path")
        if isinstance(raw, str):
            keep.update((raw, raw + ".stderr"))
    for candidate in newest.parent.glob(base_name + ".*"):
        if str(candidate) not in keep and candidate.is_file() and not candidate.is_symlink():
            candidate.unlink()


def append_receipt(path, attempt):
    target = Path(path)
    encoded_attempt = json.dumps(attempt, sort_keys=True,
                                 separators=(",", ":")).encode()
    if len(encoded_attempt) > RECEIPT_ATTEMPT_LIMIT:
        raise SystemExit("Treehouse receipt identity is too large")
    receipt = {"version": 1, "total_attempts": 0,
               "history_sha256": "0" * 64, "attempts": []}
    if target.exists():
        try:
            receipt = load_receipt(target)
        except (ValueError, OSError, UnicodeDecodeError, json.JSONDecodeError):
            raise SystemExit("invalid preserved Treehouse receipt")
    attempts = receipt["attempts"] + [attempt]
    digest = receipt["history_sha256"]
    while len(attempts) > RECEIPT_RING:
        evicted = attempts.pop(0)
        canonical_attempt = json.dumps(
            evicted, sort_keys=True, separators=(",", ":")).encode()
        digest = hashlib.sha256(bytes.fromhex(digest) + canonical_attempt).hexdigest()
    total = min(receipt["total_attempts"] + 1, MAX_RECEIPT_ATTEMPTS)
    updated = {"version": 1, "total_attempts": total,
               "history_sha256": digest, "attempts": attempts}
    atomic_json(target, updated)
    if attempt.get("operation") == "return":
        rotate_return_evidence(attempts, attempt["raw_path"])


def finish_receipt(path, attempt_id, returncode, stdout_overflow, stderr_overflow):
    receipt = load_receipt(path)
    attempts = receipt["attempts"]
    if not attempts or attempts[-1].get("attempt_id") != attempt_id:
        raise SystemExit("Treehouse receipt attempt changed")
    attempts[-1]["state"] = "completed"
    attempts[-1]["returncode"] = returncode if returncode >= 0 else None
    attempts[-1]["signal"] = -returncode if returncode < 0 else None
    attempts[-1]["stdout_overflow"] = stdout_overflow
    attempts[-1]["stderr_overflow"] = stderr_overflow
    atomic_json(path, receipt)


def run_bounded(command, cwd, raw_path, receipt_path, identity, failpoint=None):
    attempt_id = uuid.uuid4().hex
    if identity.get("operation") == "return":
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
                                   stderr=subprocess.PIPE)
        overflow = {"stdout": False, "stderr": False}
        def drain(source, destination, stream_name):
            captured = 0
            total = 0
            while chunk := source.read(65536):
                total += len(chunk)
                if captured <= LIMIT:
                    kept = chunk[:LIMIT + 1 - captured]
                    destination.write(kept)
                    captured += len(kept)
                if total > LIMIT:
                    overflow[stream_name] = True

        assert process.stdout is not None and process.stderr is not None
        stdout_thread = threading.Thread(
            target=drain, args=(process.stdout, output, "stdout"))
        stderr_thread = threading.Thread(
            target=drain, args=(process.stderr, error_output, "stderr"))
        stdout_thread.start()
        stderr_thread.start()
        returncode = process.wait()
        stdout_thread.join()
        stderr_thread.join()
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
                   overflow["stdout"], overflow["stderr"])
    return returncode, target, overflow["stdout"] or overflow["stderr"]


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


def same_repository(repo, checkout):
    repo = canonical(repo)
    checkout = canonical(checkout)
    repo_common = git_common(repo, repo)
    checkout_common = git_common(checkout, checkout)
    left = os.stat(repo_common, follow_symlinks=False)
    right = os.stat(checkout_common, follow_symlinks=False)
    if (left.st_dev, left.st_ino) != (right.st_dev, right.st_ino):
        raise ValueError("checkout belongs to another repository")


def checkout_branch(repo, checkout, branch):
    repo = canonical(repo)
    checkout = canonical(checkout)
    if controls(branch) or not branch or len(branch.encode()) > 1024:
        raise ValueError("invalid branch")
    descriptor = os.open(checkout, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        descriptor_path = f"/proc/self/fd/{descriptor}"
        repo_common = git_common(repo, repo)
        checkout_common = git_common(
            descriptor_path, checkout, pass_fds=(descriptor,))
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
    canonical_path = str(Path(path).resolve(strict=True))
    repo = canonical(repo)
    if actual_holder != holder:
        raise ValueError("allocation holder mismatch")
    atomic_json(record_path, {"version": 1, "repo": repo, "path": path,
                              "path_canonical": canonical_path,
                              "path_is_canonical": canonical_path == path,
                              "lease_id": lease_id, "lease_holder": actual_holder},
                "treehouse-record-created")
    if os.environ.get("SGT_DISPATCH_FAIL_POINT") == "treehouse-record-published":
        raise SystemExit(90)
    return path, lease_id


def main():
    mode = sys.argv[1]
    if mode == "get":
        repo, raw, receipt, record, holder = sys.argv[2:]
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
        repo, checkout, branch = sys.argv[2:]
        try:
            return checkout_branch(repo, checkout, branch)
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
