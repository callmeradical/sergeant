#!/usr/bin/env bash
# Tests for sgt-td-list: complete (non-truncated) reporting of every repo's
# non-closed tasks, correct per-repo counts and grand total, user-supplied
# limit precedence, and explicit truncation warnings instead of silent caps.
#
# Regression context: bin/sgt-td-list called `td list --json` with no limit, so
# td's default `--limit 50` silently capped every repo at 50 tasks and both the
# per-repo counts and the grand total under-reported real backlogs.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
REAL_PYTHON="$(command -v python3 || command -v python)"

home="$TEST_ROOT/home"
config="$TEST_ROOT/config"
dev_root="$TEST_ROOT/dev"
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$home" "$config" "$dev_root" "$fake_bin"

# ── Fixture repos ─────────────────────────────────────────────────────────────
# Each repo declares how many non-closed tasks its td database holds.  The fake
# td below emulates real td semantics: it honours --limit / -n and defaults to
# 50 when no limit is given.

_make_repo() {
  local name="$1" task_count="$2"
  mkdir -p "$dev_root/$name"
  git -C "$dev_root/$name" init --quiet
  printf '%s\n' "$task_count" > "$dev_root/$name/.td-task-count"
}

_make_repo big 60      # > td's default 50: the truncation case
_make_repo small 7
_make_repo huge 25     # used for the explicit-ceiling truncation warning case

# A repo with no td database at all: real td prints a JSON error object on
# stdout and exits 1 for these, so they must be skipped, not merged or fatal.
mkdir -p "$dev_root/nodb"
git -C "$dev_root/nodb" init --quiet

cat > "$config/config.yaml" <<EOF
dev_root: $dev_root
EOF

cat > "$config/example.yaml" <<EOF
name: example
repos:
  - name: big
    path: big
  - name: small
    path: small
EOF

cat > "$config/ceiling.yaml" <<EOF
name: ceiling
repos:
  - name: huge
    path: huge
EOF

cat > "$config/uninitialized.yaml" <<EOF
name: uninitialized
repos:
  - name: nodb
    path: nodb
  - name: big
    path: big
EOF

# ── Fake td ───────────────────────────────────────────────────────────────────
# Logs every invocation to $TEST_ROOT/td.log and emits a JSON array whose length
# is min(repo task count, effective limit), where the effective limit defaults
# to 50 exactly like real td (`-n, --limit int  Limit results (default 50)`).

cat > "$fake_bin/td" <<EOF
#!$REAL_PYTHON
import json
import os
import sys
from pathlib import Path

argv = sys.argv[1:]
with open("$TEST_ROOT/td.log", "a", encoding="utf-8") as fh:
    fh.write(" ".join(argv) + "\n")

if not argv or argv[0] not in ("list", "ls"):
    sys.exit(0)

work_dir = "."
limit = 50  # real td default
idx = 1
while idx < len(argv):
    arg = argv[idx]
    if arg == "--work-dir":
        work_dir = argv[idx + 1]
        idx += 2
    elif arg in ("--limit", "-n"):
        limit = int(argv[idx + 1])
        idx += 2
    elif arg.startswith("--limit="):
        limit = int(arg.split("=", 1)[1])
        idx += 1
    elif len(arg) > 2 and arg.startswith("-n") and arg[2:].isdigit():
        limit = int(arg[2:])
        idx += 1
    elif arg == "--filter":
        idx += 2
    else:
        idx += 1

fail_repo = os.environ.get("SGT_TD_LIST_TEST_FAIL_REPO", "")
if fail_repo and Path(work_dir).name == fail_repo:
    # Hard td failure: nothing usable on stdout, nonzero exit.
    sys.stderr.write("td: unexpected failure\n")
    sys.exit(2)

count_file = Path(work_dir) / ".td-task-count"
if not count_file.is_file():
    # Real td behaviour for a repo with no td database: JSON error object on
    # stdout, exit status 1.
    print(json.dumps({"error": {"code": "database_error",
                                "message": "database not found: run 'td init' first"}}))
    sys.exit(1)

total = int(count_file.read_text().strip())
emitted = min(total, limit) if limit >= 0 else total

tasks = [
    {
        "id": "td-%06d" % (n + 1),
        "title": "task %d" % (n + 1),
        "status": "open",
        "type": "bug",
        "priority": "P%d" % (n % 4),
    }
    for n in range(emitted)
]
print(json.dumps(tasks, indent=2))
EOF
chmod +x "$fake_bin/td"

