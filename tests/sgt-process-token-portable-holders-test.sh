#!/usr/bin/env bash
# Regression tests for enumerate_portable_holders() in _sgt-process-token.py
# (Deloitte support #35/#36/#37/#39, all traced to this one function):
#
#   - #36/#37: a fixed 1 MiB cap on combined lsof stdout+stderr is exceeded
#     by an ordinary, correctly-functioning busy developer machine, since the
#     scan covers every descriptor of every process the invoking user owns,
#     not just the marker candidates -- unrelated to how many Sergeant
#     workers are actually running.
#   - #35/#39: an lsof descriptor whose name field is legitimately empty
#     (anonymous pipes, deleted files, unbound sockets) was treated as
#     malformed evidence and aborted the entire scan, even though name is
#     never used to prove identity (device+inode is).
#
# This exercises enumerate_portable_holders() directly through a fake `lsof`
# on PATH emitting controlled `-F pDfin` field output, so it needs no real
# marker-holding process and runs on any platform (unlike this file's
# sibling tests, which are Linux-/proc-only).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"

# The fake lsof reads its desired output from a file named by
# FAKE_LSOF_OUTPUT_FILE, so each scenario below just writes that file with
# real Python (no nested shell/Python escaping) before invoking it.
cat > "$fake_bin/lsof" <<'EOF'
#!/usr/bin/env python3
import os
import sys
with open(os.environ["FAKE_LSOF_OUTPUT_FILE"], "rb") as fh:
    sys.stdout.buffer.write(fh.read())
EOF
chmod +x "$fake_bin/lsof"

run_enumerate() {
  PATH="$fake_bin:$PATH" FAKE_LSOF_OUTPUT_FILE="$TEST_ROOT/lsof-output" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('token', '$ROOT/bin/_sgt-process-token.py')
token = importlib.util.module_from_spec(spec)
spec.loader.exec_module(token)
markers = {(1, 42): (0, 0)}
try:
    holders = token.enumerate_portable_holders(markers)
    print('OK', holders)
except SystemExit as exc:
    print('FAIL', exc.code)
"
}

# --- #35/#39: an empty name field on an unrelated descriptor must not abort
# the whole scan; the real marker match (device=1, inode=42) must still be found.
printf 'p123\nf5\nD0x1\ni99\nn\nf6\nD1\ni42\nn/some/path\n' > "$TEST_ROOT/lsof-output"
output="$(run_enumerate)"
[[ "$output" == *'FAIL'* ]] && {
  printf 'FAIL: an empty lsof name field aborted the scan (want: benign, skip that descriptor): %s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"(1, 42)"* ]] || {
  printf 'FAIL: expected the real marker (device=1, inode=42) to still be matched: %s\n' "$output" >&2
  exit 1
}
printf 'enumerate_portable_holders tolerates an empty lsof name field: ok\n'

# --- #35/#39 mutation check: a genuinely out-of-sequence "n" line (no
# preceding "f" descriptor at all) must still be rejected as malformed --
# this proves the fix narrowed the check, not removed it.
printf 'p123\nn/some/path\n' > "$TEST_ROOT/lsof-output"
output="$(run_enumerate)"
[[ "$output" == *'FAIL'* ]] || {
  printf 'FAIL: an "n" line with no preceding descriptor should still be rejected as malformed, got: %s\n' "$output" >&2
  exit 1
}
printf 'enumerate_portable_holders still rejects a truly out-of-sequence name line: ok\n'

# --- #36/#37: lsof output well over the *old* 1 MiB fixed limit (but under
# the raised default) must no longer fail.
python3 -c "
with open('$TEST_ROOT/lsof-output', 'w') as fh:
    fh.write('p123\nf5\nD1\ni42\nn' + ('/x' * 600000) + '\n')
"
output="$(run_enumerate)"
[[ "$output" == *'FAIL'* ]] && {
  printf 'FAIL: ~1.2 MiB of legitimate lsof output was rejected under the raised default limit: %s\n' "$output" >&2
  exit 1
}
printf 'enumerate_portable_holders raised its default byte limit: ok\n'

# The limit is still real and still enforced, just larger, and is
# env-overridable downward to prove it is still an enforced bound, not
# removed entirely.
output="$(SERGEANT_PORTABLE_MARKER_LSOF_LIMIT=1024 run_enumerate)"
[[ "$output" == *'FAIL'* ]] || {
  printf 'FAIL: SERGEANT_PORTABLE_MARKER_LSOF_LIMIT=1024 should still enforce a (small) bound, got: %s\n' "$output" >&2
  exit 1
}
printf 'enumerate_portable_holders byte limit remains enforced and overridable: ok\n'
