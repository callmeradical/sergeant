#!/usr/bin/env bash
# Regression: sgt-td-memory records handoff evidence only from a verified
# worktree, and every git field it stores resolves from that worktree rather
# than from the supervisor's current directory (GH #173).
#
# Seam under test: the sgt-td-memory CLI.  Two parts:
#
#   Part A  A fake td observes its own CWD and flags, so the contract Sergeant
#           owns is asserted everywhere, with no dependency on td's storage.
#   Part B  A real td MEASURES the actual binding of "td handoff --work-dir"
#           across two linked worktrees on different branches and commits,
#           reading the captured state back through "td context".  Skipped when
#           td is unavailable.
#
# Part B exists because GH #173's technical grounding could not be verified
# read-only: whether td honors --work-dir for its automatic git fields is a
# measurement, not an assumption, and nothing in Sergeant may claim it without
# this evidence.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# ── Two linked worktrees on different branches and commits ───────────────────

PRIMARY="$TEST_ROOT/primary"
FEATURE="$TEST_ROOT/feature"
mkdir -p "$PRIMARY"
git -C "$PRIMARY" init -q -b main .
git -C "$PRIMARY" config user.name Test
git -C "$PRIMARY" config user.email test@example.invalid
printf 'primary\n' > "$PRIMARY/a.txt"
git -C "$PRIMARY" add a.txt
git -C "$PRIMARY" commit -qm 'primary commit'
git -C "$PRIMARY" branch -q feature/worktree-binding
git -C "$PRIMARY" worktree add -q "$FEATURE" feature/worktree-binding
printf 'feature\n' > "$FEATURE/b.txt"
git -C "$FEATURE" add b.txt
git -C "$FEATURE" commit -qm 'feature commit'

PRIMARY_BRANCH="$(git -C "$PRIMARY" branch --show-current)"
PRIMARY_HEAD="$(git -C "$PRIMARY" rev-parse --short HEAD)"
FEATURE_BRANCH="$(git -C "$FEATURE" branch --show-current)"
FEATURE_HEAD="$(git -C "$FEATURE" rev-parse --short HEAD)"
[[ "$PRIMARY_BRANCH" != "$FEATURE_BRANCH" && "$PRIMARY_HEAD" != "$FEATURE_HEAD" ]] || {
  printf 'FAIL: fixture worktrees do not differ\n' >&2
  exit 1
}

# ══ Part A — the contract Sergeant owns ══════════════════════════════════════

mkdir -p "$TEST_ROOT/fake-bin"
cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash
# Records the invocation's own CWD and its --work-dir so the test can compare
# them.  Fails on demand so the abort path can be exercised.
{
  printf 'cwd=%s\n' "$PWD"
  printf 'argv=%s\n' "$*"
} >> "$TD_OBSERVED_LOG"
[[ "${TD_SHOULD_FAIL:-0}" != 1 ]] || exit 1
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

# _state <name> [owned-worktree]
# Fleet state records the worktree it owns, exactly as sgt-dispatch writes it.
_state() {
  local name="$1"
  local owned="${2:-$FEATURE}"
  local state="$TEST_ROOT/state-$name"
  mkdir -p "$state"
  printf 'td-fixture-1\n' > "$state/td_task"
  printf '%s\n' "$owned" > "$state/worktree"
  printf '%s\n' "$state"
}

# _memory <state-dir> <worktree> [extra env assignments...]
# Always invoked from the PRIMARY checkout, which is exactly the divergence the
# supervisor creates: sgt-watch and sgt-respond call this helper from their own
# directory, not from the worktree.
_memory() {
  local state="$1" worktree="$2"
  shift 2
  ( cd "$PRIMARY" && \
    env PATH="$TEST_ROOT/fake-bin:$PATH" "$@" \
      "$ROOT_DIR/bin/sgt-td-memory" handoff "$state" "$worktree" )
}

# ── A1. A verified worktree binds td's git context to that worktree ──────────

