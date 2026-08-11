#!/usr/bin/env bash
# Regression for terminal-worker recycling (td-b377a0 / GH #152, absorbing td-de2936).
#
# Two verified defects:
#   * _sync_task called _recycle_terminal_worker only for done|failed:*. `drained`
#     was recognised everywhere else but never recycled, so a drained worker kept
#     its pane forever.
#   * worker_recycled was a permanent task-level marker: the guard early-returned
#     whenever it was non-empty, it was stamped merely because the recorded pane
#     was absent, and nothing cleared, generationed or identity-bound it. Any
#     relaunch that rewrote pane/pane_identity therefore permanently suppressed
#     recycling of every later pane.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fleet" "$fake_bin"

# Fake tmux.  LIVE_PANES lists pane ids that still exist; a kill removes one.
cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
_live() {
  local pane="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" == "$pane" ]] && return 0
  done < "$LIVE_PANES"
  return 1
}
case "$1" in
  display-message)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    _live "$target" || exit 1
    case "${!#}" in
      '#{pane_id}') printf '%s\n' "$target" ;;
      '#{pane_activity}') printf '%s\n' "${PANE_ACTIVITY:-0}" ;;
      *)
        identity_file="$IDENTITY_DIR/${target#%}"
        if [[ -s "$identity_file" ]]; then
          cat "$identity_file"
        else
          printf '0|%s|4242|123456|worker\n' "$target"
        fi
        ;;
    esac
    ;;
  kill-pane)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    printf '%s\n' "$target" >> "$KILL_LOG"
    grep -v -x "$target" "$LIVE_PANES" > "$LIVE_PANES.tmp" || true
    mv "$LIVE_PANES.tmp" "$LIVE_PANES"
    ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
exit 0
TD
chmod +x "$fake_bin/td"

export LIVE_PANES="$TEST_ROOT/live-panes"
export KILL_LOG="$TEST_ROOT/kill.log"
export IDENTITY_DIR="$TEST_ROOT/identities"
mkdir -p "$IDENTITY_DIR"

# set_pane_identity <pane> <identity> — what the fake tmux reports for a pane, and
# what fleet state records for it.
set_pane_identity() {
  local pane="$1" identity="$2" state="$3"
  printf '%s\n' "$identity" > "$IDENTITY_DIR/${pane#%}"
  printf '%s\n' "$identity" > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
}

# make_worker <name> <status> <pane> — a fleet task "task-<name>" owning "app".
# Prints "<repo_state> <worktree>".
make_worker() {
  local name="$1" status="$2" pane="$3"
  local task_dir state wt
  task_dir="$fleet/task-$name"
  state="$task_dir/app"
  wt="$TEST_ROOT/wt-$name"
  mkdir -p "$state" "$wt"
  printf 'Brief: recycle %s\n' "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt" > "$state/worktree"
  printf '%s\n' "$status" > "$state/status"
  printf '%s\n' "$status" > "$wt/.sergeant-status"
  case "$status" in
    done) printf 'https://example.invalid/pr/1\n' > "$wt/.sergeant-result" ;;
  esac
  printf '%s\n' "$pane" > "$state/pane"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$IDENTITY_DIR/${pane#%}"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$state/pane_identity"
  printf '4242\n' > "$state/worker_pid"
  printf '4242\n' > "$state/worker_process_group"
  printf 'fixture worker start\n' > "$state/worker_process_start"
  chmod 600 "$state/pane_identity"
  printf '%s\n' "$pane" >> "$LIVE_PANES"
  printf '%s %s\n' "$state" "$wt"
}

sync_task() {
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
    "KILL_LOG=$KILL_LOG" "$@" "$ROOT_DIR/bin/sgt-watch" --sync "$1" >/dev/null 2>&1
}

_pane_live() {
  grep -q -x "$1" "$LIVE_PANES" 2>/dev/null
}

: > "$LIVE_PANES"
: > "$KILL_LOG"

# ── 1. A drained worker is recycled ───────────────────────────────────────────

