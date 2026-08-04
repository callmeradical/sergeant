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

# A repo whose td database exists but cannot be opened.  Real td reports this
# with the same database_error code as an absent database, so only the absent
# case may be skipped quietly.
_make_repo corrupt 9
printf 'locked\n' > "$dev_root/corrupt/.td-unopenable"

# A linked git worktree: .git is a FILE here, so a `-d .git` test would drop it
# even though git and td both treat it as a checkout.  sgt-dispatch creates
# these, so a dropped worktree is a real under-reporting path.
git -C "$dev_root/big" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$dev_root/big" worktree add --quiet -b wt-branch "$dev_root/bigwt"
printf '11\n' > "$dev_root/bigwt/.td-task-count"

# A repo whose name contains quotes and yq operators.  Interpolating it into a
# yq expression used to resolve a different repo's path.
_make_repo quoted 4

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

cat > "$config/corrupt.yaml" <<EOF
name: corrupt
repos:
  - name: corrupt
    path: corrupt
  - name: small
    path: small
EOF

cat > "$config/worktree.yaml" <<EOF
name: worktree
repos:
  - name: bigwt
    path: bigwt
EOF

cat > "$config/norepos.yaml" <<EOF
name: norepos
description: a project that declares no repos
EOF

cat > "$config/odd.yaml" <<'YAML'
name: odd
repos:
  - name: say "hi" or .name == "big"
    path: quoted
  - name: small
    path: small
YAML

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

if (Path(work_dir) / ".td-unopenable").is_file():
    # Real td reports an existing-but-unusable database with the SAME code as a
    # missing one, e.g. "enable WAL mode: file is not a database (26)".
    print(json.dumps({"error": {"code": "database_error",
                                "message": "enable WAL mode: file is not a database (26)"}}))
    sys.exit(1)

fail_repo = os.environ.get("SGT_TD_LIST_TEST_FAIL_REPO", "")
if fail_repo and Path(work_dir).name == fail_repo:
    # Hard td failure: nothing usable on stdout, nonzero exit.
    sys.stderr.write("td: unexpected failure\n")
    sys.exit(2)

flood_repo = os.environ.get("SGT_TD_LIST_TEST_FLOOD_REPO", "")
if flood_repo and Path(work_dir).name == flood_repo:
    # A failure whose first stderr line is enormous.
    sys.stderr.write("x" * 200000 + "\n")
    sys.exit(2)

nonobj_repo = os.environ.get("SGT_TD_LIST_TEST_NON_OBJECT_REPO", "")
if nonobj_repo and Path(work_dir).name == nonobj_repo:
    # Exit 0 with a JSON array that does not contain task objects.
    print(json.dumps([1, 2, 3]))
    sys.exit(0)

count_file = Path(work_dir) / ".td-task-count"
if not count_file.is_file():
    # Real td behaviour for a repo with no td database: JSON error object on
    # stdout, exit status 1.
    print(json.dumps({"error": {"code": "database_error",
                                "message": "database not found: run 'td init' first"}}))
    sys.exit(1)

total = int(count_file.read_text().strip())
if limit < 0:
    emitted = total          # td's unlimited idiom
elif limit == 0:
    emitted = min(total, 50) # real td: 0 falls back to its silent default
else:
    emitted = min(total, limit)

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

RUN_STATUS=0

_run() {
  # _run <stdout-file> <stderr-file> [env assignments...] -- <args...>
  # Records the exit status in RUN_STATUS instead of failing, so every case can
  # assert the status it expects: 0 complete, 1 unusable, 2 incomplete report.
  local out="$1" err="$2"; shift 2
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  RUN_STATUS=0
  env HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
    "${envs[@]+"${envs[@]}"}" \
    "$ROOT_DIR/bin/sgt-td-list" "$@" >"$out" 2>"$err" || RUN_STATUS=$?
  return 0
}

_fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

_expect_status() {
  # _expect_status <expected> <label> <stderr-file>
  [[ "$RUN_STATUS" == "$1" ]] || {
    printf 'actual stderr:\n%s\n' "$(cat "$3")" >&2
    _fail "$2: expected exit $1, got $RUN_STATUS"
  }
}

