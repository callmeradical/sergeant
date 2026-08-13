#!/usr/bin/env bash
# Regression for the bounded status-query extension to --snapshot (GH #207).
#
# sgt-watch --snapshot already answers "is Sergeant verifiably doing work right
# now?" for a fleet task id, but a caller holding a registered project name or a
# td task/epic id had no bounded, machine-readable way to resolve that identifier
# to fleet evidence. Worse, an unknown or wrong-namespace identifier produced the
# exact same busy:null / no_verified_active_witness shape as a legitimate,
# inconclusive fleet observation — indistinguishable from "idle".
#
# --snapshot --project <project> [--td <id>] must:
#   - make an unresolved project or td id explicit (fleet:null), never shaped
#     like an idle fleet;
#   - keep busy:null inconclusive (never busy:false) exactly like v1;
#   - keep project config / repo git state in a project_state object that is
#     never fleet or coordinator evidence;
#   - only report coordinator.verified:true from an exactly-identified,
#     ownership-marked, recently active tmux pane, and always keep
#     coordinator.queried:false with an explicit reason, because this version
#     never performs a live ask/answer round-trip.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

command -v yq >/dev/null 2>&1 || {
  printf 'sgt-watch --snapshot --project: skipped (yq unavailable)\n'
  exit 0
}

fleet="$TEST_ROOT/fleet"
config="$TEST_ROOT/config"
fake_bin="$TEST_ROOT/fake-bin"
td_fixture="$TEST_ROOT/td-fixture"
mkdir -p "$fleet" "$config" "$fake_bin" "$td_fixture"

export LIVE_PANES="$TEST_ROOT/live-panes"
export IDENTITY_DIR="$TEST_ROOT/identities"
mkdir -p "$IDENTITY_DIR"
: > "$LIVE_PANES"

# ── Fake tmux: liveness table + pane identity + coordinator marker option ────
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
  list-panes)
    if [[ "$*" == *"sgt-coordinator"* ]]; then
      if [[ -n "${MANAGED_PANES:-}" ]]; then
        printf '%s\n' ${MANAGED_PANES}
      fi
    fi
    ;;
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
      '#{pane_id}|#{pane_activity}|#{window_activity}|#{window_panes}')
        # Multi-field display-message used by _snapshot_recent_tmux_activity.
        printf '%s|%s|%s|%s\n' "$target" "${PANE_ACTIVITY:-0}" \
          "${WINDOW_ACTIVITY:-0}" "${WINDOW_PANES:-1}" ;;
      '#{@sgt_coordinator}')
        if [[ "$target" == "${COORDINATOR_PANE:-}" ]]; then
          printf '%s\n' "${COORDINATOR_MARKER:-}"
        fi
        ;;
      *)
        if [[ -s "$IDENTITY_DIR/${target#%}" ]]; then
          cat "$IDENTITY_DIR/${target#%}"
        else
          printf '0|%s|4242|123456|worker\n' "$target"
        fi
        ;;
    esac
    ;;
esac
TMUX
chmod +x "$fake_bin/tmux"

# ── Fake td: repo-scoped fixture-backed "show" and "list --epic" ────────────
cat > "$fake_bin/td" <<'TD'
#!/usr/bin/env bash
set -euo pipefail
work_dir=""
epic_id=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w) work_dir="$2"; shift 2 ;;
    --json) shift ;;
    --all) shift ;;
    --epic) epic_id="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
repo="$(basename "$work_dir")"
cmd="${args[0]:-}"
case "$cmd" in
  show)
    id="${args[1]:-}"
    fixture="$TD_FIXTURE_DIR/$repo/issues/$id"
    if [[ -f "$fixture" ]]; then
      IFS=$'\t' read -r type status < "$fixture"
      printf '{"id":"%s","type":"%s","status":"%s"}\n' "$id" "$type" "$status"
      exit 0
    fi
    printf '{"error":{"code":"not_found","message":"issue not found: %s"}}\n' "$id"
    exit 1
    ;;
  list)
    fixture="$TD_FIXTURE_DIR/$repo/epics/$epic_id"
    printf '['
    first=1
    if [[ -f "$fixture" ]]; then
      while IFS= read -r did; do
        [[ -z "$did" ]] && continue
        [[ $first -eq 1 ]] || printf ','
        printf '{"id":"%s"}' "$did"
        first=0
      done < "$fixture"
    fi
    printf ']\n'
    ;;
  *) exit 1 ;;
esac
TD
chmod +x "$fake_bin/td"