state="$(_state verified)"
printf 'in_progress\n' > "$FEATURE/.sergeant-status"
observed="$TEST_ROOT/observed-verified"
_memory "$state" "$FEATURE" TD_OBSERVED_LOG="$observed"
[[ "$(sed -n 's/^cwd=//p' "$observed")" == "$FEATURE" ]] || {
  printf 'FAIL: td ran with CWD %q instead of the verified worktree %q\n' \
    "$(sed -n 's/^cwd=//p' "$observed")" "$FEATURE" >&2
  exit 1
}
argv="$(sed -n 's/^argv=//p' "$observed")"
[[ "$argv" == *"--work-dir $FEATURE"* ]] || {
  printf 'FAIL: td was not given --work-dir %q; argv was: %s\n' "$FEATURE" "$argv" >&2
  exit 1
}
# The explicit summary carries the worktree's own branch and head, never the
# supervisor checkout's.
[[ "$argv" == *"branch=$FEATURE_BRANCH,"* ]] || {
  printf 'FAIL: handoff summary branch is not the worktree branch: %s\n' "$argv" >&2
  exit 1
}
[[ "$argv" == *"head=$FEATURE_HEAD"* ]] || {
  printf 'FAIL: handoff summary head is not the worktree head: %s\n' "$argv" >&2
  exit 1
}
[[ "$argv" != *"branch=$PRIMARY_BRANCH,"* ]] || {
  printf 'FAIL: handoff summary leaked the supervisor checkout branch: %s\n' "$argv" >&2
  exit 1
}
[[ "$argv" != *"head=$PRIMARY_HEAD"* ]] || {
  printf 'FAIL: handoff summary leaked the supervisor checkout head: %s\n' "$argv" >&2
  exit 1
}
[[ ! -e "$state/diagnostic" ]]

# ── A2. A missing worktree fails closed and records nothing in td ────────────

state="$(_state missing "$TEST_ROOT/does-not-exist")"
observed="$TEST_ROOT/observed-missing"
set +e
_memory "$state" "$TEST_ROOT/does-not-exist" TD_OBSERVED_LOG="$observed"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  printf 'FAIL: a missing worktree was accepted\n' >&2
  exit 1
}
[[ ! -e "$observed" ]] || {
  printf 'FAIL: td was invoked for an unverified worktree\n' >&2
  exit 1
}
grep -Fq 'unverified worktree' "$state/diagnostic" || {
  printf 'FAIL: missing-worktree diagnostic was %q\n' \
    "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}

# ── A3. A directory that is not a git worktree fails closed ─────────────────

mkdir -p "$TEST_ROOT/plain-dir"
state="$(_state notgit "$TEST_ROOT/plain-dir")"
observed="$TEST_ROOT/observed-notgit"
set +e
_memory "$state" "$TEST_ROOT/plain-dir" TD_OBSERVED_LOG="$observed"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$observed" ]]
grep -Fq 'unverified worktree' "$state/diagnostic"

# ── A4. A git-capture failure aborts instead of recording "unavailable" ──────
# A worktree whose git metadata cannot be read must abort.  Nothing may ever be
# stored as the literal string "unavailable".

REAL_GIT="$(command -v git)"
mkdir -p "$TEST_ROOT/fail-bin"
cat > "$TEST_ROOT/fail-bin/git" <<'EOF'
#!/usr/bin/env bash
# Passes every call through to the real git except the one capture the test is
# targeting, so the abort path under test is that capture and never the
# worktree verification.
case "$* " in
  *"rev-parse HEAD "*)
    [[ "${FAIL_HEAD:-0}" != 1 ]] || exit 3
    ;;
  *"branch --show-current "*)
    [[ "${FAIL_BRANCH:-0}" != 1 ]] || exit 3
    ;;
esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/fail-bin/git"

