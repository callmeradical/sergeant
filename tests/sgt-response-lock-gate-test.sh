#!/usr/bin/env bash
# The response-lock transition gate is a PERSISTENT anchor, not a leak.
#
# _sgt_response_lock_transition serializes the non-atomic
# compare/retire/install sequence that installs `response.lock` by flocking
# `<fleet-state>/response.lock.transition`.  Correctness of that mutex depends on
# every participant locking the SAME inode: a holder keeps its lock on an
# unlinked inode while the next opener creates a fresh one and acquires it
# immediately, so unlinking the anchor would let two processes retire and install
# the lock at once and leave two owners of it.
#
# That is why a cleanup refused after acquiring the response lock leaves the gate
# behind (see tests/sgt-cleanup-cross-filesystem-test.sh, which tolerates exactly
# that one addition), and why removing it is never the fix.  These cases pin the
# invariant that justifies the exemption: the gate is created beside the lock,
# carries no state, is never unlinked or replaced by the protocol, and never
# blocks a later acquisition.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=bin/_sgt-response-lock.sh
source "$ROOT_DIR/bin/_sgt-response-lock.sh"

GATE_NAME="response.lock.transition"

_fail() {
  local line
  printf 'FAIL: %s\n' "$1" >&2
  shift
  for line in "$@"; do
    printf '  %s\n' "$line" >&2
  done
  exit 1
}

# Compact one-line listing of a directory, for failure messages.
_list_entries() {
  local root="$1"

  if [[ ! -d "$root" ]]; then
    printf '<absent>'
    return 0
  fi
  (cd "$root" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | \
    sed 's|^\./||' | tr '\n' ' ')
}

# The gate holds no state and is readable only by its owner.
assert_gate_is_empty_anchor() {
  local gate="$1" context="$2"

  [[ -f "$gate" && ! -L "$gate" ]] || _fail \
    "the response-lock transition gate is not a regular file ($context)" \
    "gate: $gate"
  [[ ! -s "$gate" ]] || _fail \
    "the response-lock transition gate carries content ($context)" \
    "gate: $gate" "content: $(cat "$gate")"
  [[ -n "$(find "$gate" -maxdepth 0 -perm 600 -print)" ]] || _fail \
    "the response-lock transition gate is not owner-private ($context)" \
    "gate: $gate"
}

# ── Case 1: acquiring publishes the gate beside the lock ─────────────────────

state1="$TEST_ROOT/state-1"
mkdir -p "$state1"
_sgt_response_lock_acquire "$state1" || _fail "could not acquire the response lock"
[[ -f "$state1/response.lock" ]] || _fail \
  "acquiring the response lock installed no lock file" \
  "state: $(_list_entries "$state1")"
assert_gate_is_empty_anchor "$state1/$GATE_NAME" "after acquire"

_sgt_response_lock_release || _fail "could not release the response lock"
[[ ! -e "$state1/response.lock" ]] || _fail \
  "releasing the response lock left the lock file behind"
# Releasing must NOT unlink the anchor: a waiter blocked on this inode would
# otherwise stop excluding the next acquirer, which creates a new one.
assert_gate_is_empty_anchor "$state1/$GATE_NAME" "after release"

# ── Case 2: the anchor identity is stable across acquisitions ────────────────

state2="$TEST_ROOT/state-2"
mkdir -p "$state2"
_sgt_response_lock_acquire "$state2" || _fail "could not acquire the response lock"
# A hard link to the original anchor: `-ef` then compares device and inode, so an
# unlink-and-recreate cycle is detectable without a stat(1) portability problem.
witness2="$TEST_ROOT/gate-2-witness"
ln "$state2/$GATE_NAME" "$witness2"
_sgt_response_lock_release || _fail "could not release the response lock"
for _ in 1 2 3; do
  _sgt_response_lock_acquire "$state2" || _fail "could not reacquire the response lock"
  _sgt_response_lock_release || _fail "could not release the response lock"
  [[ "$state2/$GATE_NAME" -ef "$witness2" ]] || _fail \
    "the response-lock transition gate was replaced between acquisitions" \
    "gate: $state2/$GATE_NAME" "original anchor: $witness2"
done

# ── Case 3: a gate left by a refused run does not block a later acquisition ──
#
# This is the convergence premise of the cross-filesystem exemption: a cleanup
# rejected after taking the lock leaves the gate and no lock, and the next
# acquisition must still succeed on that exact anchor.

state3="$TEST_ROOT/state-3"
mkdir -p "$state3"
(umask 077 && : >> "$state3/$GATE_NAME")
witness3="$TEST_ROOT/gate-3-witness"
ln "$state3/$GATE_NAME" "$witness3"
_sgt_response_lock_acquire "$state3" || _fail \
  "a leftover transition gate blocked a later response-lock acquisition"
[[ -f "$state3/response.lock" ]] || _fail \
  "acquiring over a leftover gate installed no lock file"
[[ "$state3/$GATE_NAME" -ef "$witness3" ]] || _fail \
  "acquiring over a leftover gate replaced the anchor" \
  "gate: $state3/$GATE_NAME" "original anchor: $witness3"
_sgt_response_lock_release || _fail "could not release the response lock"
assert_gate_is_empty_anchor "$state3/$GATE_NAME" "after acquiring over a leftover gate"

# ── Case 4: the flock fallback anchors the same way ──────────────────────────
#
# _sgt_response_lock_transition prefers python3 and falls back to flock(1).  Both
# implementations own the same anchor, so both are held to it.  PATH is stripped
# to a shim directory without python3 rather than to nothing, so the fallback
# runs with the tools it actually needs.

fallback_bin="$TEST_ROOT/fallback-bin"
mkdir -p "$fallback_bin"
for tool in flock find cat readlink rm rmdir ln; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -z "$tool_path" ]] || ln -s "$tool_path" "$fallback_bin/$tool"
done

if [[ ! -x "$fallback_bin/flock" ]]; then
  printf 'sgt-response-lock gate: flock(1) absent, fallback case skipped\n'
else
  state4="$TEST_ROOT/state-4"
  mkdir -p "$state4"
  printf 'pid=%s\nstart=portable\nnonce=%s\n' "$$" "$(printf '0%.0s' $(seq 1 32))" \
    > "$state4/candidate"
  (
    PATH="$fallback_bin"
    export PATH
    ! command -v python3 >/dev/null 2>&1 || exit 9
    _sgt_response_lock_transition "$state4/response.lock" "$state4/candidate" --absent
  ) || _fail "the flock fallback could not install the response lock" \
    "state: $(_list_entries "$state4")"
  [[ -f "$state4/response.lock" ]] || _fail \
    "the flock fallback installed no lock file" \
    "state: $(_list_entries "$state4")"
  assert_gate_is_empty_anchor "$state4/$GATE_NAME" "after the flock fallback"
fi

printf 'sgt-response-lock transition gate: ok\n'
