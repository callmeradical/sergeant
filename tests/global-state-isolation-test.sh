#!/usr/bin/env bash
# global-state-isolation-test.sh — Guard: no test suite may touch REAL Sergeant
# state.
#
# Why this exists (incident 2026-08-05, td-79f0a8):
#   tests/sgt-drain-worker-test.sh set no drain-state isolation, so
#   _sgt_drain_state_dir fell through to $HOME/.config/sergeant/drain and the
#   suite wrote FOUR REAL GLOBAL DRAINS.  Every interactive worker of every
#   coordinator that polled during one of those short-lived windows
#   cooperatively drained and died mid-mission — including workers owned by
#   other coordinator sessions and other projects.  Because the suite cleared
#   each drain immediately, `sgt-drain --status` showed nothing afterwards and
#   the deaths looked like unexplained stops.
#
#   Repository instructions tell every worker to run the complete tests
#   directory at the end of its mission, so the defect fired as each worker's
#   FINAL act.
#
# What this guard proves:
#   1. Static: every suite that touches drain or fleet state declares isolation.
#   2. Dynamic: with HOME redirected to a canary containing a simulated live
#      worker, running every suite leaves that canary byte-for-byte untouched —
#      no drain file appears and no worker status changes.
#   3. Transitive: every suite invoked by tests/run-drain-tests.sh is audited.
#
# The dynamic audit is the real assertion: it catches this defect class no
# matter which variable, helper, or code path a future suite uses to resolve a
# path, because it observes the filesystem rather than the source.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
failures=0

_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# ── Part 1: static isolation declarations ────────────────────────────────────
#
# A suite that exercises drain state must pin it to its own temporary root.  A
# suite that exercises fleet state must pin SERGEANT_FLEET.  This is the exact
# check whose absence allowed the incident, kept cheap so it runs everywhere.

# Commands that resolve drain state themselves (directly, or by sourcing
# bin/_sgt-drain.sh).  Commands that take an explicit state path instead of
# resolving a root — sgt-td-memory, and sgt-interactive-worker's state/worktree
# arguments — are covered here only because the worker also consults drain state.
_touches_drain() {
  grep -qE '_sgt-drain\.sh|bin/sgt-drain|bin/sgt-undrain|bin/sgt-interactive-worker|bin/sgt-respond|bin/sgt-recover|bin/sgt-dispatch|bin/sgt-drain-force' "$1"
}

# Redirecting HOME is valid isolation: it is the last link in the resolution
# chain, so a suite that redirects HOME cannot reach the real drain directory.
_declares_drain_isolation() {
  grep -qE 'SERGEANT_DRAIN_DIR=|SERGEANT_CONFIG=|HOME=' "$1"
}

_touches_fleet() {
  grep -qE 'bin/sgt-(watch|wake|cleanup|notify|validate|ack-response|dispatch|respond|recover|drain-force|callback)' "$1"
}

_declares_fleet_isolation() {
  grep -qE 'SERGEANT_FLEET=|HOME=' "$1"
}