repo_a="$TEST_ROOT/repo-a"
repo_b="$TEST_ROOT/repo-b"
mkdir -p "$repo_a/.git" "$repo_b/.git" \
  "$td_fixture/repo-a/issues" "$td_fixture/repo-a/epics" \
  "$td_fixture/repo-b/issues"

git -C "$repo_a" init -q -b main . 2>/dev/null || true
git -C "$repo_a" config user.email t@example.invalid 2>/dev/null || true
git -C "$repo_a" config user.name t 2>/dev/null || true
printf 'x\n' > "$repo_a/f.txt"
git -C "$repo_a" add f.txt >/dev/null 2>&1 || true
git -C "$repo_a" commit -qm init >/dev/null 2>&1 || true
git -C "$repo_a" checkout -qb feature/demo >/dev/null 2>&1 || true

cat > "$config/proj.yaml" <<EOF
name: proj
repos:
  - name: repo-a
    path: $repo_a
  - name: repo-b
    path: $repo_b
EOF

run() {
  env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "SERGEANT_CONFIG=$config" \
    "LIVE_PANES=$LIVE_PANES" "IDENTITY_DIR=$IDENTITY_DIR" "TD_FIXTURE_DIR=$td_fixture" \
    "$ROOT_DIR/bin/sgt-watch" --snapshot --project proj "$@"
}

field() {
  printf '%s' "$1" | python3 -c 'import json,sys
doc=json.load(sys.stdin)
print(eval(sys.argv[1], {"d": doc, "repr": repr}))' "$2"
}

# make_fleet_repo <fleet-task> <repo-name> <status> [td-task-id] [pane] [activity-ts]
make_fleet_repo() {
  local task="$1" repo="$2" status="$3" td_task="${4:-}" pane="${5:-}" ts="${6:-}"
  local dir="$fleet/$task/$repo"
  mkdir -p "$dir"
  printf '%s\n' "$status" > "$dir/status"
  [[ -z "$td_task" ]] || printf '%s\n' "$td_task" > "$dir/td_task"
  if [[ -n "$pane" ]]; then
    printf '%s\n' "$pane" > "$dir/pane"
    printf '0|%s|4242|123456|worker\n' "$pane" > "$IDENTITY_DIR/${pane#%}"
    printf '0|%s|4242|123456|worker\n' "$pane" > "$dir/pane_identity"
    chmod 600 "$dir/pane_identity"
    printf '%s\n' "$pane" >> "$LIVE_PANES"
  fi
  if [[ -n "$ts" ]]; then
    printf '%s\n' "$ts" > "$dir/progress_ts"
    # Write a durable activity_witness for the new _snapshot_recent_durable_witness
    # path introduced in GH#206. Without this, an in_progress+pane setup without
    # a recent pane_activity cannot be verified as an active witness.
    if [[ -n "${pane:-}" ]]; then
      _ident="$(cat "$dir/pane_identity" 2>/dev/null || true)"
      printf 'version=1\nkind=transition\nobserved_at=%s\npane=%s\npane_identity=%s\nsubject_pid=\nsubject_identity=\n' \
        "$ts" "$pane" "$_ident" > "$dir/activity_witness"
      chmod 600 "$dir/activity_witness"
    fi
  fi
}

assert_common_shape() {
  local json="$1" label="$2"
  printf '%s' "$json" | python3 -c '
import json, re, sys
doc = json.load(sys.stdin)
assert doc["schema"] == "sergeant.status-query/v1", doc["schema"]
assert set(doc) == {"schema","observed_at","scope","resolved","namespace","reason","fleet","project_state","coordinator"}, sorted(doc)
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", doc["observed_at"]), doc["observed_at"]
assert doc["resolved"] in (True, False)
if doc["fleet"] is not None:
    assert doc["fleet"]["busy"] in (True, None), doc["fleet"]
    if doc["fleet"]["busy"] is True:
        assert doc["fleet"]["basis"] == "verified_active_witness", doc["fleet"]
    else:
        assert doc["fleet"]["basis"] == "no_verified_active_witness", doc["fleet"]
    assert "branch" not in doc["fleet"], "fleet leaked git metadata: " + repr(doc["fleet"])
if doc["project_state"] is not None:
    assert "busy" not in doc["project_state"], "project_state leaked fleet evidence: " + repr(doc["project_state"])
if doc["coordinator"] is not None:
    assert doc["coordinator"]["queried"] is False, "coordinator.queried must stay false: " + repr(doc["coordinator"])
' || { printf '%s: invalid status-query shape:\n%s\n' "$label" "$json" >&2; exit 1; }
}