# _reject_git_capture <case> <failure-env-assignment>
_reject_git_capture() {
  local name="$1" failure="$2"
  local state observed status
  state="$(_state "$name")"
  observed="$TEST_ROOT/observed-$name"
  set +e
  ( cd "$PRIMARY" && \
    env PATH="$TEST_ROOT/fail-bin:$TEST_ROOT/fake-bin:$PATH" \
      REAL_GIT="$REAL_GIT" "$failure" TD_OBSERVED_LOG="$observed" \
      "$ROOT_DIR/bin/sgt-td-memory" handoff "$state" "$FEATURE" )
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf 'FAIL: %s git-capture failure was accepted\n' "$name" >&2
    exit 1
  }
  [[ ! -e "$observed" ]] || {
    printf 'FAIL: %s recorded a handoff in td despite failed git capture\n' "$name" >&2
    exit 1
  }
  grep -Fq 'git capture failed' "$state/diagnostic" || {
    printf 'FAIL: %s diagnostic was %q\n' "$name" \
      "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
    exit 1
  }
  if grep -Fq 'unavailable' "$state/diagnostic"; then
    printf 'FAIL: %s degraded to the literal string "unavailable"\n' "$name" >&2
    exit 1
  fi
}

_reject_git_capture gitfail-head FAIL_HEAD=1
_reject_git_capture gitfail-branch FAIL_BRANCH=1

# ── A5. The response action verifies the worktree the same way ───────────────

state="$(_state response "$TEST_ROOT/does-not-exist")"
observed="$TEST_ROOT/observed-response"
set +e
( cd "$PRIMARY" && \
  env PATH="$TEST_ROOT/fake-bin:$PATH" TD_OBSERVED_LOG="$observed" \
    "$ROOT_DIR/bin/sgt-td-memory" response "$state" "$TEST_ROOT/does-not-exist" \
    <<< '0123456789abcdef0123456789abcdef' )
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$observed" ]]
grep -Fq 'unverified worktree' "$state/diagnostic"

state="$(_state response-ok)"
observed="$TEST_ROOT/observed-response-ok"
( cd "$PRIMARY" && \
  env PATH="$TEST_ROOT/fake-bin:$PATH" TD_OBSERVED_LOG="$observed" \
    "$ROOT_DIR/bin/sgt-td-memory" response "$state" "$FEATURE" \
    <<< '0123456789abcdef0123456789abcdef' )
[[ "$(sed -n 's/^cwd=//p' "$observed")" == "$FEATURE" ]] || {
  printf 'FAIL: response action ran td with CWD %q\n' \
    "$(sed -n 's/^cwd=//p' "$observed")" >&2
  exit 1
}

# ── A6. A valid but unowned checkout fails closed ────────────────────────────
# "Is a git worktree" is not enough: the supervisor's own checkout satisfies it,
# and because td binds its capture to the working directory, recording from the
# wrong-but-valid checkout would produce internally consistent yet wrong
# evidence.  This is the case GH #173 calls an identity-mismatched worktree.