for suite in "$ROOT_DIR"/tests/*-test.sh; do
  name="$(basename "$suite")"
  [[ "$name" != "$SELF_NAME" ]] || continue
  if _touches_drain "$suite" && ! _declares_drain_isolation "$suite"; then
    _fail "$name exercises drain state but never sets SERGEANT_DRAIN_DIR or SERGEANT_CONFIG"
  fi
  if _touches_fleet "$suite" && ! _declares_fleet_isolation "$suite"; then
    _fail "$name exercises fleet state but never sets SERGEANT_FLEET"
  fi
done
[[ $failures -eq 0 ]] || {
  printf 'global-state isolation: static audit failed\n' >&2
  exit 1
}
printf 'global-state isolation: static declarations present: ok\n'

# ── Part 2: dynamic leak audit against a canary HOME ─────────────────────────

CANARY="$TEST_ROOT/canary-home"
CANARY_CONFIG="$CANARY/.config/sergeant"
CANARY_DATA="$CANARY/.local/share/sergeant"
LIVE_TASK="live-mission"
LIVE_REPO="live-repo"
LIVE_REPO_DIR="$CANARY_DATA/fleet/$LIVE_TASK/$LIVE_REPO"
LIVE_WORKTREE="$CANARY/live-worktree"
SNAPSHOT="$TEST_ROOT/snapshot.expected"

# _reset_canary
#
# Rebuilds a canary HOME that looks like a live Sergeant installation: a real
# drain directory (empty, and writable so a leak is RECORDED rather than merely
# refused), plus one in-flight worker whose status a stray drain would change.
#
# `drain/global` is pre-created as a DIRECTORY.  This is a deliberate trap: the
# offending suites wrote a drain and cleared it immediately, so a leak was
# invisible to any end-of-run check — which is precisely why the incident looked
# like an unexplained worker stop.  _sgt_drain_write ends in `mv <tmp> global`,
# which moves the temp file INSIDE the sentinel directory, and the matching
# `rm -f global` cannot remove a directory.  A transient leak therefore leaves a
# permanent artifact.
_reset_canary() {
  rm -rf "$CANARY"
  mkdir -p "$CANARY_CONFIG/drain/global" "$LIVE_REPO_DIR" "$LIVE_WORKTREE"
  printf 'dev_root: %s\n' "$CANARY/dev" > "$CANARY_CONFIG/config.yaml"
  printf 'in_progress\n'  > "$LIVE_REPO_DIR/status"
  printf 'liveproject\n'  > "$LIVE_REPO_DIR/project"
  printf '%s\n' "$LIVE_WORKTREE" > "$LIVE_REPO_DIR/worktree"
  printf 'in_progress\n'  > "$LIVE_WORKTREE/.sergeant-status"
}

# _watch_canary_drain <record>
#
# Samples the canary drain directory continuously so a drain that is created and
# cleared within one suite is still recorded.  The sentinel trap above catches
# global drains; this catches project-scoped and any other transient drain file.
_watch_canary_drain() {
  local record="$1"
  while :; do
    find "$CANARY_CONFIG/drain" -mindepth 1 2>/dev/null >> "$record"
    sleep 0.05
  done
}

# _canary_drain_leaks <record>
#
# Prints any observed drain path that is not the pre-created sentinel directory.
_canary_drain_leaks() {
  LC_ALL=C sort -u "$1" 2>/dev/null | \
    grep -v "^$CANARY_CONFIG/drain/global\$" || true
}

# _snapshot_canary <output>
#
# Records every path and every regular-file checksum under the canary's Sergeant
# state, so any creation, deletion, or modification is detectable.
_snapshot_canary() {
  {
    find "$CANARY_CONFIG" "$CANARY_DATA" -print 2>/dev/null | LC_ALL=C sort
    find "$CANARY_CONFIG" "$CANARY_DATA" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
    printf 'worktree_status=%s\n' "$(cat "$LIVE_WORKTREE/.sergeant-status" 2>/dev/null || echo MISSING)"
  } > "$1"
}

_reset_canary
_snapshot_canary "$SNAPSHOT"

audited_suites=""
observed_leaks=""
watcher_pid=""
leaked=0
suite_failures=""

for suite in "$ROOT_DIR"/tests/*-test.sh; do
  name="$(basename "$suite")"
  [[ "$name" != "$SELF_NAME" ]] || continue
  audited_suites="$audited_suites $name"

  _reset_canary
  log="$TEST_ROOT/log.$name"
  drain_record="$TEST_ROOT/drainwatch.$name"
  : > "$drain_record"
  suite_rc=0

  _watch_canary_drain "$drain_record" &
  watcher_pid=$!

  # Every Sergeant state variable is unset so each suite must supply its own
  # isolation; HOME and the XDG roots point at the canary so any fallback path
  # lands there instead of the operator's real installation.
  env -u SERGEANT_DRAIN_DIR -u SERGEANT_CONFIG -u SERGEANT_FLEET \
      HOME="$CANARY" \
      XDG_CONFIG_HOME="$CANARY/.config" \
      XDG_DATA_HOME="$CANARY/.local/share" \
      timeout 600 bash "$suite" > "$log" 2>&1 || suite_rc=$?

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [[ $suite_rc -eq 0 ]] || suite_failures="$suite_failures $name"

  actual="$TEST_ROOT/snapshot.actual"
  _snapshot_canary "$actual"
  if ! diff -q "$SNAPSHOT" "$actual" >/dev/null 2>&1; then
    leaked=1
    _fail "$name modified real Sergeant state (canary HOME diff below)"
    diff "$SNAPSHOT" "$actual" 2>&1 | sed 's/^/    /' >&2
  fi
  # Transient drains are the dangerous case: they are long enough to kill a
  # polling worker but gone before anyone can inspect durable state.
  observed_leaks="$(_canary_drain_leaks "$drain_record")"
  if [[ -n "$observed_leaks" ]]; then
    leaked=1
    _fail "$name wrote REAL drain state under \$HOME/.config/sergeant/drain:"
    printf '%s\n' "$observed_leaks" | sed 's/^/    /' >&2
  fi
  if [[ "$(cat "$LIVE_REPO_DIR/status" 2>/dev/null || true)" != "in_progress" ]]; then
    leaked=1
    _fail "$name changed a live worker's fleet status"
  fi
done

[[ $leaked -eq 0 ]] || {
  printf 'global-state isolation: dynamic audit failed\n' >&2
  exit 1
}
printf 'global-state isolation: no suite touched real Sergeant state: ok\n'
printf 'global-state isolation: simulated live worker was not drained: ok\n'

# The audit must not be vacuous: the suite that caused the incident has to run
# to completion under the canary HOME, proving it exercised its drain writes and
# still leaked nothing.
if [[ " $suite_failures " == *" sgt-drain-worker-test.sh "* ]]; then
  printf 'FAIL: sgt-drain-worker-test.sh did not pass under the canary HOME, so its drain writes were not exercised\n' >&2
  sed 's/^/    /' "$TEST_ROOT/log.sgt-drain-worker-test.sh" >&2
  exit 1
fi
printf 'global-state isolation: the formerly leaking suite ran fully and leaked nothing: ok\n'

# ── Part 3: transitive coverage of the drain runner ──────────────────────────
#
# tests/run-drain-tests.sh invoked the offending suite at :99, so its safety must
# be established too.  Every suite it dispatches must be in the audited set.

runner="$ROOT_DIR/tests/run-drain-tests.sh"
if [[ -f "$runner" ]]; then
  runner_suites="$(grep -oE 'tests/[A-Za-z0-9._-]+-test\.sh' "$runner" | \
    sed 's#^tests/##' | LC_ALL=C sort -u)"
  [[ -n "$runner_suites" ]] || \
    _fail "could not determine which suites run-drain-tests.sh invokes"
  for name in $runner_suites; do
    case " $audited_suites " in
      *" $name "*) : ;;
      *) _fail "run-drain-tests.sh invokes $name, which the audit does not cover" ;;
    esac
  done
fi
[[ $failures -eq 0 ]] || exit 1
printf 'global-state isolation: run-drain-tests.sh is transitively safe: ok\n'

if [[ -n "$suite_failures" ]]; then
  printf 'note: suites that did not pass under a redirected HOME (not leaks):%s\n' \
    "$suite_failures"
fi

printf 'global-state isolation: all tests passed\n'