# ── 1. Unknown project is explicit, never shaped like idle fleet evidence ────

json="$(env "PATH=$fake_bin:$PATH" "SERGEANT_FLEET=$fleet" "SERGEANT_CONFIG=$config" \
  "$ROOT_DIR/bin/sgt-watch" --snapshot --project does-not-exist)"
assert_common_shape "$json" 'unknown project'
[[ "$(field "$json" 'd["resolved"]')" == "False" ]]
[[ "$(field "$json" 'd["namespace"]')" == "unknown" ]]
[[ "$(field "$json" 'd["reason"]')" == "project_not_found" ]]
[[ "$(field "$json" 'repr(d["fleet"])')" == "None" ]] || {
  printf 'an unknown project must not carry any fleet evidence shape:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'repr(d["project_state"])')" == "None" ]]
[[ "$(field "$json" 'repr(d["coordinator"])')" == "None" ]]

# ── 2. Known project, no --td: project-scoped fleet + git state, separated ──

make_fleet_repo task1 repo-a in_progress "" '%50' "$(date +%s)"

json="$(run)"
assert_common_shape "$json" 'known project, no td'
[[ "$(field "$json" 'd["resolved"]')" == "True" ]]
[[ "$(field "$json" 'd["namespace"]')" == "project" ]]
[[ "$(field "$json" 'd["reason"]')" == "ok" ]]
[[ "$(field "$json" 'repr(d["fleet"]["busy"])')" == "True" ]] || {
  printf 'a verified in_progress witness in the project scope was not busy:true:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["project_state"]["name"]')" == "proj" ]]
branch="$(field "$json" 'json.dumps([r for r in d["project_state"]["repos"] if r["name"]=="repo-a"][0]["branch"])' 2>/dev/null || true)"
[[ -z "$branch" ]] && branch="$(printf '%s' "$json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=[x for x in d["project_state"]["repos"] if x["name"]=="repo-a"][0]
print(r["branch"])')"
[[ "$branch" == "feature/demo" ]] || {
  printf 'expected project_state branch feature/demo, got %s:\n%s\n' "$branch" "$json" >&2
  exit 1
}
cloned_b="$(printf '%s' "$json" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=[x for x in d["project_state"]["repos"] if x["name"]=="repo-b"][0]
print(r["cloned"])')"
[[ "$cloned_b" == "False" ]] || {
  printf 'repo-b has no .git worktree and should be reported as not cloned:\n%s\n' "$json" >&2
  exit 1
}

# ── 3. busy:null stays inconclusive for a terminal-only matched fleet record ─

rm -rf "$fleet"; mkdir -p "$fleet"
: > "$LIVE_PANES"
make_fleet_repo task2 repo-a done
json="$(run)"
assert_common_shape "$json" 'terminal-only project fleet'
[[ "$(field "$json" 'repr(d["fleet"]["busy"])')" == "None" ]] || {
  printf 'a terminal-only fleet record must stay busy:null, not busy:false:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["fleet"]["basis"]')" == "no_verified_active_witness" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["terminal"]')" == "1" ]]
# busy must never appear as the literal false (only null/true); cloned:false is
# an expected schema value for an uncloned repo, so we target the busy field.
if printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["fleet"]["busy"] is not False, "busy emitted false"' 2>/dev/null; then
  : # ok
else
  printf 'status-query emitted busy:false (must be null or true):\n%s\n' "$json" >&2
  exit 1
fi

# ── 4. An unknown td id is explicit and distinct from an empty fleet result ──

json="$(run --td td-does-not-exist)"
assert_common_shape "$json" 'unknown td id'
[[ "$(field "$json" 'd["resolved"]')" == "False" ]]
[[ "$(field "$json" 'd["namespace"]')" == "unknown" ]]
[[ "$(field "$json" 'd["reason"]')" == "td_id_not_found" ]]
[[ "$(field "$json" 'repr(d["fleet"])')" == "None" ]] || {
  printf 'an unknown td id must not carry any fleet evidence shape:\n%s\n' "$json" >&2
  exit 1
}
# The project itself is still valid, so project_state must still be reported.
[[ "$(field "$json" 'd["project_state"]["name"]')" == "proj" ]]

# ── 5. A td epic resolves its descendants' fleet records, scoped by project ──

printf 'epic\topen\n' > "$td_fixture/repo-a/issues/td-epic1"
printf 'task\topen\n' > "$td_fixture/repo-a/issues/td-child1"
printf 'td-child1\n' > "$td_fixture/repo-a/epics/td-epic1"

