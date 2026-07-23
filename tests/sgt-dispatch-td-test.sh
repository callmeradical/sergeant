#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
YQ_BIN="$(command -v yq)"
trap 'rm -rf "$TEST_ROOT"' EXIT

APP_MAIN_REPO="$TEST_ROOT/repo-main"
APP_REPO="$TEST_ROOT/repo"
API_REPO="$TEST_ROOT/api"
WEB_REPO="$TEST_ROOT/web"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config" "$TEST_ROOT/fake-bin" \
  "$TEST_ROOT/fleet" "$APP_MAIN_REPO" "$APP_REPO" "$API_REPO" "$WEB_REPO" \
  "$TEST_ROOT/td-active" "$TEST_ROOT/td-counter"
cp "$ROOT_DIR/bin/sgt-dispatch" "$ROOT_DIR/bin/_sgt-lib.sh" "$ROOT_DIR/bin/_sgt-bash-version.sh" \
  "$ROOT_DIR/bin/sgt-td-create" "$ROOT_DIR/bin/sgt-td-memory" "$TEST_ROOT/bin/"

cat > "$TEST_ROOT/config/test.yaml" <<EOF
name: test
repos:
  - name: app
    path: $APP_REPO
  - name: api
    path: $API_REPO
  - name: web
    path: $WEB_REPO
EOF

cat > "$TEST_ROOT/fake-bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
if [[ "${1:-}" == "new-window" ]]; then
  printf '%%42\n'
fi
exit 0
EOF
chmod +x "$TEST_ROOT/fake-bin/tmux"

cat > "$TEST_ROOT/fake-bin/td" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

mode="${TD_MODE:-success}"

if [[ "${1:-}" == "--version" ]]; then
  if [[ "${TD_VERSION_OUTPUT_SET:-0}" == "1" ]]; then
    printf '%s\n' "${TD_VERSION_OUTPUT:-}"
  elif [[ "$mode" == "wrong_td" || "$mode" == "wrong_version" ]]; then
    printf 'td version 1.4.2 (github.com/Swatto/td)\n'
  else
    printf 'td version v0.51.2\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  if [[ "$mode" == "wrong_td" ]]; then
    printf 'No help topic for create\n' >&2
    exit 1
  fi
  printf '%s\n' 'Usage: td create TITLE --description TEXT --priority P1 --json --work-dir DIR'
  exit 0
fi

work_dir=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir|-w)
      work_dir="$2"
      shift 2
      ;;
    --json)
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

set -- "${args[@]}"
cmd="${1:-}"
repo="$(basename "$work_dir")"
[[ "$repo" == "repo" ]] && repo="app"

next_task_id() {
  local repo_name="$1"
  local counter_file="$TD_COUNTER_DIR/$repo_name"
  local count=0
  [[ -f "$counter_file" ]] && count="$(cat "$counter_file")"
  count=$((count + 1))
  printf '%s\n' "$count" > "$counter_file"
  printf 'td-%s-%s\n' "$repo_name" "$count"
}

case "$cmd" in
  list)
    if [[ "$mode" == "uninitialized" ]]; then
      printf "database not found: run 'td init' first\n" >&2
      exit 1
    elif [[ "$mode" == "list_failure" ]]; then
      printf 'permission denied while opening database\n' >&2
      exit 1
    elif [[ "$mode" == "existing_td" ]]; then
      printf '[{"id":"td-existing","title":"Existing tracked work","description":"Keep existing behavior"}]\n'
    else
      printf '[]\n'
    fi
    ;;
  context)
    printf 'existing td lifecycle context\n'
    ;;
  create)
    title="${2:-}"
    description=""
    for ((i=1; i<${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--description" ]]; then
        description="${args[$((i + 1))]:-}"
      fi
    done
    printf '%s|%s|%s\n' "$mode" "$repo" "$title" >> "$TD_CREATE_LOG"
    printf '%s' "$description" > "$TD_DESCRIPTION_LOG"
    case "$mode" in
      fail_after_one)
        [[ "$repo" == "app" ]] || {
          printf 'create failed for %s\n' "$repo" >&2
          exit 11
        }
        ;;
      malformed_after_one)
        [[ "$repo" == "app" ]] || {
          printf '{not-json}\n'
          exit 0
        }
        ;;
      missing_id_after_one)
        [[ "$repo" == "app" ]] || {
          printf '{}\n'
          exit 0
        }
        ;;
      fail_after_two|delete_failure_after_two)
        [[ "$repo" != "web" ]] || {
          printf 'create failed for %s\n' "$repo" >&2
          exit 12
        }
        ;;
      existing_td)
        printf 'create should not run for existing td dispatch\n' >&2
        exit 91
        ;;
    esac
    task_id="$(next_task_id "$repo")"
    : > "$TD_ACTIVE_DIR/$task_id"
    printf '{"id":"%s"}\n' "$task_id"
    ;;
  delete)
    task_id="${2:-}"
    printf '%s|%s\n' "$mode" "$task_id" >> "$TD_DELETE_LOG"
    if [[ "$mode" == "delete_failure_after_two" ]]; then
      printf 'cleanup failed for %s\n' "$task_id" >&2
      exit 31
    fi
    rm -f "$TD_ACTIVE_DIR/$task_id"
    printf '{"id":"%s","deleted":true}\n' "$task_id"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_ROOT/fake-bin/td"