state="$(_state unowned)"
observed="$TEST_ROOT/observed-unowned"
set +e
_memory "$state" "$PRIMARY" TD_OBSERVED_LOG="$observed"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  printf 'FAIL: a valid but unowned checkout was accepted\n' >&2
  exit 1
}
[[ ! -e "$observed" ]] || {
  printf 'FAIL: td recorded a handoff for a checkout this fleet record does not own\n' >&2
  exit 1
}
grep -Fq 'is not the owned worktree' "$state/diagnostic" || {
  printf 'FAIL: unowned-checkout diagnostic was %q\n' \
    "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}

# A subdirectory of the owned worktree is not the owned worktree either.
mkdir -p "$FEATURE/nested"
state="$(_state nested "$FEATURE/nested")"
observed="$TEST_ROOT/observed-nested"
set +e
_memory "$state" "$FEATURE/nested" TD_OBSERVED_LOG="$observed"
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  printf 'FAIL: a subdirectory of a worktree was accepted as the worktree\n' >&2
  exit 1
}
[[ ! -e "$observed" ]]
grep -Fq 'is not a worktree root' "$state/diagnostic" || {
  printf 'FAIL: nested-path diagnostic was %q\n' \
    "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}

# Fleet state that records no owned worktree cannot be reconciled, so it aborts.
state="$TEST_ROOT/state-noowner"
mkdir -p "$state"
printf 'td-fixture-1\n' > "$state/td_task"
observed="$TEST_ROOT/observed-noowner"
set +e
_memory "$state" "$FEATURE" TD_OBSERVED_LOG="$observed"
status=$?
set -e
[[ "$status" -ne 0 ]]
[[ ! -e "$observed" ]]
grep -Fq 'records no owned worktree' "$state/diagnostic"

# ── A7. The handoff summary carries the FULL head ────────────────────────────
# GH #173 names the full head; an abbreviated prefix is a display convenience.

state="$(_state fullhead)"
observed="$TEST_ROOT/observed-fullhead"
_memory "$state" "$FEATURE" TD_OBSERVED_LOG="$observed"
FEATURE_FULL_HEAD="$(git -C "$FEATURE" rev-parse HEAD)"
[[ "$(sed -n 's/^argv=//p' "$observed")" == *"head=$FEATURE_FULL_HEAD"* ]] || {
  printf 'FAIL: handoff summary does not carry the full head %s\n' "$FEATURE_FULL_HEAD" >&2
  exit 1
}

# ── A8. A detached HEAD is a real state, not a capture failure ───────────────

git -C "$PRIMARY" worktree add -q --detach "$TEST_ROOT/detached" HEAD
state="$(_state detached "$TEST_ROOT/detached")"
observed="$TEST_ROOT/observed-detached"
_memory "$state" "$TEST_ROOT/detached" TD_OBSERVED_LOG="$observed"
[[ "$(sed -n 's/^argv=//p' "$observed")" == *"branch=detached,"* ]] || {
  printf 'FAIL: detached HEAD was not recorded as detached: %s\n' \
    "$(sed -n 's/^argv=//p' "$observed")" >&2
  exit 1
}
[[ ! -e "$state/diagnostic" ]] || {
  printf 'FAIL: a detached HEAD was treated as a capture failure\n' >&2
  exit 1
}

# ══ Part B — MEASURE the real binding ════════════════════════════════════════

if ! command -v td >/dev/null 2>&1; then
  printf 'sgt-td-memory worktree binding: ok (part B skipped: td unavailable)\n'
  exit 0
fi

# _td_snapshot <event> <task-id>
# Prints "<short-commit> <branch> <dirty-files>" for the newest snapshot td
# stored for <event>, "SKIP" when td no longer stores them, or "NONE".
#
# This reads td's own database because no td command surfaces that record: "td
# context" prints the stored "start" snapshot but recomputes its "Current" line
# from the reader's working directory, so reading it back through "td context"
# would measure the reader instead of the handoff.
_td_snapshot() {
  python3 - "$PRIMARY/.todos/issues.db" "$2" "$1" <<'PY_SNAPSHOT'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
tables = {row[0] for row in connection.execute(
    "select name from sqlite_master where type='table'")}
if "git_snapshots" not in tables:
    print("SKIP")
    raise SystemExit(0)
rows = list(connection.execute(
    "select commit_sha, branch, dirty_files from git_snapshots"
    " where issue_id = ? and event = ? order by timestamp desc limit 1",
    (sys.argv[2], sys.argv[3])))
if not rows:
    print("NONE")
    raise SystemExit(0)
commit, branch, dirty = rows[0]
print("%s %s %s" % (commit[:7], branch, dirty))
PY_SNAPSHOT
}

td init --work-dir "$PRIMARY" >/dev/null 2>&1 || true
[[ -d "$PRIMARY/.todos" ]] || {
  printf 'sgt-td-memory worktree binding: ok (part B skipped: td init unavailable)\n'
  exit 0
}

task_json=""
if ! task_json="$( cd "$PRIMARY" && td create 'Worktree binding measurement' \
  --work-dir "$PRIMARY" --json 2>/dev/null )"; then
  task_json=""
fi
task_id="$(printf '%s' "$task_json" | \
  python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
[[ -n "$task_id" ]] || {
  printf 'sgt-td-memory worktree binding: ok (part B skipped: td create unavailable)\n'
  exit 0
}
# Record where the passed worktree stood when work started, then add a commit, so
# commits-since-start has something to derive and can be checked.
COMMITS_SINCE_START_BASE="$(git -C "$FEATURE" rev-parse --short HEAD)"
( cd "$FEATURE" && td start "$task_id" --work-dir "$FEATURE" >/dev/null 2>&1 ) || true
printf 'since start\n' > "$FEATURE/since-start.txt"
git -C "$FEATURE" add since-start.txt
git -C "$FEATURE" commit -qm 'commit after start'
FEATURE_HEAD="$(git -C "$FEATURE" rev-parse --short HEAD)"

# Dirty the two checkouts by DIFFERENT amounts, so a recorded dirty count that
# matches the passed worktree cannot have come from the other checkout.
printf 'dirty one\n' > "$FEATURE/dirty-a.txt"
printf 'dirty two\n' > "$FEATURE/dirty-b.txt"
git -C "$FEATURE" add dirty-a.txt dirty-b.txt
printf 'dirty primary\n' > "$PRIMARY/dirty-primary.txt"
git -C "$PRIMARY" add dirty-primary.txt

real_state="$TEST_ROOT/state-real"
mkdir -p "$real_state"
printf '%s\n' "$task_id" > "$real_state/td_task"
printf '%s\n' "$FEATURE" > "$real_state/worktree"
printf 'in_progress\n' > "$FEATURE/.sergeant-status"

# Invoke from the primary checkout — the supervisor's divergent CWD — passing
# the feature worktree.
( cd "$PRIMARY" && "$ROOT_DIR/bin/sgt-td-memory" handoff "$real_state" "$FEATURE" )

# ── B1. The handoff Sergeant records is bound to the passed worktree ─────────

measured="$(_td_snapshot handoff "$task_id")"
case "$measured" in
  SKIP)
    printf 'sgt-td-memory worktree binding: ok (measurement skipped: td no longer stores git_snapshots)\n'
    exit 0
    ;;
  NONE)
    printf 'FAIL: td stored no handoff git snapshot for %s\n' "$task_id" >&2
    exit 1
    ;;