# Wrapper that records every python3 process sgt-td-list launches.  The fake td
# above runs on an absolute interpreter path, so it is not counted here.
cat > "$fake_bin/python3" <<EOF
#!/usr/bin/env bash
printf 'python3\n' >> "$TEST_ROOT/python.log"
if [[ -n "\${SGT_TD_LIST_TEST_FAIL_PYTHON:-}" ]]; then
  _calls="\$(wc -l < "$TEST_ROOT/python.log" | tr -d ' ')"
  if [[ "\$_calls" == "\$SGT_TD_LIST_TEST_FAIL_PYTHON" ]]; then
    printf 'python3: simulated failure\n' >&2
    exit 1
  fi
fi
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$fake_bin/python3"

_run() {
  # _run <stdout-file> <stderr-file> [env assignments...] -- <args...>
  local out="$1" err="$2"; shift 2
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  local status=0
  env HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
    "${envs[@]+"${envs[@]}"}" \
    "$ROOT_DIR/bin/sgt-td-list" "$@" >"$out" 2>"$err" || status=$?
  return "$status"
}

_fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# ── 1. Human-readable path reports every task, not 50 ─────────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/human.out"; err="$TEST_ROOT/human.err"
_run "$out" "$err" -- example || _fail "human_no_truncation: sgt-td-list exited nonzero: $(cat "$err")"

grep -qF '── big (60)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "human_no_truncation: expected '── big (60)', repo was truncated"
}
grep -qF '── small (7)' "$out" || _fail "human_no_truncation: expected '── small (7)'"
grep -qF '67 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "human_total_matches_sum: expected '67 task(s) total'"
}
grep -qF 'td-000060' "$out" || _fail "human_no_truncation: 60th task missing from listing"
printf 'human_no_truncation: ok\n'
printf 'human_total_matches_sum: ok\n'

# No truncation warning should appear when nothing was truncated.
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "human_no_spurious_warning: expected empty stderr when nothing is truncated"
}
printf 'human_no_spurious_warning: ok\n'

# Every td invocation must carry an explicit limit above td's silent default.
while read -r line; do
  [[ "$line" == list* ]] || continue
  case "$line" in
    *--limit*|*" -n "*) ;;
    *) _fail "explicit_limit_passed: td invoked without an explicit limit: $line" ;;
  esac
done < "$TEST_ROOT/td.log"
printf 'explicit_limit_passed: ok\n'

# ── 2. JSON path reports every task ───────────────────────────────────────────

: > "$TEST_ROOT/td.log"
: > "$TEST_ROOT/python.log"
out="$TEST_ROOT/json.out"; err="$TEST_ROOT/json.err"
_run "$out" "$err" -- example --json || _fail "json_no_truncation: exited nonzero: $(cat "$err")"

json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")"
[[ "$json_count" == "67" ]] || {
  printf 'actual json count: %s\n' "$json_count" >&2
  _fail "json_no_truncation: expected 67 tagged tasks, got $json_count"
}
printf 'json_no_truncation: ok\n'

# Every task must carry its owning repo, with the per-repo split intact.
json_tags="$("$REAL_PYTHON" - "$out" <<'PY'
import collections, json, sys
tasks = json.load(open(sys.argv[1]))
counts = collections.Counter(t.get("_repo") for t in tasks)
print(" ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)))
PY
)"
[[ "$json_tags" == "big=60 small=7" ]] || {
  printf 'actual repo tags: %s\n' "$json_tags" >&2
  _fail "json_repo_tagging: expected 'big=60 small=7'"
}
printf 'json_repo_tagging: ok\n'

# Tagging and merging happen in one pass over staged payloads (audit finding
# P-2): at most one python3 process per repo plus one merge.
python_calls="$(wc -l < "$TEST_ROOT/python.log" | tr -d ' ')"
[[ "$python_calls" -le 3 ]] || {
  _fail "json_single_merge_pass: expected at most 3 python3 processes for 2 repos, got $python_calls"
}
printf 'json_single_merge_pass: ok (%s python3 processes for 2 repos)\n' "$python_calls"

# ── 3. A user-supplied limit still wins ───────────────────────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/userlimit.out"; err="$TEST_ROOT/userlimit.err"
_run "$out" "$err" -- example --repos big --limit 5 \
  || _fail "user_limit_wins: exited nonzero: $(cat "$err")"