make_repo() {
  local repo_path="$1"
  git -C "$repo_path" init -q
  git -C "$repo_path" config user.name Test
  git -C "$repo_path" config user.email test@example.invalid
  touch "$repo_path/README.md"
  git -C "$repo_path" add README.md
  git -C "$repo_path" commit -qm fixture
}

dispatch_capture() {
  set +e
  output="$(PATH="$TEST_ROOT/fake-bin:$PATH" \
    TMUX_LOG="$TEST_ROOT/tmux.log" \
    TD_CREATE_LOG="$TEST_ROOT/td-create.log" \
    TD_DESCRIPTION_LOG="$TEST_ROOT/td-description.log" \
    TD_DELETE_LOG="$TEST_ROOT/td-delete.log" \
    TD_VERSION_OUTPUT_SET="${TD_VERSION_OUTPUT_SET:-0}" \
    TD_VERSION_OUTPUT="${TD_VERSION_OUTPUT:-}" \
    TD_ACTIVE_DIR="$TEST_ROOT/td-active" \
    TD_COUNTER_DIR="$TEST_ROOT/td-counter" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$TEST_ROOT/bin/sgt-dispatch" "$@" 2>&1)"
  status=$?
  set -e
}

dispatch_success() {
  PATH="$TEST_ROOT/fake-bin:$PATH" \
    TMUX_LOG="$TEST_ROOT/tmux.log" \
    TD_CREATE_LOG="$TEST_ROOT/td-create.log" \
    TD_DESCRIPTION_LOG="$TEST_ROOT/td-description.log" \
    TD_DELETE_LOG="$TEST_ROOT/td-delete.log" \
    TD_VERSION_OUTPUT_SET="${TD_VERSION_OUTPUT_SET:-0}" \
    TD_VERSION_OUTPUT="${TD_VERSION_OUTPUT:-}" \
    TD_ACTIVE_DIR="$TEST_ROOT/td-active" \
    TD_COUNTER_DIR="$TEST_ROOT/td-counter" \
    SERGEANT_CONFIG="$TEST_ROOT/config" \
    SERGEANT_FLEET="$TEST_ROOT/fleet" \
    SGT_WIKI_DISABLED=1 \
    "$TEST_ROOT/bin/sgt-dispatch" "$@" >/dev/null
}

task_dir_for() {
  local prefix="$1"
  printf '%s\n' "$TEST_ROOT"/fleet/"$prefix"-* | sed -n '1p'
}

make_repo "$APP_MAIN_REPO"
git -C "$APP_MAIN_REPO" branch -M main
git -C "$APP_MAIN_REPO" worktree add -q -b linked-worktree "$APP_REPO" HEAD
make_repo "$API_REPO"
make_repo "$WEB_REPO"
[[ -f "$APP_REPO/.git" ]] || {
  printf 'app fixture is not a linked git worktree\n' >&2
  exit 1
}

valid_td_versions=(
  'td version 0.51.0'
  'td version v0.51.2'
  '  td version 0.51.0  '
  'td version v0.52.0-rc.1'
  $'td version 0.51.0\n\nUpdate available: 0.51.0 → v0.51.2\nRun: go install -ldflags "-X main.Version=v0.51.2" github.com/marcus/td@v0.51.2'
)