# ── 1. Human-readable path reports every task, not 50 ─────────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/human.out"; err="$TEST_ROOT/human.err"
_run "$out" "$err" -- example
_expect_status 0 human_no_truncation "$err"

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
_run "$out" "$err" -- example --json
_expect_status 0 json_no_truncation "$err"

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
_run "$out" "$err" -- example --repos big --limit 5
_expect_status 2 user_limit_wins "$err"   # 55 of 60 tasks withheld

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
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 SGT_TD_LIST_MAX_LIMIT=10 -- ceiling
_expect_status 2 ceiling_warning "$err"

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
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 SGT_TD_LIST_MAX_LIMIT=10 -- ceiling --json
_expect_status 2 ceiling_json_stdout_clean "$err"
"$REAL_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" \
  || { printf 'actual stdout:\n%s\n' "$(cat "$out")" >&2
       _fail "ceiling_json_stdout_clean: --json stdout must stay valid JSON"; }
grep -qi 'truncat' "$err" || _fail "ceiling_json_stdout_clean: warning must go to stderr"
printf 'ceiling_json_stdout_clean: ok\n'

# ── 5. Escalation reaches repos larger than the initial page size ──────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/escalate.out"; err="$TEST_ROOT/escalate.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 -- ceiling
_expect_status 0 escalates_past_initial_limit "$err"

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
_run "$out" "$err" -- uninitialized
_expect_status 0 uninitialized_repo_skipped "$err"

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
_run "$out" "$err" -- uninitialized --json
_expect_status 0 uninitialized_repo_json "$err"

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
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_REPO=big -- example
_expect_status 2 td_failure_warns "$err"

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
_run "$out" "$err" -- example --repos big --limit
! grep -qE -- '--limit[[:space:]]+--limit' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "dangling_limit_not_supplemented: must not inject a default beside a caller --limit"
}
printf 'dangling_limit_not_supplemented: ok\n'

# ── 9. A caller limit that withholds nothing must not warn ────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/exact.out"; err="$TEST_ROOT/exact.err"
_run "$out" "$err" -- example --repos small --limit 7
_expect_status 0 exact_limit_no_warning "$err"

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
_run "$out" "$err" -- example --repos small --limit 3
_expect_status 2 caller_limit_lower_bound "$err"
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
  _run "$out" "$err" -- example --repos big "$spelling"
  _expect_status 2 "caller_limit_spellings($spelling)" "$err"
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
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_PYTHON=1 -- example
_expect_status 2 parse_failure_warns "$err"

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
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_PYTHON=2 -- example --repos big
_expect_status 2 render_failure_warns "$err"
if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "render_failure_warns: a failed listing render must warn and name the repo"
fi
printf 'render_failure_warns: ok\n'

# ── 12. --json keeps its contract when a repo fails hard ─────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/jsonfail.out"; err="$TEST_ROOT/jsonfail.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FAIL_REPO=big -- example --json
_expect_status 2 json_failure_warns "$err"

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

# ── 13. An unusable td database is never mistaken for an absent one ────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/corrupt.out"; err="$TEST_ROOT/corrupt.err"
_run "$out" "$err" -- corrupt
_expect_status 2 corrupt_db_warns "$err"

if ! grep -qF 'corrupt' "$err" || ! grep -qF 'not a database' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "corrupt_db_warns: an unopenable td database must be named on stderr with td's reason"
fi
! grep -qF '── corrupt (' "$out" || _fail "corrupt_db_warns: unreadable repo must not report a count"
grep -qF '── small (7)' "$out" || _fail "corrupt_db_warns: healthy repos must still be reported"
grep -qF 'report incomplete' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "corrupt_db_warns: the human footer must say the report is incomplete"
}
printf 'corrupt_db_warns: ok\n'

# ── 14. A linked git worktree is a checkout, not a missing repo ────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/worktree.out"; err="$TEST_ROOT/worktree.err"
_run "$out" "$err" -- worktree
_expect_status 0 worktree_repo_listed "$err"

grep -qF '── bigwt (11)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "worktree_repo_listed: a repo checked out as a linked worktree must be listed"
}
grep -qF '11 task(s) total' "$out" || _fail "worktree_repo_listed: total must include the worktree repo"
printf 'worktree_repo_listed: ok\n'

