#!/usr/bin/env bash
# Regression for sgt-recover's two GH #160 defects (td-3de0ac):
#
#  1. An absent .sergeant-gate-generation leaked a raw shell error. The
#     `2>/dev/null` on `tr -d '\n' < "$file" 2>/dev/null || true` silences tr, but
#     the INPUT REDIRECTION fails first and bash writes that failure to the real
#     stderr, reproducing
#     "sgt-recover: line 71: <worktree>/.sergeant-gate-generation: No such file or
#     directory".
#
#  2. A pending action lease refused recovery unconditionally, with no liveness or
#     staleness adjudication of the lease owner and no documented resolution path.
#     A lease whose recorded owner is provably dead must not block recovery; a
#     live owner, a reused pane id, or an unprovable owner must still fail closed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
source_repo="$TEST_ROOT/source"
fake_bin="$TEST_ROOT/fake-bin"
config_dir="$TEST_ROOT/config"
export SERGEANT_CONFIG="$config_dir"
export SGT_WIKI_DISABLED=1

mkdir -p "$fleet" "$source_repo" "$fake_bin" "$config_dir"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name Test
git -C "$source_repo" config user.email test@example.invalid
touch "$source_repo/README.md"
git -C "$source_repo" add README.md
git -C "$source_repo" commit -qm fixture

cat > "$config_dir/test.yaml" <<EOF
repos:
  - name: app
    path: $source_repo
EOF

# Fake tmux.  The stalled supervisor owns %42.  %41 stands in for an older lease
# owner: it resolves only when LEASE_OWNER_ALIVE=1, and then reports whatever
# LEASE_OWNER_IDENTITY says, so a reused pane id can be modelled too.
cat > "$fake_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:-/dev/null}"
case "$1" in
  display-message)
    target=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target="$arg"
      previous="$arg"
    done
    case "$target" in
      %41)
        [[ "${LEASE_OWNER_ALIVE:-0}" == 1 ]] || exit 1
        printf '%s\n' "${LEASE_OWNER_IDENTITY:-0|%41|4141|111111|lease-owner}"
        ;;
      %99)
        printf '0|%%99|9999|654321|relaunched\n'
        if [[ -s "$REPO_STATE_DIR/notification_id" ]]; then
          notification_id="$(cat "$REPO_STATE_DIR/notification_id")"
          nonce="$(cat "$REPO_STATE_DIR/notification_target" 2>/dev/null || true)"
          if [[ "$nonce" =~ ^[a-f0-9]{32}$ ]]; then
            target_dir="$REPO_STATE_DIR/notifications/$notification_id/targets/$nonce"
            mkdir -p "$target_dir"
            printf '%s|%s\n' "$notification_id" "$nonce" > "$target_dir/accepted"
            printf '%s|%s\n' "$notification_id" "$nonce" > "$target_dir/delivered"
          fi
        fi
        ;;
      *)
        printf '0|%%42|4242|123456|stalled-pane\n'
        ;;
    esac
    ;;
  new-window) printf '%%99\n' ;;
  kill-pane)
    target_pane=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == -t ]] && target_pane="$arg"
      previous="$arg"
    done
    printf '%s\n' "$target_pane" >> "${KILL_LOG:-/dev/null}"
    ;;
  send-keys) ;;
  has-session) ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then printf 'td version v0.1.0\n'; exit 0; fi
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' '--description --json --work-dir'; exit 0
fi
exit 0
TD
chmod +x "$fake_bin/td"

NOTIFY="deadbeef00112233445566778899aabb"
LEASE="aabbccddeeff00112233445566778899"