grep -qF '── big (5)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "user_limit_wins: expected '── big (5)' when the user asks for --limit 5"
}
grep -qF -- '--limit 5' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "user_limit_wins: user --limit 5 was not forwarded to td"
}
# The default must not be injected alongside the user's limit.
[[ "$(grep -c -- '--limit' "$TEST_ROOT/td.log")" == "$(grep -c -- '--limit 5' "$TEST_ROOT/td.log")" ]] || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "user_limit_wins: a default limit was injected alongside the user-supplied --limit"
}
printf 'user_limit_wins: ok\n'

# A user-supplied limit that truncates must still say so out loud.
if ! grep -qiF 'big' "$err" || ! grep -qi 'truncat' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "user_limit_truncation_warning: expected an explicit truncation warning naming 'big'"
fi
printf 'user_limit_truncation_warning: ok\n'

# ── 4. A retained ceiling warns explicitly instead of truncating silently ──────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/ceiling.out"; err="$TEST_ROOT/ceiling.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 SGT_TD_LIST_MAX_LIMIT=10 -- ceiling \
  || _fail "ceiling_warning: exited nonzero: $(cat "$err")"

if ! grep -qiF 'huge' "$err" || ! grep -qi 'truncat' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "ceiling_warning: expected a truncation warning naming 'huge' and the count"
fi
grep -qF 'at least 11 task(s)' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "ceiling_warning: warning must report the proven lower bound, not an unverified count"
}
printf 'ceiling_warning: ok\n'

# Warnings must never corrupt the machine-readable contract.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/ceiling-json.out"; err="$TEST_ROOT/ceiling-json.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 SGT_TD_LIST_MAX_LIMIT=10 -- ceiling --json \
  || _fail "ceiling_json_stdout_clean: exited nonzero: $(cat "$err")"
"$REAL_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" \
  || { printf 'actual stdout:\n%s\n' "$(cat "$out")" >&2
       _fail "ceiling_json_stdout_clean: --json stdout must stay valid JSON"; }
grep -qi 'truncat' "$err" || _fail "ceiling_json_stdout_clean: warning must go to stderr"
printf 'ceiling_json_stdout_clean: ok\n'

# ── 5. Escalation reaches repos larger than the initial page size ──────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/escalate.out"; err="$TEST_ROOT/escalate.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 -- ceiling \
  || _fail "escalates_past_initial_limit: exited nonzero: $(cat "$err")"

grep -qF '── huge (25)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "escalates_past_initial_limit: expected all 25 tasks with SGT_TD_LIST_LIMIT=10"
}
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "escalates_past_initial_limit: escalation that succeeds must not warn"
}
printf 'escalates_past_initial_limit: ok\n'

# ── 6. Repos without a td database are skipped, not fatal, not counted ────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nodb.out"; err="$TEST_ROOT/nodb.err"
_run "$out" "$err" -- uninitialized \
  || _fail "uninitialized_repo_skipped: exited nonzero: $(cat "$err")"

grep -qF '── big (60)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "uninitialized_repo_skipped: initialized repo must still be reported completely"
}
grep -qF '60 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "uninitialized_repo_skipped: total must count only real tasks"
}
! grep -qF 'nodb (' "$out" || _fail "uninitialized_repo_skipped: nodb must not be listed"
! grep -qi 'database_error' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "uninitialized_repo_skipped: td error payload leaked into output"
}
# A repo that simply has no td database is an expected skip, not a warning.
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "uninitialized_repo_skipped: an uninitialized repo must not produce warnings"
}
printf 'uninitialized_repo_skipped: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nodb-json.out"; err="$TEST_ROOT/nodb-json.err"
_run "$out" "$err" -- uninitialized --json \
  || _fail "uninitialized_repo_json: exited nonzero: $(cat "$err")"

json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")" \
  || _fail "uninitialized_repo_json: stdout was not valid JSON"
[[ "$json_count" == "60" ]] || {
  printf 'actual json count: %s\n' "$json_count" >&2
  _fail "uninitialized_repo_json: expected 60 tasks, got $json_count"
}
printf 'uninitialized_repo_json: ok\n'

# ── 7. A hard td failure is reported, never a silently dropped repo ───────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/tdfail.out"; err="$TEST_ROOT/tdfail.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_REPO=big -- example \
  || _fail "td_failure_warns: sgt-td-list must still report the other repos: $(cat "$err")"

grep -qF '── small (7)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "td_failure_warns: healthy repos must still be reported"
}
! grep -qF '── big (' "$out" || _fail "td_failure_warns: failed repo must not report a bogus count"
if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "td_failure_warns: expected a warning naming the failed repo 'big'"
fi
printf 'td_failure_warns: ok\n'