# ── 15. --limit 0 does not hand the silent 50-task default back to td ──────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/limit0.out"; err="$TEST_ROOT/limit0.err"
_run "$out" "$err" -- example --repos big --limit 0
_expect_status 2 limit_zero_warns "$err"

grep -qF '── big (50)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "limit_zero_warns: expected td's own default of 50 rows to be reported"
}
if ! grep -qF 'big' "$err" || ! grep -qi 'truncat' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "limit_zero_warns: --limit 0 hits td's silent 50 default, so it must warn"
fi
printf 'limit_zero_warns: ok\n'

# ── 16. Repo selectors that cannot be honoured are reported ───────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/typo.out"; err="$TEST_ROOT/typo.err"
_run "$out" "$err" -- example --repos big,typo-repo
_expect_status 2 unknown_named_repo_warns "$err"

grep -qF 'typo-repo' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "unknown_named_repo_warns: a --repos name that is not configured must be named on stderr"
}
grep -qF '── big (60)' "$out" || _fail "unknown_named_repo_warns: known repos must still be reported"
printf 'unknown_named_repo_warns: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/empty.out"; err="$TEST_ROOT/empty.err"
_run "$out" "$err" -- example --repos 'big,,small'
_expect_status 2 empty_repo_selector_warns "$err"
grep -qi 'empty --repos' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "empty_repo_selector_warns: an empty --repos element must be reported"
}
printf 'empty_repo_selector_warns: ok\n'

# ── 17. A repo name is data, never part of the yq expression ──────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/inject.out"; err="$TEST_ROOT/inject.err"
_run "$out" "$err" -- example --repos 'ghost" or .name == "big' --json
_expect_status 2 repo_name_not_injected "$err"

json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")" \
  || _fail "repo_name_not_injected: stdout must stay valid JSON"
[[ "$json_count" == "0" ]] || {
  printf 'actual stdout:\n%s\n' "$(cat "$out")" >&2
  _fail "repo_name_not_injected: a crafted name resolved to another repo's tasks ($json_count)"
}
printf 'repo_name_not_injected: ok\n'

# A configured name containing quotes and yq operators still resolves correctly.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/odd.out"; err="$TEST_ROOT/odd.err"
_run "$out" "$err" -- odd
_expect_status 0 odd_repo_name_resolves "$err"
grep -qF 'say "hi" or .name == "big" (4)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "odd_repo_name_resolves: a repo whose configured name contains quotes must still be read"
}
grep -qF '11 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "odd_repo_name_resolves: expected 4 + 7 tasks"
}
printf 'odd_repo_name_resolves: ok\n'

# ── 18. Unusable configuration and environment fail once, loudly ──────────────

out="$TEST_ROOT/norepos.out"; err="$TEST_ROOT/norepos.err"
_run "$out" "$err" -- norepos
_expect_status 1 no_repos_is_fatal "$err"
grep -qi 'no repos' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "no_repos_is_fatal: a project with no repos must fail with a clear message"
}
printf 'no_repos_is_fatal: ok\n'

for bad in 0 abc -5; do
  out="$TEST_ROOT/badlimit.out"; err="$TEST_ROOT/badlimit.err"
  _run "$out" "$err" "SGT_TD_LIST_LIMIT=$bad" -- example
  _expect_status 1 "limit_validation($bad)" "$err"
  grep -qF 'must be a positive integer' "$err" || {
    printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
    _fail "limit_validation($bad): expected a validation error"
  }
done
printf 'limit_validation: ok\n'

# An initial limit above the ceiling is clamped, and the ceiling still warns.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/clamp.out"; err="$TEST_ROOT/clamp.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=500 SGT_TD_LIST_MAX_LIMIT=20 -- ceiling
_expect_status 2 clamped_initial_limit "$err"
grep -qF -- '--limit 21' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "clamped_initial_limit: the initial limit must be clamped to the ceiling"
}
grep -qi 'truncat' "$err" || _fail "clamped_initial_limit: the ceiling must still warn"
printf 'clamped_initial_limit: ok\n'

