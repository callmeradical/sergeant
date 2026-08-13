#!/usr/bin/env python3
"""Compute the review-router executable identity.

Shared by bin/sgt-review-findings so its own --require-executable-identity
comparison uses the exact same dev:ino:sha256:runtime_sha256 algorithm and
runtime dependency set that bin/sgt-dispatch's
_sgt_review_router_executable_identity and bin/sgt-review-router-launch's
snapshot_identity compute and persist. The runtime file list, order, and hash
composition here must stay byte-for-byte identical to those two (GH #204).
"""

import hashlib
import os
import stat
import sys

RUNTIME_FILES = (
    "sgt-review-findings",
    "_sgt-lib.sh",
    "_sgt-response-lock.sh",
    "_sgt-review-axes.sh",
    "_sgt-bash-version.sh",
    "_sgt-process-identity.sh",
    "_sgt-drain.sh",
    "_sgt-process.sh",
    "_sgt-response-lock-transition.py",
    "_sgt-process-token.py",
    "sgt-notify",
    "sgt-callback",
)


def compute_identity(router_path):
    directory = os.path.dirname(router_path)
    runtime = hashlib.sha256()
    router_info = None
    router_digest = None
    for name in RUNTIME_FILES:
        path = router_path if name == "sgt-review-findings" else os.path.join(directory, name)
        runtime.update(name.encode() + b"\0")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise OSError("runtime dependency is not a regular file")
            digest = hashlib.sha256()
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                digest.update(chunk)
            runtime.update(digest.digest())
            if name == "sgt-review-findings":
                router_info = info
                router_digest = digest.hexdigest()
        finally:
            os.close(fd)
    if router_info is None:
        raise OSError("review router is unavailable")
    return f"{router_info.st_dev}:{router_info.st_ino}:{router_digest}:{runtime.hexdigest()}"


def main():
    if len(sys.argv) != 2:
        print("usage: _sgt-review-router-identity.py <router-path>", file=sys.stderr)
        return 64
    try:
        print(compute_identity(sys.argv[1]))
    except OSError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
