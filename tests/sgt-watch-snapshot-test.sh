#!/usr/bin/env bash
# Regression for the bounded read-only fleet snapshot (td-c4f3de / GH #154).
#
# Sergeant had no safe answer to "is Sergeant verifiably doing work right now?".
# --list renders every retained record for humans under a misleading "Active
# tasks:" heading and embeds free-form brief text, and --sync/--sync-all mutate
# lifecycle state. A coordinator or bridge had to either parse human output or
# trigger reconciliation side effects.
#
# --snapshot must be strictly read-only, constant-size, versioned, and must only
# claim busy when it has a verified active witness.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fleet="$TEST_ROOT/fleet"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fleet" "$fake_bin"

export LIVE_PANES="$TEST_ROOT/live-panes"
export IDENTITY_DIR="$TEST_ROOT/identities"
mkdir -p "$IDENTITY_DIR"
: > "$LIVE_PANES"

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
        if [[ -s "$IDENTITY_DIR/${target#%}" ]]; then
          cat "$IDENTITY_DIR/${target#%}"
        else
          printf '0|%s|4242|123456|worker\n' "$target"
        fi
        ;;
    esac
    ;;
  kill-pane) printf '%s\n' "$*" >> "${KILL_LOG:-/dev/null}" ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

snapshot() {
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
    "IDENTITY_DIR=$IDENTITY_DIR" "$@" "$ROOT_DIR/bin/sgt-watch" --snapshot
}

# field <json> <python-expression-on-doc>
field() {
  printf '%s' "$1" | python3 -c 'import json,sys
doc=json.load(sys.stdin)
print(eval(sys.argv[1], {"d": doc, "repr": repr}))' "$2"
}

assert_valid_shape() {
  local json="$1" label="$2"
  printf '%s' "$json" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert set(doc) == {"schema", "observed_at", "scope", "busy", "basis"}, sorted(doc)
assert doc["schema"] == "sergeant.watch-status/v1", doc["schema"]
assert set(doc["scope"]) == {"kind", "task_id", "repo"}, sorted(doc["scope"])
assert doc["scope"]["kind"] in {"fleet", "task", "repo"}, doc["scope"]["kind"]
assert doc["basis"] in {"verified_active_witness", "no_verified_active_witness"}, doc["basis"]
assert doc["busy"] in (True, None), doc["busy"]
if doc["busy"] is True:
    assert doc["basis"] == "verified_active_witness", doc
else:
    assert doc["basis"] == "no_verified_active_witness", doc
import re
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", doc["observed_at"]), doc["observed_at"]
' || {
    printf '%s: invalid snapshot shape:\n%s\n' "$label" "$json" >&2
    exit 1
  }
}

# make_worker <name> <status> <pane> <activity>
make_worker() {
  local name="$1" status="$2" pane="$3" activity="$4"
  local task_dir state wt
  task_dir="$fleet/task-$name"
  state="$task_dir/app"
  wt="$TEST_ROOT/wt-$name"
  mkdir -p "$state" "$wt"
  printf 'Brief: snapshot %s\n' "$name" > "$task_dir/brief.md"
  printf '%s\n' "$wt" > "$state/worktree"
  printf '%s\n' "$status" > "$state/status"
  printf '%s\n' "$status" > "$wt/.sergeant-status"
  printf '%s\n' "$pane" > "$state/pane"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$IDENTITY_DIR/${pane#%}"
  printf '0|%s|4242|123456|worker\n' "$pane" > "$state/pane_identity"
  chmod 600 "$state/pane_identity"
  printf '%s\n' "$pane" >> "$LIVE_PANES"
  printf '%s\n' "$activity" > "$state/progress_ts"
  printf '%s %s\n' "$state" "$wt"
}

# ── 1. An empty fleet is a bounded null observation ───────────────────────────

json="$(snapshot)"
assert_valid_shape "$json" 'empty fleet'
[[ "$(field "$json" 'd["scope"]["kind"]')" == "fleet" ]]
[[ "$(field "$json" 'repr(d["scope"]["task_id"])')" == "None" ]]
[[ "$(field "$json" 'repr(d["scope"]["repo"])')" == "None" ]]
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]]
[[ "$(field "$json" 'd["basis"]')" == "no_verified_active_witness" ]]