esac

read -r measured_head measured_branch measured_dirty <<< "$measured"
if [[ "$measured_head" != "$FEATURE_HEAD" || "$measured_branch" != "$FEATURE_BRANCH" ]]; then
  printf 'FAIL: td bound the handoff to %s (%s); a direct git query in the passed worktree reports %s (%s)\n' \
    "$measured_head" "$measured_branch" "$FEATURE_HEAD" "$FEATURE_BRANCH" >&2
  exit 1
fi
# The other linked checkout must not have influenced the metadata.
if [[ "$measured_head" == "$PRIMARY_HEAD" || "$measured_branch" == "$PRIMARY_BRANCH" ]]; then
  printf 'FAIL: td bound the handoff to the supervisor checkout %s (%s)\n' \
    "$PRIMARY_HEAD" "$PRIMARY_BRANCH" >&2
  exit 1
fi
# Dirty state: the two checkouts are deliberately dirty by different amounts, so
# a count that matches the passed worktree cannot have come from the other one.
FEATURE_DIRTY="$(git -C "$FEATURE" status --porcelain | grep -c . || true)"
PRIMARY_DIRTY="$(git -C "$PRIMARY" status --porcelain | grep -c . || true)"
if [[ "$FEATURE_DIRTY" == "$PRIMARY_DIRTY" ]]; then
  printf 'FAIL: fixture checkouts are dirty by the same amount, so the measurement proves nothing\n' >&2
  exit 1