read -r state wt <<<"$(make_worker drained drained '%10')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-drained >/dev/null
if _pane_live '%10'; then
  printf 'a drained worker pane was not recycled\n' >&2
  exit 1
fi
[[ -s "$state/worker_recycled" ]] || {
  printf 'no recycle evidence was recorded for a drained worker\n' >&2
  exit 1
}
# The evidence names the exact pane identity that was recycled, not just a date.
grep -Fq '0|%10|4242|123456|worker' "$state/worker_recycled" || {
  printf 'recycle evidence is not bound to the pane identity:\n%s\n' \
    "$(cat "$state/worker_recycled")" >&2
  exit 1
}
[[ "$(cat "$state/status")" == "drained" ]]

# ── 2. done and failed are still recycled ────────────────────────────────────

read -r state wt <<<"$(make_worker done done '%11')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-done >/dev/null
_pane_live '%11' && { printf 'a done worker pane was not recycled\n' >&2; exit 1; }

read -r state wt <<<"$(make_worker failed 'failed: deliberate' '%12')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-failed >/dev/null
_pane_live '%12' && { printf 'a failed worker pane was not recycled\n' >&2; exit 1; }

# ── 3. Nonterminal and unreconciled states fail closed ───────────────────────

pane_number=20
for status in in_progress needs_input blocked waiting orphaned; do
  pane="%$pane_number"
  pane_number=$((pane_number + 1))
  read -r state wt <<<"$(make_worker "$status" "$status" "$pane")"
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
    "$ROOT_DIR/bin/sgt-watch" --sync "task-$status" >/dev/null
  _pane_live "$pane" || {
    printf 'a %s worker pane was recycled; nonterminal states must fail closed\n' \
      "$status" >&2
    exit 1
  }
  [[ ! -e "$state/worker_recycled" ]] || {
    printf 'a %s worker was stamped with recycle evidence\n' "$status" >&2
    exit 1
  }
done

# ── 4. Recycling is idempotent for an unchanged pane identity ────────────────

read -r state wt <<<"$(make_worker idempotent done '%30')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-idempotent >/dev/null
first_evidence="$(cat "$state/worker_recycled")"
kills_before="$(grep -c -x '%30' "$KILL_LOG" || true)"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-idempotent >/dev/null
[[ "$(cat "$state/worker_recycled")" == "$first_evidence" ]] || {
  printf 'a second sync rewrote the recycle evidence\n' >&2
  exit 1
}
[[ "$(grep -c -x '%30' "$KILL_LOG" || true)" == "$kills_before" ]] || {
  printf 'a second sync tried to recycle the same pane again\n' >&2
  exit 1
}

# ── 5. A relaunch does not inherit stale recycle evidence ────────────────────
# This is the core td-b377a0 defect: after any stamped marker, a rewritten
# pane/pane_identity must still be recycled rather than permanently suppressed.

read -r state wt <<<"$(make_worker relaunch done '%40')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-relaunch >/dev/null
_pane_live '%40' && { printf 'the first pane was not recycled\n' >&2; exit 1; }
[[ -s "$state/worker_recycled" ]]

# A relaunch installs a new live pane and a new identity, and the worker becomes
# terminal again.
printf '%%41\n' > "$state/pane"
set_pane_identity '%41' '0|%41|4141|999999|worker' "$state"
printf '4141\n' > "$state/worker_pid"
printf '4141\n' > "$state/worker_process_group"
printf 'fixture relaunched worker start\n' > "$state/worker_process_start"
printf '%%41\n' >> "$LIVE_PANES"
printf 'done\n' > "$state/status"
printf 'done\n' > "$wt/.sergeant-status"

env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-relaunch >/dev/null
if _pane_live '%41'; then
  printf 'stale recycle evidence suppressed recycling of the relaunched pane\n' >&2
  printf 'evidence:\n%s\n' "$(cat "$state/worker_recycled")" >&2
  exit 1