rm -rf "$fleet"; mkdir -p "$fleet"
: > "$LIVE_PANES"
make_fleet_repo task3 repo-a needs_input td-child1
make_fleet_repo task4 repo-a blocked td-child1
make_fleet_repo task5 repo-a waiting td-child1
make_fleet_repo task6 repo-a done td-child1
# Wrong-project noise: same td id happens to appear under a repo name that is
# not part of this project's repo list, and must never be counted.
make_fleet_repo task7 repo-outside-project needs_input td-child1

json="$(run --td td-epic1)"
assert_common_shape "$json" 'td epic descendants'
[[ "$(field "$json" 'd["resolved"]')" == "True" ]]
[[ "$(field "$json" 'd["namespace"]')" == "td_epic" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["needs_input"]')" == "1" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["blocked"]')" == "1" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["waiting"]')" == "1" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["terminal"]')" == "1" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["total"]')" == "4" ]] || {
  printf 'expected exactly 4 project-owned matched fleet records (5th is wrong-repo noise):\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'repr(d["fleet"]["busy"])')" == "None" ]]

# A plain (non-epic) td id resolves to its own fleet records as td_task.
rm -rf "$fleet"; mkdir -p "$fleet"
: > "$LIVE_PANES"
make_fleet_repo task8 repo-a needs_input td-child1
json="$(run --td td-child1)"
assert_common_shape "$json" 'plain td task'
[[ "$(field "$json" 'd["namespace"]')" == "td_task" ]]
[[ "$(field "$json" 'd["fleet"]["totals"]["needs_input"]')" == "1" ]]

# ── 6. Coordinator: unverifiable pane is explicit, never a fabricated answer ─

json="$(run)"
[[ "$(field "$json" 'd["coordinator"]["verified"]')" == "False" ]]
[[ "$(field "$json" 'd["coordinator"]["queried"]')" == "False" ]]
[[ "$(field "$json" 'd["coordinator"]["reason"]')" == "no_managed_coordinator_pane" ]]
[[ "$(field "$json" 'repr(d["coordinator"]["pane"])')" == "None" ]]

# ── 7. Coordinator: an exactly-identified, ownership-marked, recently active
#      pane is verified — but still never claims a response was obtained ─────

export MANAGED_PANES='%77'
export COORDINATOR_PANE='%77'
export COORDINATOR_MARKER='sergeant-managed-coordinator'
export PANE_ACTIVITY="$(date +%s)"
printf '%%77\n' >> "$LIVE_PANES"

json="$(run)"
[[ "$(field "$json" 'd["coordinator"]["verified"]')" == "True" ]] || {
  printf 'an exactly-identified, marked, recently active pane was not verified:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["coordinator"]["queried"]')" == "False" ]] || {
  printf 'verified coordinator evidence must never imply a request/response round-trip:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["coordinator"]["pane"]')" == "%77" ]]
[[ "$(field "$json" 'd["coordinator"]["reason"]')" != "" ]]

# A stale heartbeat on an otherwise-identified pane must not be verified.
export PANE_ACTIVITY="$(( $(date +%s) - 99999 ))"
json="$(run)"
[[ "$(field "$json" 'd["coordinator"]["verified"]')" == "False" ]] || {
  printf 'a stale coordinator heartbeat must not verify:\n%s\n' "$json" >&2
  exit 1
}
[[ "$(field "$json" 'd["coordinator"]["reason"]')" == "coordinator_pane_heartbeat_stale" ]]
unset MANAGED_PANES COORDINATOR_PANE COORDINATOR_MARKER PANE_ACTIVITY

# ── 8. td unavailable is explicit, not silently absorbed into "unknown" ─────

rm -f "$fake_bin/td"
json="$(run --td td-child1)"
assert_common_shape "$json" 'td unavailable'
[[ "$(field "$json" 'd["reason"]')" == "td_unavailable" ]]
[[ "$(field "$json" 'repr(d["fleet"])')" == "None" ]]

# ── 9. --snapshot --project is read-only ─────────────────────────────────────

manifest_before="$(find "$fleet" "$config" -printf '%p %s %T@\n' 2>/dev/null | sort)"
run >/dev/null
manifest_after="$(find "$fleet" "$config" -printf '%p %s %T@\n' 2>/dev/null | sort)"
[[ "$manifest_before" == "$manifest_after" ]] || {
  printf '--snapshot --project mutated state:\n%s\n' \
    "$(diff <(printf '%s\n' "$manifest_before") <(printf '%s\n' "$manifest_after") || true)" >&2
  exit 1
}

printf 'bounded status-query --snapshot --project extension: ok\n'