# ── 2. --snapshot is strictly read-only ──────────────────────────────────────
# A worker whose worktree status disagrees with fleet state is exactly what
# --sync rewrites.  --snapshot must not, and must create no files at all.

read -r state wt <<<"$(make_worker readonly in_progress '%10' "$(date +%s)")"
printf 'done\n' > "$wt/.sergeant-status"
printf 'https://example.invalid/pr/1\n' > "$wt/.sergeant-result"

manifest_before="$(find "$fleet" "$wt" -printf '%p %s %T@\n' 2>/dev/null | sort)"
snapshot >/dev/null
manifest_after="$(find "$fleet" "$wt" -printf '%p %s %T@\n' 2>/dev/null | sort)"
[[ "$manifest_before" == "$manifest_after" ]] || {
  printf '--snapshot mutated state:\n%s\n' \
    "$(diff <(printf '%s\n' "$manifest_before") <(printf '%s\n' "$manifest_after") || true)" >&2
  exit 1
}
[[ "$(cat "$state/status")" == "in_progress" ]] || {
  printf '--snapshot reconciled the recorded status\n' >&2
  exit 1
}
[[ ! -e "$state/result" ]] || {
  printf '--snapshot copied a result into fleet state\n' >&2
  exit 1
}
# Repeat for task and repo scope: no scope may mutate.
manifest_before="$(find "$fleet" "$wt" -printf '%p %s %T@\n' 2>/dev/null | sort)"
snapshot >/dev/null <<<'' || true
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly >/dev/null
env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly \
  --repo app >/dev/null
manifest_after="$(find "$fleet" "$wt" -printf '%p %s %T@\n' 2>/dev/null | sort)"
[[ "$manifest_before" == "$manifest_after" ]] || {
  printf 'a scoped --snapshot mutated state:\n%s\n' \
    "$(diff <(printf '%s\n' "$manifest_before") <(printf '%s\n' "$manifest_after") || true)" >&2
  exit 1
}

# Restore agreement so this worker can serve as the verified witness below.
printf 'in_progress\n' > "$wt/.sergeant-status"
rm -f "$wt/.sergeant-result"

# ── 3. Task and repo scopes are reported ─────────────────────────────────────

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly)"
assert_valid_shape "$json" 'task scope'
[[ "$(field "$json" 'd["scope"]["kind"]')" == "task" ]]
[[ "$(field "$json" 'd["scope"]["task_id"]')" == "task-readonly" ]]
[[ "$(field "$json" 'repr(d["scope"]["repo"])')" == "None" ]]

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
assert_valid_shape "$json" 'repo scope'
[[ "$(field "$json" 'd["scope"]["kind"]')" == "repo" ]]
[[ "$(field "$json" 'd["scope"]["task_id"]')" == "task-readonly" ]]
[[ "$(field "$json" 'd["scope"]["repo"]')" == "app" ]]

# ── 4. busy requires status, identity and recent progress together ────────────

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
assert_valid_shape "$json" 'verified witness'
[[ "$(field "$json" 'repr(d["busy"])')" == "True" ]] || {
  printf 'a live identity-matched worker with recent progress was not reported busy:\n%s\n' \
    "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["basis"]')" == "verified_active_witness" ]]
# The fleet scope sees the same witness.
[[ "$(field "$(snapshot)" 'repr(d["busy"])')" == "True" ]]

# Stale progress alone removes the witness.
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$state/progress_ts"
json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
assert_valid_shape "$json" 'stale progress'
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]] || {
  printf 'stale progress still reported busy:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["basis"]')" == "no_verified_active_witness" ]]
printf '%s\n' "$(date +%s)" > "$state/progress_ts"

# An identity mismatch removes the witness.
printf '0|%%10|9999|777777|someone-else\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"
json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]] || {
  printf 'an identity mismatch still reported busy:\n%s\n' "$json" >&2
  exit 1
}
printf '0|%%10|4242|123456|worker\n' > "$state/pane_identity"
chmod 600 "$state/pane_identity"

# A dead pane removes the witness.
grep -v -x '%10' "$LIVE_PANES" > "$LIVE_PANES.tmp" || true
mv "$LIVE_PANES.tmp" "$LIVE_PANES"
json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]] || {
  printf 'a dead pane still reported busy:\n%s\n' "$json" >&2
  exit 1
}
printf '%%10\n' >> "$LIVE_PANES"