valid_version_index=0
for version_output in "${valid_td_versions[@]}"; do
  valid_version_index=$((valid_version_index + 1))
  : > "$TEST_ROOT/tmux.log"
  : > "$TEST_ROOT/td-create.log"
  TD_VERSION_OUTPUT_SET=1 TD_VERSION_OUTPUT="$version_output" \
    dispatch_capture test "Accept Marcus td version $valid_version_index" --repos app
  [[ "$status" -eq 0 ]] || {
    printf 'dispatch rejected supported Marcus td version output %q:\n%s\n' "$version_output" "$output" >&2
    exit 1
  }
done

invalid_td_versions=(
  ''
  'td version 0.51'
  'td version 0.51.0--rc1'
  'td version latest'
  'version 0.51.0'
  $'BROKEN\ntd version 0.51.0'
  $'td version 0.51.0\nBROKEN'
)

for version_output in "${invalid_td_versions[@]}"; do
  : > "$TEST_ROOT/tmux.log"
  : > "$TEST_ROOT/td-create.log"
  TD_VERSION_OUTPUT_SET=1 TD_VERSION_OUTPUT="$version_output" \
    dispatch_capture test "Reject malformed td version" --repos app
  [[ "$status" -ne 0 ]] || {
    printf 'dispatch accepted malformed td version output %q\n' "$version_output" >&2
    exit 1
  }
  [[ "$output" == *"Unsupported td detected"* && "$output" == *"github.com/marcus/td"* ]] || {
    printf 'dispatch did not report an actionable malformed-version error for %q:\n%s\n' "$version_output" "$output" >&2
    exit 1
  }
  [[ ! -s "$TEST_ROOT/td-create.log" && ! -s "$TEST_ROOT/tmux.log" ]] || {
    printf 'dispatch mutated state with malformed td version output %q\n' "$version_output" >&2
    exit 1
  }
done

unset TD_VERSION_OUTPUT_SET TD_VERSION_OUTPUT

printf 'sgt-dispatch Marcus td version formats: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"

TD_MODE=wrong_td dispatch_capture test "Reject unrelated td" --repos app

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded with the unrelated td implementation\n' >&2
  exit 1
}
[[ "$output" == *"td version 1.4.2 (github.com/Swatto/td)"* ]] || {
  printf 'dispatch did not report the detected td implementation:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"github.com/marcus/td"* ]] || {
  printf 'dispatch did not report the required td implementation:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"brew install marcus/tap/td"* && "$output" == *"go install github.com/marcus/td@latest"* ]] || {
  printf 'dispatch did not report actionable Marcus td install commands:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td-create.log" && ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch mutated state with the unrelated td implementation\n' >&2
  exit 1
}

printf 'sgt-dispatch wrong td gate: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"

TD_MODE=wrong_version dispatch_capture test "Reject wrong td version" --repos app

[[ "$status" -ne 0 && "$output" == *"td version 1.4.2 (github.com/Swatto/td)"* ]] || {
  printf 'dispatch accepted a non-Marcus version despite compatible-looking help:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td-create.log" && ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch mutated state with an invalid td version\n' >&2
  exit 1
}

printf 'sgt-dispatch wrong td version gate: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"

TD_MODE=uninitialized dispatch_capture test "Require initialized storage" --repos app

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded with uninitialized td storage\n' >&2
  exit 1
}
[[ "$output" == *"td is not initialized in repo 'app' ($APP_REPO)"* ]] || {
  printf 'dispatch did not identify uninitialized td storage:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"td init --work-dir '$APP_REPO'"* ]] || {
  printf 'dispatch did not report the exact td initialization remedy:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/td-create.log" && ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch mutated state with uninitialized td storage\n' >&2
  exit 1
}

printf 'sgt-dispatch uninitialized td gate: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"

TD_MODE=list_failure dispatch_capture test "Report td storage failure" --repos app

[[ "$status" -ne 0 && "$output" == *"td prerequisite check failed"* && "$output" == *"permission denied while opening database"* ]] || {
  printf 'dispatch misreported a non-initialization td failure:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" != *"td init --work-dir"* ]] || {
  printf 'dispatch prescribed td init for a non-initialization failure:\n%s\n' "$output" >&2
  exit 1
}

printf 'sgt-dispatch td storage error classification: ok\n'

long_brief="$(printf 'Detailed mission %.0s' {1..20})"
: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-description.log"

dispatch_success test "$long_brief" --repos app