# make_stalled <name> — a stalled in_progress worker owning pane %42.
# Prints "<repo_state> <worktree>".
make_stalled() {
  local name="$1"
  local task_dir state wt pointer git_dir revision
  task_dir="$fleet/task-$name"
  state="$task_dir/app"
  wt="$TEST_ROOT/wt-$name"
  git -C "$source_repo" worktree add -q -b "owner-$name" "$wt"
  mkdir -p "$state"
  printf 'Project: test\nBrief: lease owner test\nBranch: owner-%s\nRepos: app\n' \
    "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt" > "$state/worktree"
  pointer="$(cat "$wt/.git")"
  printf '%s\n' "$pointer" > "$state/worktree_git_pointer"
  git_dir="${pointer#gitdir: }"
  [[ "$git_dir" == /* ]] || git_dir="$wt/$git_dir"
  printf '%s\n' "$(cd "$git_dir" && pwd -P)" > "$state/worktree_git_dir"
  cat > "$task_dir/.sergeant-intent.md" <<'INTENT'
## Objective

Exercise lease owner adjudication.
INTENT
  revision="$(bash -c 'source "$1"; _sgt_intent_revision "$2"' _ \
    "$ROOT_DIR/bin/_sgt-intent.sh" "$task_dir/.sergeant-intent.md")"
  printf '%s\n' "$revision" > "$task_dir/intent_revision"
  cp "$task_dir/.sergeant-intent.md" "$state/.sergeant-intent.md"
  cp "$task_dir/.sergeant-intent.md" "$wt/.sergeant-intent.md"
  printf '%s\n' "$revision" > "$state/intent_revision"
  printf 'in_progress\n' > "$state/status"
  printf 'in_progress\n' > "$wt/.sergeant-status"
  printf 'live worker stalled: no progress for 401s (grace=300s); last event at epoch 1000\n' \
    > "$state/diagnostic"
  printf 'sgt\n' > "$state/tmux_session"
  printf 'task/app\n' > "$state/window_name"
  printf 'opencode\n' > "$state/agent"
  printf '%%42\n' > "$state/pane"
  printf '0|%%42|4242|123456|stalled-pane\n' > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  printf '%s %s\n' "$state" "$wt"
}

# install_lease <state> <owner-pid> — an accepted turn owned by pane %41 with no
# completion proof, so only owner adjudication can decide it.
install_lease() {
  local state="$1" owner_pid="$2"
  local target_dir="$state/notifications/$NOTIFY/targets/$LEASE"
  mkdir -p "$target_dir"
  printf '%s\n' "$NOTIFY" > "$state/notification_id"
  printf '%s\n' "$LEASE" > "$state/notification_target"
  printf '%s\n' "$LEASE" > "$state/notifications/$NOTIFY/action_lease"
  printf '0|%%41|%s|111111|lease-owner\n' "$owner_pid" > "$target_dir/pane_identity"
  printf '%s|%s\n' "$NOTIFY" "$LEASE" > "$target_dir/acknowledged"
  printf '%s|%s\n' "$NOTIFY" "$LEASE" > "$target_dir/accepted"
  printf '%s|%s\n' "$NOTIFY" "$LEASE" > "$target_dir/delivered"
}

recover() {
  local state="$1"
  shift
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "REPO_STATE_DIR=$state" "$@" \
    "$ROOT_DIR/bin/sgt-recover" "$task" app 2>&1
}

# A PID that is certainly not running.
dead_pid=4194303
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done

# ── 1. An absent gate-generation file produces no raw shell error ─────────────

read -r state wt <<<"$(make_stalled nogen)"
task=task-nogen
rm -f "$wt/.sergeant-gate-generation"
set +e
nogen_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/nogen.log" 2>&1)"
nogen_status=$?
set -e
[[ "$nogen_status" -eq 0 ]] || {
  printf 'recovery failed with no gate-generation file:\n%s\n' "$nogen_output" >&2
  exit 1
}
if printf '%s' "$nogen_output" | grep -Fq '.sergeant-gate-generation: No such file or directory'; then
  printf 'the absent gate-generation file leaked a raw redirect error:\n%s\n' \
    "$nogen_output" >&2
  exit 1
fi
if printf '%s' "$nogen_output" | grep -Eq 'sgt-recover: line [0-9]+:'; then
  printf 'sgt-recover leaked a raw shell error:\n%s\n' "$nogen_output" >&2
  exit 1
fi
[[ "$(cat "$state/pane")" == "%99" ]]

# The same must hold on the escalation path, which is what actually reads the
# generation in order to advance it.
read -r state wt <<<"$(make_stalled nogen-escalate)"
task=task-nogen-escalate
rm -f "$wt/.sergeant-gate-generation"
install_lease "$state" 4242   # owner pid is the live-ish stalled pid; unprovable
set +e
esc_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/nogen-esc.log" LEASE_OWNER_ALIVE=1 2>&1)"
set -e
if printf '%s' "$esc_output" | grep -Eq 'sgt-recover: line [0-9]+:'; then
  printf 'the escalation path leaked a raw shell error:\n%s\n' "$esc_output" >&2
  exit 1
fi
# The gate generation was still advanced explicitly from absent to 1.
[[ "$(cat "$wt/.sergeant-gate-generation")" == "1" ]] || {
  printf 'gate generation was not initialised from absent: %s\n' \
    "$(cat "$wt/.sergeant-gate-generation" 2>/dev/null || true)" >&2
  exit 1
}

# ── 2. A provably dead lease owner does not block recovery ────────────────────
# The recorded owner pane no longer resolves AND its recorded process is gone.

read -r state wt <<<"$(make_stalled deadowner)"
task=task-deadowner
printf '1\n' > "$wt/.sergeant-gate-generation"
install_lease "$state" "$dead_pid"
dead_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/dead.log" \
  "KILL_LOG=$TEST_ROOT/dead-kill.log" LEASE_OWNER_ALIVE=0)" || {
  printf 'recovery was refused although the lease owner is provably dead:\n%s\n' \
    "$dead_output" >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%99" ]] || {
  printf 'recovery did not relaunch after adjudicating a dead lease owner\n' >&2
  exit 1
}
# The adjudication is recorded as durable evidence, naming the dead owner.
[[ -s "$state/notifications/$NOTIFY/action_lease_abandoned" ]] || {
  printf 'the dead-owner adjudication was not recorded\n' >&2
  exit 1
}
grep -Fq "$LEASE" "$state/notifications/$NOTIFY/action_lease_abandoned"
grep -Fq "$dead_pid" "$state/notifications/$NOTIFY/action_lease_abandoned"
# Prior delivery evidence is preserved, not destroyed.
[[ "$(cat "$state/notifications/$NOTIFY/targets/$LEASE/accepted")" == "$NOTIFY|$LEASE" ]]
[[ "$(cat "$state/notifications/$NOTIFY/targets/$LEASE/delivered")" == "$NOTIFY|$LEASE" ]]
[[ -s "$state/notifications/$NOTIFY/superseded_target_pane_identity" ]]
# No completion was fabricated for a turn the agent never proved.
[[ ! -e "$state/notifications/$NOTIFY/targets/$LEASE/completed" ]] || {
  printf 'dead-owner adjudication fabricated completion\n' >&2
  exit 1
}

# ── 3. A live lease owner still fails closed ─────────────────────────────────

read -r state wt <<<"$(make_stalled liveowner)"
task=task-liveowner
printf '1\n' > "$wt/.sergeant-gate-generation"
sleep 120 &
live_pid=$!
install_lease "$state" "$live_pid"
set +e
live_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/live.log" \
  "KILL_LOG=$TEST_ROOT/live-kill.log" LEASE_OWNER_ALIVE=1 \
  "LEASE_OWNER_IDENTITY=0|%41|$live_pid|111111|lease-owner")"
live_status=$?
set -e
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
[[ "$live_status" -ne 0 ]] || {
  printf 'recovery proceeded although the lease owner is live\n' >&2
  exit 1
}
[[ -z "$(cat "$TEST_ROOT/live-kill.log" 2>/dev/null || true)" ]] || {
  printf 'a pane was killed while refusing a live-owner lease\n' >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%42" ]]
# The refusal names the lease owner and a supported resolution command.
[[ "$live_output" == *"$LEASE"* ]] || {
  printf 'the refusal did not name the lease owner:\n%s\n' "$live_output" >&2
  exit 1
}
[[ "$live_output" == *"sgt-respond $task app"* ]] || {
  printf 'the refusal did not name a supported resolution command:\n%s\n' "$live_output" >&2
  exit 1
}
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

# ── 4. A reused pane id fails closed ─────────────────────────────────────────
# The recorded pane id resolves, but to a different pane/process than recorded.

read -r state wt <<<"$(make_stalled reused)"
task=task-reused
printf '1\n' > "$wt/.sergeant-gate-generation"
install_lease "$state" "$dead_pid"
set +e
reused_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/reused.log" \
  "KILL_LOG=$TEST_ROOT/reused-kill.log" LEASE_OWNER_ALIVE=1 \
  'LEASE_OWNER_IDENTITY=0|%41|7777|999999|someone-else')"
reused_status=$?
set -e
[[ "$reused_status" -ne 0 ]] || {
  printf 'recovery proceeded although the lease owner pane id was reused\n' >&2
  exit 1
}
[[ -z "$(cat "$TEST_ROOT/reused-kill.log" 2>/dev/null || true)" ]]
[[ "$(cat "$state/pane")" == "%42" ]]
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

# ── 5. An owner whose pane is gone but whose process still runs fails closed ──
# Death is not provable, so recovery must not proceed.

read -r state wt <<<"$(make_stalled unprovable)"
task=task-unprovable
printf '1\n' > "$wt/.sergeant-gate-generation"
sleep 120 &
lingering_pid=$!
install_lease "$state" "$lingering_pid"
set +e
unprovable_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/unprovable.log" \
  "KILL_LOG=$TEST_ROOT/unprovable-kill.log" LEASE_OWNER_ALIVE=0)"
unprovable_status=$?
set -e
kill "$lingering_pid" 2>/dev/null || true
wait "$lingering_pid" 2>/dev/null || true
[[ "$unprovable_status" -ne 0 ]] || {
  printf 'recovery proceeded although the lease owner process is still running\n' >&2
  exit 1
}
[[ -z "$(cat "$TEST_ROOT/unprovable-kill.log" 2>/dev/null || true)" ]]
[[ "$(cat "$state/pane")" == "%42" ]]
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

# ── 6. A malformed owner identity fails closed ───────────────────────────────

read -r state wt <<<"$(make_stalled malformed)"
task=task-malformed
printf '1\n' > "$wt/.sergeant-gate-generation"
install_lease "$state" "$dead_pid"
printf 'not-an-identity\n' > "$state/notifications/$NOTIFY/targets/$LEASE/pane_identity"
set +e
malformed_status_output="$(recover "$state" "TMUX_LOG=$TEST_ROOT/malformed.log" \
  "KILL_LOG=$TEST_ROOT/malformed-kill.log" LEASE_OWNER_ALIVE=0)"
malformed_status=$?
set -e
[[ "$malformed_status" -ne 0 ]] || {
  printf 'recovery proceeded on a malformed lease owner identity\n' >&2
  exit 1
}
[[ "$(cat "$state/pane")" == "%42" ]]
[[ ! -e "$state/notifications/$NOTIFY/action_lease_abandoned" ]]

# ── 7. The existing in-flight-lease guard is preserved, not reverted ──────────
# td-6da427 demanded that an in-flight lease never be silently overwritten. A
# refused recovery must leave the lease and its target evidence exactly as found.

[[ "$(cat "$state/notifications/$NOTIFY/action_lease")" == "$LEASE" ]] || {
  printf 'a refused recovery mutated the action lease\n' >&2
  exit 1
}

printf 'sgt-recover lease owner adjudication: ok\n'