# A terminal status removes the witness even with a live identity-matched pane.
printf 'done\n' > "$state/status"
json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
  "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]] || {
  printf 'a terminal worker was reported busy:\n%s\n' "$json" >&2
  exit 1
}
printf 'in_progress\n' > "$state/status"

# Waiting states are not busy either: they are not doing work.
for status in needs_input blocked waiting orphaned drained; do
  printf '%s\n' "$status" > "$state/status"
  json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "LIVE_PANES=$LIVE_PANES" \
    "IDENTITY_DIR=$IDENTITY_DIR" "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo app)"
  [[ "$(field "$json" 'repr(d["busy"])')" == "None" ]] || {
    printf 'a %s worker was reported busy:\n%s\n' "$status" "$json" >&2
    exit 1
  }
done
printf 'in_progress\n' > "$state/status"

# ── 5. Version 1 never emits busy:false ──────────────────────────────────────

all_output="$(snapshot; env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "LIVE_PANES=$LIVE_PANES" "IDENTITY_DIR=$IDENTITY_DIR" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly)"
if printf '%s' "$all_output" | grep -q 'false'; then
  printf 'version 1 emitted busy:false:\n%s\n' "$all_output" >&2
  exit 1
fi

# ── 6. Output is constant-size and free of brief text ────────────────────────

huge="$(head -c 20000 /dev/zero | tr '\0' 'x')"
printf 'Brief: %s\n' "$huge" > "$fleet/task-readonly/brief.md"
for extra in $(seq 1 25); do
  read -r _ _ <<<"$(make_worker "bulk$extra" in_progress "%1$extra" "$(date +%s)")"
  printf 'Brief: %s\n' "$huge" > "$fleet/task-bulk$extra/brief.md"
done
json="$(snapshot)"
assert_valid_shape "$json" 'bounded output'
size="$(printf '%s' "$json" | wc -c | tr -d ' ')"
(( size <= 400 )) || {
  printf 'snapshot output is not bounded: %s bytes\n%s\n' "$size" "$json" >&2
  exit 1
}
if printf '%s' "$json" | grep -q 'xxxx'; then
  printf 'snapshot leaked free-form brief text\n' >&2
  exit 1
fi

# ── 7. An unknown task is an honest null observation, not an invention ───────

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot task-does-not-exist)"
assert_valid_shape "$json" 'unknown task'
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]]
[[ "$(field "$json" 'd["basis"]')" == "no_verified_active_witness" ]]
[[ "$(field "$json" 'd["scope"]["task_id"]')" == "task-does-not-exist" ]]

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot task-readonly --repo nosuchrepo)"
assert_valid_shape "$json" 'unknown repo'
[[ "$(field "$json" 'repr(d["busy"])')" == "None" ]]

# ── 8. A malformed scope is rejected before any observation ──────────────────

for bad in '../escape' 'has space' '' 'a/b'; do
  set +e
  bad_output="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
    "$ROOT_DIR/bin/sgt-watch" --snapshot "$bad" 2>&1)"
  bad_status=$?
  set -e
  [[ "$bad_status" -ne 0 ]] || {
    printf 'a malformed task id was accepted: %s\n' "$bad" >&2
    exit 1
  }
  if printf '%s' "$bad_output" | grep -q 'sergeant.watch-status'; then
    printf 'a malformed task id produced a snapshot: %s\n' "$bad" >&2
    exit 1
  fi
done

set +e
long_id="$(head -c 200 /dev/zero | tr '\0' 'a')"
long_status_output="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot "$long_id" 2>&1)"
long_status=$?
set -e
[[ "$long_status" -ne 0 ]] || {
  printf 'an unbounded task id was accepted, breaking output boundedness\n' >&2
  exit 1
}

# ── 9. --list no longer labels terminal records as active ────────────────────

printf 'done\n' > "$state/status"
list_output="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" \
  "$ROOT_DIR/bin/sgt-watch" --list)"
if printf '%s' "$list_output" | grep -q 'Active tasks:'; then
  printf '--list still labels retained terminal records as active:\n%s\n' \
    "$(printf '%s' "$list_output" | head -3)" >&2
  exit 1
fi

printf 'bounded read-only fleet snapshot: ok\n'