created_title="$(cut -d'|' -f3- "$TEST_ROOT/td-create.log")"
[[ "${#created_title}" -le 200 ]] || {
  printf 'dispatch generated a td title longer than 200 characters: %s\n' "${#created_title}" >&2
  exit 1
}
[[ "$created_title" == *"..." ]] || {
  printf 'dispatch did not mark the generated title as truncated: %s\n' "$created_title" >&2
  exit 1
}
[[ "$(cat "$TEST_ROOT/td-description.log")" == "$long_brief" ]] || {
  printf 'dispatch did not preserve the full brief as the td description\n' >&2
  exit 1
}
task_dir="$(task_dir_for detailed-mission)"
grep -Fq "$long_brief" "$(cat "$task_dir/app/worktree")/.sergeant-brief.md" || {
  printf 'dispatch did not preserve the full Sergeant brief\n' >&2
  exit 1
}

printf 'sgt-dispatch bounded generated title: ok\n'

cat > "$TEST_ROOT/bin/sgt-td-create" <<'EOF'
#!/usr/bin/env bash
printf 'td warning on stderr\n' >&2
printf '[{"repo":"app","task_id":"td-app-stderr"}]\n'
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"
: > "$TEST_ROOT/tmux.log"

dispatch_success test "Track stderr cleanly" --repos app

task_dir="$(task_dir_for track-stderr-cleanly)"
[[ -n "$task_dir" ]] || {
  printf 'dispatch with harmless stderr did not create fleet state\n' >&2
  exit 1
}
[[ "$(cat "$task_dir/app/td_task")" == "td-app-stderr" ]] || {
  printf 'dispatch lost td task id when helper wrote stderr\n' >&2
  exit 1
}
[[ "$(grep -c '^new-window ' "$TEST_ROOT/tmux.log")" -eq 1 ]] || {
  printf 'dispatch did not spawn exactly one worker for stderr success\n' >&2
  exit 1
}

printf 'sgt-dispatch stderr-safe td parsing: ok\n'

cp "$ROOT_DIR/bin/sgt-td-create" "$TEST_ROOT/bin/sgt-td-create"
: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

dispatch_success test "Create tracked work" --repos app,api

[[ "$(wc -l < "$TEST_ROOT/td-create.log")" -eq 2 ]] || {
  printf 'dispatch did not create one td task per selected repo\n' >&2
  exit 1
}
task_dir="$(task_dir_for create-tracked-work)"
for repo in app api; do
  repo_state="$task_dir/$repo"
  task_id="$(cat "$repo_state/td_task")"
  brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
  [[ "$task_id" == td-"$repo"-1 ]] || {
    printf 'dispatch recorded the wrong td task for %s\n' "$repo" >&2
    exit 1
  }
  grep -Fq "**td task:** $task_id" "$brief"
  grep -Fq "td start $task_id --work-dir ." "$brief"
  grep -Fq 'td log "message" --work-dir .' "$brief"
  grep -Fq "td handoff $task_id --work-dir ." "$brief"
  grep -Fq "td review $task_id --work-dir ." "$brief"
done
[[ "$(grep -c '^new-window ' "$TEST_ROOT/tmux.log")" -eq 2 ]] || {
  printf 'dispatch did not spawn one worker per selected repo\n' >&2
  exit 1
}

printf 'sgt-dispatch generated td tracking: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=malformed_after_one dispatch_capture test "Rollback malformed task output" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after malformed td create output\n' >&2
  exit 1
}
[[ "$output" == *"td create returned invalid JSON for api"* ]] || {
  printf 'dispatch did not report malformed td create output:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 1 ]] || {
  printf 'dispatch did not roll back the created td task after malformed output\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after malformed td create output\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'malformed td create output left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch malformed td rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=missing_id_after_one dispatch_capture test "Rollback missing task id" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after missing td create id\n' >&2
  exit 1
}
[[ "$output" == *"td create returned invalid JSON for api"* ]] || {
  printf 'dispatch did not report missing td create id:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 1 ]] || {
  printf 'dispatch did not roll back the created td task after missing id\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after missing td create id\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'missing td create id left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch missing-id td rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=fail_after_one dispatch_capture test "Rollback one created task" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after one repo td creation failed\n' >&2
  exit 1
}
[[ "$output" == *"td task creation failed"* ]] || {
  printf 'dispatch did not report td creation failure after one success:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"create failed for api"* ]] || {
  printf 'dispatch did not surface creator diagnostics for one-success rollback:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 1 ]] || {
  printf 'dispatch did not roll back the one created td task\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after one-success td rollback\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'rollback after one td creation failure left active cards behind\n' >&2
  exit 1
}

