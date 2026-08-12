#!/usr/bin/env python3
"""Regression coverage for receipt publication and evidence eviction."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "sgt_treehouse_io", Path(os.environ.get(
        "SGT_TREEHOUSE_IO_UNDER_TEST",
        ROOT / "bin" / "_sgt-treehouse-io.py")))
TREEHOUSE_IO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TREEHOUSE_IO)


def completed_attempt(raw_prefix, attempt_id):
    return {
        "attempt_id": attempt_id,
        "state": "completed",
        "raw_path": f"{raw_prefix}.{attempt_id}",
        "operation": "return",
        "repo": "/repo",
        "path": "/checkout",
        "lease_id": "lease",
        "lease_holder": "holder",
        "returncode": 1,
        "signal": None,
        "stdout_overflow": False,
        "stderr_overflow": False,
        "timed_out": False,
        "pipe_timeout": False,
    }


def inode_is_bound(info):
    """Observe descriptors through the process's public descriptor directory."""
    for entry in Path("/dev/fd").iterdir():
        try:
            descriptor_info = os.fstat(int(entry.name))
        except (OSError, ValueError):
            continue
        if ((descriptor_info.st_dev, descriptor_info.st_ino) ==
                (info.st_dev, info.st_ino)):
            return True
    return False


def receipt_eviction_keeps_identity_bound_across_publication():
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory)
        raw_prefix = str(state / "treehouse-return.raw")
        receipt_path = state / "treehouse-return-receipt.json"
        attempts = [completed_attempt(raw_prefix, f"{index:032x}")
                    for index in range(1, 5)]
        receipt = {
            "version": 1,
            "total_attempts": 4,
            "count_saturated": False,
            "history_sha256": "0" * 64,
            "identity": TREEHOUSE_IO.attempt_identity(attempts[0]),
            "attempts": attempts,
        }
        receipt_path.write_text(
            json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8")
        oldest = Path(attempts[0]["raw_path"])
        oldest.write_text("original evidence\n", encoding="utf-8")
        oldest_stderr = Path(str(oldest) + ".stderr")
        oldest_stderr.write_text("original stderr evidence\n", encoding="utf-8")
        original_info = oldest.stat()
        original_stderr_info = oldest_stderr.stat()

        real_atomic_json = TREEHOUSE_IO.atomic_json

        def replace_after_publication(path, value, failpoint=None):
            real_atomic_json(path, value, failpoint)
            if (not inode_is_bound(original_info) or
                    not inode_is_bound(original_stderr_info)):
                raise AssertionError(
                    "an eviction identity was released before receipt publication")
            oldest.unlink()
            oldest.write_text("replacement evidence\n", encoding="utf-8")

        TREEHOUSE_IO.atomic_json = replace_after_publication
        next_attempt = completed_attempt(raw_prefix, f"{5:032x}")
        next_attempt["state"] = "started"
        for key in ("returncode", "signal", "stdout_overflow", "stderr_overflow",
                    "timed_out", "pipe_timeout"):
            del next_attempt[key]
        try:
            try:
                TREEHOUSE_IO.append_receipt(receipt_path, next_attempt, raw_prefix)
            except SystemExit as error:
                assert "changed before deletion" in str(error)
            else:
                raise AssertionError("replacement evidence was accepted for deletion")
        finally:
            TREEHOUSE_IO.atomic_json = real_atomic_json
        assert oldest.read_text(encoding="utf-8") == "replacement evidence\n"
        assert oldest_stderr.read_text(
            encoding="utf-8") == "original stderr evidence\n"
        assert not inode_is_bound(original_info)
        assert not inode_is_bound(original_stderr_info)


def receipt_eviction_quarantines_before_deleting_by_name():
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory)
        raw_prefix = str(state / "treehouse-return.raw")
        receipt_path = state / "treehouse-return-receipt.json"
        attempts = [completed_attempt(raw_prefix, f"{index:032x}")
                    for index in range(1, 5)]
        receipt_path.write_text(json.dumps({
            "version": 1,
            "total_attempts": 4,
            "count_saturated": False,
            "history_sha256": "0" * 64,
            "identity": TREEHOUSE_IO.attempt_identity(attempts[0]),
            "attempts": attempts,
        }, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        oldest = Path(attempts[0]["raw_path"])
        oldest.write_text("original evidence\n", encoding="utf-8")

        real_rename = Path.rename

        def replace_at_delete_boundary(path, target):
            result = real_rename(path, target)
            if path == oldest:
                oldest.write_text("replacement evidence\n", encoding="utf-8")
            return result

        Path.rename = replace_at_delete_boundary
        next_attempt = completed_attempt(raw_prefix, f"{5:032x}")
        next_attempt["state"] = "started"
        for key in ("returncode", "signal", "stdout_overflow", "stderr_overflow",
                    "timed_out", "pipe_timeout"):
            del next_attempt[key]
        try:
            TREEHOUSE_IO.append_receipt(receipt_path, next_attempt, raw_prefix)
        finally:
            Path.rename = real_rename
        assert oldest.read_text(encoding="utf-8") == "replacement evidence\n"


def concurrent_receipt_eviction_refuses_the_rotation():
    with tempfile.TemporaryDirectory() as directory:
        raw_prefix = str(Path(directory) / "treehouse-return.raw")
        descriptor = TREEHOUSE_IO.acquire_evidence_rotation_lock(raw_prefix)
        try:
            try:
                TREEHOUSE_IO.acquire_evidence_rotation_lock(raw_prefix)
            except SystemExit as error:
                assert str(error) == "Treehouse evidence rotation is already active"
            else:
                raise AssertionError("concurrent evidence rotation was not refused")
        finally:
            os.close(descriptor)
        quarantine = Path(directory) / ".treehouse-evidence-quarantine"
        quarantine.mkdir()
        try:
            TREEHOUSE_IO.acquire_evidence_rotation_lock(raw_prefix)
        except SystemExit as error:
            assert str(error).startswith(
                "preserved Treehouse evidence quarantine requires inspection:")
        else:
            raise AssertionError("preserved evidence quarantine was ignored")


if __name__ == "__main__":
    receipt_eviction_keeps_identity_bound_across_publication()
    receipt_eviction_quarantines_before_deleting_by_name()
    concurrent_receipt_eviction_refuses_the_rotation()
    print("Treehouse eviction binds evidence across receipt publication: ok")