# ── 8. A dangling --limit is the caller's, and is not silently supplemented ────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/dangling.out"; err="$TEST_ROOT/dangling.err"
_run "$out" "$err" -- example --repos big --limit || true
! grep -qE -- '--limit[[:space:]]+--limit' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "dangling_limit_not_supplemented: must not inject a default beside a caller --limit"
}
printf 'dangling_limit_not_supplemented: ok\n'

# ── 9. A caller limit that withholds nothing must not warn ────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/exact.out"; err="$TEST_ROOT/exact.err"
_run "$out" "$err" -- example --repos small --limit 7 \
  || _fail "exact_limit_no_warning: exited nonzero: $(cat "$err")"

grep -qF '── small (7)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "exact_limit_no_warning: expected all 7 tasks"
}
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "exact_limit_no_warning: --limit 7 on a 7-task repo withholds nothing, so it must not warn"
}
printf 'exact_limit_no_warning: ok\n'

# A caller limit that does withhold tasks reports a proven lower bound.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/lower.out"; err="$TEST_ROOT/lower.err"
_run "$out" "$err" -- example --repos small --limit 3 \
  || _fail "caller_limit_lower_bound: exited nonzero: $(cat "$err")"
grep -qF '── small (3)' "$out" || _fail "caller_limit_lower_bound: caller limit must still win"
grep -qF 'at least 4 task(s)' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "caller_limit_lower_bound: warning must state the proven lower bound"
}
printf 'caller_limit_lower_bound: ok\n'

# ── 10. Every caller limit spelling wins and is never supplemented ────────────

for spelling in "--limit=5" "-n5"; do
  : > "$TEST_ROOT/td.log"
  out="$TEST_ROOT/spelling.out"; err="$TEST_ROOT/spelling.err"
  _run "$out" "$err" -- example --repos big "$spelling" \
    || _fail "caller_limit_spellings: $spelling exited nonzero: $(cat "$err")"
  grep -qF '── big (5)' "$out" || {
    printf 'actual output:\n%s\n' "$(cat "$out")" >&2
    _fail "caller_limit_spellings: $spelling must cap the report at 5"
  }
  grep -qF -- "$spelling" "$TEST_ROOT/td.log" || {
    printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
    _fail "caller_limit_spellings: $spelling was not forwarded to td"
  }
  if ! grep -qiF 'big' "$err" || ! grep -qi 'truncat' "$err"; then
    printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
    _fail "caller_limit_spellings: $spelling truncated 60 tasks without warning"
  fi
  printf 'caller_limit_spellings(%s): ok\n' "$spelling"
done

# ── 11. Unreadable task output is reported, never counted as zero ─────────────

# The first python3 process parses the first repo's td output.  When it fails,
# the repo must be named on stderr rather than silently reported as empty.
: > "$TEST_ROOT/td.log"; : > "$TEST_ROOT/python.log"
out="$TEST_ROOT/parsefail.out"; err="$TEST_ROOT/parsefail.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_PYTHON=1 -- example \
  || _fail "parse_failure_warns: exited nonzero: $(cat "$err")"

if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "parse_failure_warns: expected a warning naming the unreadable repo 'big'"
fi
! grep -qF '── big (0)' "$out" || _fail "parse_failure_warns: unreadable repo must not be reported as zero"
grep -qF '── small (7)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "parse_failure_warns: healthy repos must still be reported"
}
printf 'parse_failure_warns: ok\n'

# A failing renderer must not leave a per-repo header with no rows beneath it.
: > "$TEST_ROOT/td.log"; : > "$TEST_ROOT/python.log"
out="$TEST_ROOT/renderfail.out"; err="$TEST_ROOT/renderfail.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_PYTHON=2 -- example --repos big \
  || _fail "render_failure_warns: exited nonzero: $(cat "$err")"
if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "render_failure_warns: a failed listing render must warn and name the repo"
fi
printf 'render_failure_warns: ok\n'

# ── 12. --json keeps its contract when a repo fails hard ─────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/jsonfail.out"; err="$TEST_ROOT/jsonfail.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_REPO=big -- example --json \
  || _fail "json_failure_warns: exited nonzero: $(cat "$err")"

json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")" \
  || _fail "json_failure_warns: stdout must stay valid JSON when a repo fails"
[[ "$json_count" == "7" ]] || {
  printf 'actual json count: %s\n' "$json_count" >&2
  _fail "json_failure_warns: expected the healthy repo's 7 tasks, got $json_count"
}
if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "json_failure_warns: expected a warning naming the failed repo on stderr"
fi
printf 'json_failure_warns: ok\n'

printf '\nAll sgt-td-list tests passed.\n'