TD_MODE=success dispatch_success test "Rollback one created task retry" --repos app,api

[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 2 ]] || {
  printf 'retry after one-success rollback left duplicate active cards\n' >&2
  exit 1
}
[[ "$(grep -c '^fail_after_one|app|Rollback one created task$' "$TEST_ROOT/td-create.log")" -eq 1 ]] || {
  printf 'first attempt did not create the expected app card\n' >&2
  exit 1
}
[[ "$(grep -c '^success|app|Rollback one created task retry$' "$TEST_ROOT/td-create.log")" -eq 1 ]] || {
  printf 'retry did not create a fresh app card\n' >&2
  exit 1
}
[[ "$(grep -c '^success|api|Rollback one created task retry$' "$TEST_ROOT/td-create.log")" -eq 1 ]] || {
  printf 'retry did not create the api card\n' >&2
  exit 1
}

printf 'sgt-dispatch single-task rollback retry: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=fail_after_two dispatch_capture test "Rollback multiple created tasks" --repos app,api,web

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after multiple repo td creation failed\n' >&2
  exit 1
}
[[ "$output" == *"td task creation failed"* ]] || {
  printf 'dispatch did not report td creation failure after multiple successes:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"create failed for web"* ]] || {
  printf 'dispatch did not surface creator diagnostics for multi-success rollback:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back every created td task after multi-success failure\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after multi-success td rollback\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'rollback after multiple td creation failures left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch multi-task rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=delete_failure_after_two dispatch_capture test "Report cleanup failures" --repos app,api,web

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after td rollback cleanup failures\n' >&2
  exit 1
}
[[ "$output" == *"cleanup failed for td-app-1"* ]] || {
  printf 'dispatch did not report the first cleanup failure:\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" == *"cleanup failed for td-api-1"* ]] || {
  printf 'dispatch did not report the second cleanup failure:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not attempt every rollback delete when cleanup failed\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after cleanup failures\n' >&2
  exit 1
}

printf 'sgt-dispatch cleanup failure reporting: ok\n'

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
"$ROOT_DIR/bin/sgt-td-create" "\$@"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  printf '{not-json}\n'
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"
: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

TD_MODE=success dispatch_capture test "Reject invalid tracking" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after td result injection failed\n' >&2
  exit 1
}
[[ "$output" == *"failed to inject td task results"* ]] || {
  printf 'dispatch did not report td result injection failure:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after td result injection failure\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after td result injection failed\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'dispatch left active td cards after result injection failure\n' >&2
  exit 1
}

cp "$ROOT_DIR/bin/sgt-td-create" "$TEST_ROOT/bin/sgt-td-create"
TD_MODE=success dispatch_success test "Reject invalid tracking retry" --repos app,api

[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 2 ]] || {
  printf 'retry after td injection rollback left duplicate active cards\n' >&2
  exit 1
}

printf 'sgt-dispatch td injection rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
items[1]["repo"] = "app"
print(json.dumps(items))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject duplicate selected repo results" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after duplicate selected repo td results\n' >&2
  exit 1
}
[[ "$output" == *"duplicate td task result for repo: app"* ]] || {
  printf 'dispatch did not report duplicate selected repo td results:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after duplicate selected repo results\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after duplicate selected repo td results\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'duplicate selected repo td results left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch duplicate td result rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
items[1]["repo"] = "web"
print(json.dumps(items))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject unexpected repo results" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after unexpected repo td results\n' >&2
  exit 1
}
[[ "$output" == *"unexpected td task result for repo: web"* ]] || {
  printf 'dispatch did not report unexpected repo td results:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after unexpected repo td results\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after unexpected repo td results\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'unexpected repo td results left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch unexpected td result rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
print(json.dumps(items[:-1]))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject missing selected repo results" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after missing selected repo td results\n' >&2
  exit 1
}
[[ "$output" == *"missing td task for selected repo: api"* ]] || {
  printf 'dispatch did not report missing selected repo td results:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after missing selected repo td results\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after missing selected repo td results\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'missing selected repo td results left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch missing selected repo rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
items[1]["task_id"] = ""
print(json.dumps(items))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject empty task ids" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after empty td task ids\n' >&2
  exit 1
}
[[ "$output" == *"invalid td task id for repo: api"* ]] || {
  printf 'dispatch did not report empty td task ids:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after empty td task ids\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after empty td task ids\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'empty td task ids left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch empty td task id rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
items[1]["task_id"] = "td api 2"
print(json.dumps(items))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject whitespace task ids" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after whitespace td task ids\n' >&2
  exit 1
}
[[ "$output" == *"invalid td task id for repo: api"* ]] || {
  printf 'dispatch did not report whitespace td task ids:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after whitespace td task ids\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after whitespace td task ids\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'whitespace td task ids left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch whitespace td task id rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cat > "$TEST_ROOT/bin/sgt-td-create" <<EOF
#!/usr/bin/env bash
results="\$("$ROOT_DIR/bin/sgt-td-create" "\$@")"
status=\$?
if [[ "\$status" -eq 0 ]]; then
  RESULTS="\$results" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["RESULTS"])