# An unwritable TMPDIR is an environment fault, and must not be blamed on td.
: > "$TEST_ROOT/td.log"
nowrite="$TEST_ROOT/nowrite"; mkdir -p "$nowrite"; chmod 500 "$nowrite"
out="$TEST_ROOT/tmpdir.out"; err="$TEST_ROOT/tmpdir.err"
_run "$out" "$err" "TMPDIR=$nowrite" -- example
_expect_status 1 unwritable_tmpdir_is_fatal "$err"
grep -qi 'temporary directory' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "unwritable_tmpdir_is_fatal: expected a message naming the temporary directory"
}
! grep -qi 'td list failed' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "unwritable_tmpdir_is_fatal: an environment fault must not be blamed on td"
}
[[ ! -s "$TEST_ROOT/td.log" ]] || _fail "unwritable_tmpdir_is_fatal: td must not be invoked at all"
chmod 700 "$nowrite"
printf 'unwritable_tmpdir_is_fatal: ok\n'

# A missing python3 is a single fatal error, not a per-repo warning.
: > "$TEST_ROOT/td.log"
nopython="$TEST_ROOT/nopython"; mkdir -p "$nopython"
for tool in bash env dirname basename cat sed head cut tr wc mktemp rm git yq td uname grep; do
  [[ -x "$fake_bin/$tool" ]] && { ln -sf "$fake_bin/$tool" "$nopython/$tool"; continue; }
  _tool_path="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$_tool_path" ]] && ln -sf "$_tool_path" "$nopython/$tool"
done
out="$TEST_ROOT/nopython.out"; err="$TEST_ROOT/nopython.err"
RUN_STATUS=0
env -i HOME="$home" PATH="$nopython" SERGEANT_CONFIG="$config" \
  "$ROOT_DIR/bin/sgt-td-list" example >"$out" 2>"$err" || RUN_STATUS=$?
_expect_status 1 missing_python3_is_fatal "$err"
grep -qi 'python3 is required' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "missing_python3_is_fatal: expected a single fatal python3 requirement error"
}
! grep -qi 'No tasks found' "$out" || {
  _fail "missing_python3_is_fatal: must not print an authoritative empty report"
}
printf 'missing_python3_is_fatal: ok\n'

# ── 19. Task rows that are not objects are reported, not half-published ───────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nonobj.out"; err="$TEST_ROOT/nonobj.err"
_run "$out" "$err" SGT_TD_LIST_TEST_NON_OBJECT_REPO=big -- example
_expect_status 2 non_object_rows_warn "$err"
! grep -qF '── big (' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "non_object_rows_warn: must not publish a header and count for unusable rows"
}
grep -qF '7 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "non_object_rows_warn: the total must count only the healthy repo"
}
grep -qF 'big' "$err" || _fail "non_object_rows_warn: the repo must be named on stderr"
printf 'non_object_rows_warn: ok\n'

# The --json path must agree, not die.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nonobj-json.out"; err="$TEST_ROOT/nonobj-json.err"
_run "$out" "$err" SGT_TD_LIST_TEST_NON_OBJECT_REPO=big -- example --json
_expect_status 2 non_object_rows_json "$err"
json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")" \
  || _fail "non_object_rows_json: stdout must stay valid JSON"
[[ "$json_count" == "7" ]] || _fail "non_object_rows_json: expected only the healthy repo's 7 tasks"
printf 'non_object_rows_json: ok\n'

# ── 20. Pathological td stderr is bounded in the warning ─────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/flood.out"; err="$TEST_ROOT/flood.err"
_run "$out" "$err" SGT_TD_LIST_TEST_FLOOD_REPO=big -- example
_expect_status 2 bounded_td_stderr "$err"
err_size="$(wc -c < "$err" | tr -d ' ')"
[[ "$err_size" -lt 4096 ]] || {
  printf 'stderr size: %s\n' "$err_size" >&2
  _fail "bounded_td_stderr: a pathological td stderr must not be echoed unbounded"
}
grep -qF 'big' "$err" || _fail "bounded_td_stderr: the repo must still be named"
printf 'bounded_td_stderr: ok (%s bytes)\n' "$err_size"

printf '\nAll sgt-td-list tests passed.\n'