fi
grep -Fq '0|%41|4141|999999|worker' "$state/worker_recycled" || {
  printf 'recycle evidence was not rebound to the relaunched pane identity:\n%s\n' \
    "$(cat "$state/worker_recycled")" >&2
  exit 1
}
# Both recyclings are retained as history, so evidence is never lost.
grep -Fq '%40' "$state/worker_recycled_log" && grep -Fq '%41' "$state/worker_recycled_log" || {
  printf 'recycle history did not retain both panes:\n%s\n' \
    "$(cat "$state/worker_recycled_log" 2>/dev/null || true)" >&2
  exit 1
}

# ── 6. An empty or malformed marker is not treated as proof (td-de2936) ──────
# The guard must never accept a truncated marker as evidence that a live pane was
# already retired.

read -r state wt <<<"$(make_worker emptymarker done '%50')"
: > "$state/worker_recycled"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-emptymarker >/dev/null
if _pane_live '%50'; then
  printf 'an empty recycle marker suppressed recycling of a live pane\n' >&2
  exit 1
fi

read -r state wt <<<"$(make_worker garbagemarker done '%51')"
printf 'recycled\n' > "$state/worker_recycled"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-garbagemarker >/dev/null
if _pane_live '%51'; then
  printf 'a marker naming no pane identity suppressed recycling of a live pane\n' >&2
  exit 1
fi

# ── 7. An identity mismatch refuses to recycle ───────────────────────────────

read -r state wt <<<"$(make_worker mismatch done '%60')"
# Fleet state records one identity while the live pane reports another.
printf '0|%%60|9999|777777|someone-else\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-mismatch >/dev/null 2>&1 || true
_pane_live '%60' || {
  printf 'a pane whose identity does not match the record was recycled\n' >&2
  exit 1
}
[[ ! -e "$state/worker_recycled" ]] || {
  printf 'an identity mismatch was stamped as recycled\n' >&2
  exit 1
}
grep -Fq 'identity' "$state/diagnostic" || {
  printf 'the identity mismatch was not diagnosed:\n%s\n' \
    "$(cat "$state/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}

# ── 7b. Identity mismatch warning is actionable (GH #203) ────────────────────
# The WARNING emitted to stderr must name a supported next step (sgt-cleanup).

mismatch_stderr="$TEST_ROOT/t7b-stderr"
read -r state7b wt7b <<<"$(make_worker mismatch-7b done '%61')"
printf '0|%%61|9999|777777|someone-else\n' > "$state7b/pane_identity"
chmod 600 "$state7b/pane_identity"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-mismatch-7b >/dev/null 2>"$mismatch_stderr" || true
grep -Fq 'sgt-cleanup' "$mismatch_stderr" || {
  printf 'identity mismatch warning does not name sgt-cleanup:\n%s\n' \
    "$(cat "$mismatch_stderr")" >&2
  exit 1
}
# The diagnostic file must also reference the recovery command.
grep -Fq 'sgt-cleanup' "$state7b/diagnostic" || {
  printf 'identity mismatch diagnostic file does not name sgt-cleanup:\n%s\n' \
    "$(cat "$state7b/diagnostic" 2>/dev/null || true)" >&2
  exit 1
}

# ── 8. An absent pane records evidence without claiming a kill ───────────────

read -r state wt <<<"$(make_worker absent done '%70')"
grep -v -x '%70' "$LIVE_PANES" > "$LIVE_PANES.tmp" || true
mv "$LIVE_PANES.tmp" "$LIVE_PANES"
kills_before="$(wc -l < "$KILL_LOG" | tr -d ' ')"
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --sync task-absent >/dev/null
[[ "$(wc -l < "$KILL_LOG" | tr -d ' ')" == "$kills_before" ]] || {
  printf 'an absent pane was killed\n' >&2
  exit 1
}
[[ -s "$state/worker_recycled" ]] || {
  printf 'an absent pane recorded no recycle evidence\n' >&2
  exit 1
}
grep -Fq '0|%70|4242|123456|worker' "$state/worker_recycled" || {
  printf 'absent-pane evidence is not bound to the recorded identity:\n%s\n' \
    "$(cat "$state/worker_recycled")" >&2
  exit 1
}

printf 'terminal worker recycling: ok\n'