items[1]["task_id"] = items[0]["task_id"]
print(json.dumps(items))
PY
fi
exit "\$status"
EOF
chmod +x "$TEST_ROOT/bin/sgt-td-create"

TD_MODE=success dispatch_capture test "Reject duplicate task ids" --repos app,api

[[ "$status" -ne 0 ]] || {
  printf 'dispatch succeeded after duplicate td task ids\n' >&2
  exit 1
}
[[ "$output" == *"duplicate td task id: td-app-1"* ]] || {
  printf 'dispatch did not report duplicate td task ids:\n%s\n' "$output" >&2
  exit 1
}
[[ "$(wc -l < "$TEST_ROOT/td-delete.log")" -eq 2 ]] || {
  printf 'dispatch did not roll back created tasks after duplicate td task ids\n' >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux after duplicate td task ids\n' >&2
  exit 1
}
[[ "$(find "$TEST_ROOT/td-active" -type f | wc -l)" -eq 0 ]] || {
  printf 'duplicate td task ids left active cards behind\n' >&2
  exit 1
}

printf 'sgt-dispatch duplicate td task id rollback: ok\n'

: > "$TEST_ROOT/tmux.log"
: > "$TEST_ROOT/td-create.log"
: > "$TEST_ROOT/td-delete.log"
rm -f "$TEST_ROOT"/td-active/* "$TEST_ROOT"/td-counter/*

cp "$ROOT_DIR/bin/sgt-td-create" "$TEST_ROOT/bin/sgt-td-create"
TD_MODE=existing_td dispatch_success test --td td-existing --repos app

task_dir="$(task_dir_for existing-tracked-work)"
repo_state="$task_dir/app"
brief="$(cat "$repo_state/worktree")/.sergeant-brief.md"
[[ "$(cat "$task_dir/td_task")" == 'td-existing' ]]
[[ "$(cat "$repo_state/td_task")" == 'td-existing' ]]
grep -Fq '**td task:** td-existing' "$brief"
grep -Fq 'existing td lifecycle context' "$brief"
[[ "$(grep -c '^new-window ' "$TEST_ROOT/tmux.log")" -eq 1 ]] || {
  printf 'existing td dispatch did not spawn exactly one worker\n' >&2
  exit 1
}

printf 'sgt-dispatch existing td compatibility: ok\n'

rm "$TEST_ROOT/fake-bin/td"
ln -s "$YQ_BIN" "$TEST_ROOT/fake-bin/yq"
: > "$TEST_ROOT/tmux.log"

set +e
output="$(PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin" \
  TMUX_LOG="$TEST_ROOT/tmux.log" \
  SERGEANT_CONFIG="$TEST_ROOT/config" \
  SERGEANT_FLEET="$TEST_ROOT/fleet" \
  SGT_WIKI_DISABLED=1 \
  "$TEST_ROOT/bin/sgt-dispatch" test "Require task tracking" --repos app 2>&1)"
status=$?
set -e

[[ "$status" -ne 0 ]] || {
  printf 'brief-only dispatch succeeded without td\n' >&2
  exit 1
}
[[ "$output" == *"td is missing"* && "$output" == *"github.com/marcus/td"* ]] || {
  printf 'dispatch did not report missing td requirement:\n%s\n' "$output" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/tmux.log" ]] || {
  printf 'dispatch spawned tmux without td tracking\n' >&2
  exit 1
}

printf 'sgt-dispatch missing td gate: ok\n'