fi
if [[ "$measured_dirty" != "$FEATURE_DIRTY" ]]; then
  printf 'FAIL: td recorded %s dirty files; the passed worktree has %s (the other checkout has %s)\n' \
    "$measured_dirty" "$FEATURE_DIRTY" "$PRIMARY_DIRTY" >&2
  exit 1
fi
# Commits-since-start is derived from the start snapshot against the handoff
# snapshot, so both must be bound to the passed worktree for it to be right.
start_measured="$(_td_snapshot start "$task_id")"
case "$start_measured" in
  SKIP|NONE) ;;
  *)
    read -r start_head start_branch _ <<< "$start_measured"
    if [[ "$start_branch" != "$FEATURE_BRANCH" ]]; then
      printf 'FAIL: the start snapshot is bound to %s, so commits-since-start cannot be right\n' \
        "$start_branch" >&2
      exit 1
    fi
    if [[ "$start_head" != "$COMMITS_SINCE_START_BASE" ]]; then
      printf 'FAIL: the start snapshot head is %s; the passed worktree was at %s when work started\n' \
        "$start_head" "$COMMITS_SINCE_START_BASE" >&2
      exit 1
    fi
    expected_since="$(git -C "$FEATURE" rev-list --count "$COMMITS_SINCE_START_BASE..HEAD")"
    if [[ "$expected_since" != "1" ]]; then
      printf 'FAIL: fixture expected exactly one commit since start, got %s\n' "$expected_since" >&2
      exit 1
    fi
    ;;
esac

# ── B2. Controls: what td does WITHOUT Sergeant's working-directory binding ───
# These two invocations are the evidence for the claim in bin/sgt-td-memory that
# td binds its automatic git capture to the process working directory rather than
# to --work-dir.  Without them that claim would be an assertion, which the task
# explicitly forbids.

_control_task() {
  local title="$1" cwd="$2" json id
  json="$( cd "$cwd" && td create "$title" --work-dir "$PRIMARY" --json 2>/dev/null )" || return 1
  id="$(printf '%s' "$json" | \
    python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)" || return 1
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# Control 1: td invoked FROM the other checkout, with the feature worktree passed
# explicitly. If td honored --work-dir, this would record the feature worktree.
if control_id="$(_control_task 'Control: td from the other checkout' "$PRIMARY")"; then
  ( cd "$PRIMARY" && td handoff "$control_id" --work-dir "$FEATURE" \
    --done control --remaining control >/dev/null 2>&1 ) || true
  control_measured="$(_td_snapshot handoff "$control_id")"
  case "$control_measured" in
    SKIP|NONE) ;;
    *)
      read -r control_head control_branch _ <<< "$control_measured"
      if [[ "$control_branch" != "$PRIMARY_BRANCH" || "$control_head" != "$PRIMARY_HEAD" ]]; then
        printf 'FAIL: control 1 recorded %s (%s); the documented behaviour is the invoking checkout %s (%s). Update bin/sgt-td-memory: td may now honor --work-dir.\n' \
          "$control_head" "$control_branch" "$PRIMARY_HEAD" "$PRIMARY_BRANCH" >&2
        exit 1
      fi
      ;;
  esac
fi

# Control 2: td invoked from a directory that is not a repository at all, with
# the feature worktree passed explicitly. The documented behaviour is that no
# git state is captured.
non_repo="$TEST_ROOT/not-a-repo"
mkdir -p "$non_repo"
if control_id="$(_control_task 'Control: td from a non-repository directory' "$non_repo")"; then
  ( cd "$non_repo" && td handoff "$control_id" --work-dir "$FEATURE" \
    --done control --remaining control >/dev/null 2>&1 ) || true
  control_measured="$(_td_snapshot handoff "$control_id")"
  if [[ "$control_measured" != "NONE" && "$control_measured" != "SKIP" ]]; then
    printf 'FAIL: control 2 recorded %s; the documented behaviour is that no git state is captured from a non-repository directory. Update bin/sgt-td-memory.\n' \
      "$control_measured" >&2
    exit 1
  fi
fi

printf 'sgt-td-memory worktree binding: ok\n'
