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
_make_repo edge 11     # exactly SGT_TD_LIST_MAX_LIMIT + 1 in the ceiling tests

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

_make_repo victim 7

# 10 tasks cycling open, in_progress, open, blocked, open, in_review, open,
# closed, in_progress, blocked → 9 non-closed, of which 4 are open.
# A repo with no open tasks at all: under the old status=open default it
# disappeared from the report entirely, repo header and all.
_make_repo nonopen 3
printf 'in_progress\nblocked\nin_review\n' > "$dev_root/nonopen/.td-task-statuses"

_make_repo mixed 10
printf 'open\nin_progress\nopen\nblocked\nopen\nin_review\nopen\nclosed\nin_progress\nblocked\n' \
  > "$dev_root/mixed/.td-task-statuses"
# Tasks 3 (open) and 6 (in_review) are deferred: non-closed, and hidden from td's
# default answer, so they are exactly the tasks a single read would lose.
printf '3 6\n' > "$dev_root/mixed/.td-task-deferred"

cat > "$config/nopath.yaml" <<EOF
name: nopath
repos:
  - name: small
    path: small
  - name: nopathrepo
EOF

cat > "$config/newlinename.yaml" <<'YAML'
name: newlinename
repos:
  - name: "alpha\nbeta"
    path: quoted
  - name: victim
    path: victim
YAML

cat > "$config/mixed.yaml" <<EOF
name: mixed
repos:
  - name: mixed
    path: mixed
EOF

cat > "$config/notcloned.yaml" <<EOF
name: notcloned
repos:
  - name: small
    path: small
  - name: ghostrepo
    path: ghostrepo
EOF

cat > "$config/nonopen.yaml" <<EOF
name: nonopen
repos:
  - name: nonopen
    path: nonopen
  - name: small
    path: small
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

cat > "$config/edge.yaml" <<EOF
name: edge
repos:
  - name: edge
    path: edge
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
td_filter = ""
deferred_only = False
want_status = ""
want_priority = ""
include_everything = False
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
        td_filter = argv[idx + 1]
        idx += 2
    elif arg == "--deferred":
        deferred_only = True
        idx += 1
    elif arg in ("-s", "--status"):
        # Real td's -s is a stringArray and accumulates; sgt-td-list claims every
        # status spelling itself so td can never receive two, and this fake fails
        # loudly if that ever stops being true.
        if want_status:
            sys.stderr.write("fake td: -s passed twice (%r then %r)\n"
                             % (want_status, argv[idx + 1]))
            sys.exit(64)
        want_status = argv[idx + 1]
        idx += 2
    elif arg in ("-a", "--all"):
        include_everything = True
        idx += 1
    elif arg in ("-o", "--open"):
        want_status = "open"
        idx += 1
    elif arg in ("-p", "--priority"):
        want_priority = argv[idx + 1]
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

slow_repo = os.environ.get("SGT_TD_LIST_TEST_SLOW_REPO", "")
if slow_repo and Path(work_dir).name == slow_repo:
    import time
    time.sleep(30)

usage_repo = os.environ.get("SGT_TD_LIST_TEST_USAGE_ERROR_REPO", "")
if usage_repo and Path(work_dir).name == usage_repo:
    # Real td flag error: the reason goes to stdout as JSON, and only cobra's
    # usage banner goes to stderr.
    print(json.dumps({"error": {"code": "invalid_input",
                                "message": "unknown flag: --nope"}}))
    sys.stderr.write("Usage:\n  td list [filters] [flags]\n\nFlags:\n  -a, --all\n")
    sys.exit(1)

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

def task_priority(n):
    return "P%d" % (n % 4)

statuses_file = Path(work_dir) / ".td-task-statuses"
if statuses_file.is_file():
    # One status per line, cycled over the repo's tasks.
    cycle = [line for line in statuses_file.read_text().split() if line]
else:
    cycle = ["open"]

# --filter is a raw TDQ expression: td applies neither its closed exclusion nor
# its deferred exclusion to it, and only the status clause is honoured here.
for clause in td_filter.split(" AND "):
    if clause.startswith("status="):
        want_status = clause[len("status="):]
    elif clause.startswith("priority="):
        want_priority = clause[len("priority="):]

deferred_file = Path(work_dir) / ".td-task-deferred"
deferred_idx = set()
if deferred_file.is_file():
    deferred_idx = {int(x) for x in deferred_file.read_text().split() if x}

# Real td, verified against v0.55.0: the native -s/-p flags keep td's
# closed-and-deferred exclusion and are honoured together with --deferred, while
# a raw --filter expression bypasses both exclusions.
tasks = []
for n in range(total):
    status = cycle[n % len(cycle)]
    is_deferred = (n + 1) in deferred_idx
    if td_filter or include_everything:
        pass                          # neither --filter nor -a applies exclusions
    else:
        # Verified against td v0.55.0: closed tasks are excluded unless asked
        # for by status (-s closed returns them), and deferred tasks come only
        # from a --deferred query.
        if status == "closed" and want_status != "closed":
            continue
        if deferred_only and not is_deferred:
            continue
        if not deferred_only and is_deferred:
            continue
    if want_status and status != want_status:
        continue
    if want_priority and task_priority(n) != want_priority:
        continue
    tasks.append(
        {
            "id": "td-%06d" % (n + 1),
            "title": "task %d" % (n + 1),
            "status": status,
            "type": "bug",
            "priority": task_priority(n),
        }
    )

if limit < 0:
    pass                              # td's unlimited idiom
elif limit == 0:
    tasks = tasks[:50]                # real td: 0 falls back to its default
else:
    tasks = tasks[:limit]
print(json.dumps(tasks, indent=2))
EOF
chmod +x "$fake_bin/td"

# Wrapper that records every python3 process sgt-td-list launches.  The fake td
# above runs on an absolute interpreter path, so it is not counted here.
cat > "$fake_bin/python3" <<EOF
#!/usr/bin/env bash
printf 'python3\n' >> "$TEST_ROOT/python.log"
# Failure injection keys on a marker in the program text, not on invocation
# order, so these tests survive a change in how many passes sgt-td-list makes.
# Only the FIRST matching invocation fails, which is what makes "one repo is
# unreadable, the rest are fine" testable.
if [[ -n "\${SGT_TD_LIST_TEST_FAIL_PYTHON:-}" && "\$*" == *"\$SGT_TD_LIST_TEST_FAIL_PYTHON"* ]]; then
  if [[ ! -e "$TEST_ROOT/python-failed-once" ]]; then
    : > "$TEST_ROOT/python-failed-once"
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

# Per repo: one parse for td's default answer, one for its deferred answer, and
# one merge — plus one repo-map read and one final tag-and-merge pass for the
# whole project.  Anything more means per-repo tagging crept back in, and that
# was the shape whose whitespace-split merge silently produced an empty array.
python_calls="$(wc -l < "$TEST_ROOT/python.log" | tr -d ' ')"
[[ "$python_calls" -le 8 ]] || {
  _fail "json_single_merge_pass: expected at most 8 python3 processes for 2 repos, got $python_calls"
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
# The default must not be injected alongside the caller's limit: the only limits
# td may see are the caller's 5 and the deliberate 6 that proves truncation.
# The caller's cap limits what is printed, not what is read, so the read uses the
# normal escalating limit and the caller's own flag is still forwarded.
limits_seen="$(grep -o -- '--limit [0-9]*' "$TEST_ROOT/td.log" | sort -u | tr '\n' ',')"
[[ "$limits_seen" == "--limit 1001,--limit 5," ]] || {
  printf 'actual td calls:\n%s\nlimits seen: %s\n' "$(cat "$TEST_ROOT/td.log")" "$limits_seen" >&2
  _fail "user_limit_wins: unexpected limits sent to td (a default was injected?)"
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
_expect_status 2 dangling_limit_not_supplemented "$err"
! grep -qE -- '--limit[[:space:]]+--limit' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "dangling_limit_not_supplemented: must not inject a default beside a caller --limit"
}
# td rejects the dangling flag, and that rejection must be reported, not swallowed.
if ! grep -qF 'big' "$err" || ! grep -qi 'fail' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "dangling_limit_not_supplemented: td's rejection must be reported and name the repo"
fi
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

# A caller limit that does withhold tasks names the exact total it withheld from.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/lower.out"; err="$TEST_ROOT/lower.err"
_run "$out" "$err" -- example --repos small --limit 3
_expect_status 2 caller_limit_exact_total "$err"
grep -qF '── small (3)' "$out" || _fail "caller_limit_exact_total: caller limit must still cap the printed rows"
grep -qF '7 task(s) exist' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "caller_limit_exact_total: the repo was read completely, so the warning must name the exact total"
}
printf 'caller_limit_exact_total: ok\n'

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

# The per-repo parser turns td's stdout into a payload.  When it fails, the repo
# must be named on stderr rather than silently reported as empty.
: > "$TEST_ROOT/td.log"; : > "$TEST_ROOT/python.log"; rm -f "$TEST_ROOT/python-failed-once"
out="$TEST_ROOT/parsefail.out"; err="$TEST_ROOT/parsefail.err"
_run "$out" "$err" 'SGT_TD_LIST_TEST_FAIL_PYTHON=isinstance(data, list)' -- example
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
: > "$TEST_ROOT/td.log"; : > "$TEST_ROOT/python.log"; rm -f "$TEST_ROOT/python-failed-once"
out="$TEST_ROOT/renderfail.out"; err="$TEST_ROOT/renderfail.err"
_run "$out" "$err" 'SGT_TD_LIST_TEST_FAIL_PYTHON=order = {' -- example --repos big
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

# ── 21. A repo map that cannot be read is fatal, not an empty report ──────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/mapfail.out"; err="$TEST_ROOT/mapfail.err"
rm -f "$TEST_ROOT/python-failed-once"
_run "$out" "$err" 'SGT_TD_LIST_TEST_FAIL_PYTHON=repo.get' -- example
_expect_status 1 repo_map_failure_is_fatal "$err"
grep -qi 'cannot read repos' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "repo_map_failure_is_fatal: expected a fatal repo-map error"
}
! grep -qi 'No tasks found' "$out" || \
  _fail "repo_map_failure_is_fatal: must not print an authoritative empty report"
printf 'repo_map_failure_is_fatal: ok\n'

# ── 22. A repo configured without a path is reported, not dropped ─────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nopath.out"; err="$TEST_ROOT/nopath.err"
_run "$out" "$err" -- nopath
_expect_status 2 missing_path_warns "$err"
grep -qF 'nopathrepo' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "missing_path_warns: a repo configured with no path must be named on stderr"
}
grep -qF '── small (7)' "$out" || _fail "missing_path_warns: healthy repos must still be reported"
printf 'missing_path_warns: ok\n'

# ── 23. A repo name containing a newline keeps its own identity ───────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/newline.out"; err="$TEST_ROOT/newline.err"
_run "$out" "$err" -- newlinename
_expect_status 0 newline_repo_name "$err"
grep -qF '── victim (7)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "newline_repo_name: a later repo must not lose its identity to a multi-line name"
}
! grep -qE '^── beta \(' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "newline_repo_name: tasks must never be published under a phantom repo name"
}

# --json must attribute the same tasks to the same configured names.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/newline-json.out"; err="$TEST_ROOT/newline-json.err"
_run "$out" "$err" -- newlinename --json
_expect_status 0 newline_repo_name_json "$err"
json_tags="$("$REAL_PYTHON" - "$out" <<'PY'
import collections, json, sys
tasks = json.load(open(sys.argv[1]))
counts = collections.Counter(t.get("_repo") for t in tasks)
print(" | ".join("%r=%d" % (k, counts[k]) for k in sorted(counts, key=str)))
PY
)"
[[ "$json_tags" == *"victim'=7"* ]] || {
  printf 'actual repo tags: %s\n' "$json_tags" >&2
  _fail "newline_repo_name_json: victim's tasks must be tagged with victim"
}
[[ "$json_tags" != *"'beta'"* ]] || {
  printf 'actual repo tags: %s\n' "$json_tags" >&2
  _fail "newline_repo_name_json: no task may be tagged with a phantom repo name"
}
printf 'newline_repo_name: ok\n'
printf 'newline_repo_name_json: ok\n'

# ── 24. Option parsing: missing values and filter composition ────────────────

for flag in --status --priority --repos; do
  out="$TEST_ROOT/noval.out"; err="$TEST_ROOT/noval.err"
  _run "$out" "$err" -- example "$flag"
  _expect_status 1 "option_requires_value($flag)" "$err"
  grep -qF -- "$flag requires a value" "$err" || {
    printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
    _fail "option_requires_value($flag): expected an explicit missing-value error"
  }
done
printf 'option_requires_value: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/prio.out"; err="$TEST_ROOT/prio.err"
_run "$out" "$err" -- example --repos small --priority P1
_expect_status 0 priority_filter_composed "$err"
# The narrowing must travel as td's native -p, never as a hand-built --filter:
# td does not apply its closed exclusion to --filter expressions.
grep -qF -- '-p P1' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "priority_filter_composed: --priority must reach td as its native -p flag"
}
! grep -qF -- '--filter' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "priority_filter_composed: a hand-built --filter expression would defeat td's closed exclusion"
}
! grep -qF -- '-s ' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "priority_filter_composed: --priority alone must not narrow the status view"
}
grep -qF '[all non-closed AND priority=P1]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "priority_filter_composed: the header must name the active view"
}
printf 'priority_filter_composed: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/all.out"; err="$TEST_ROOT/all.err"
_run "$out" "$err" -- example --repos small --all
_expect_status 0 all_drops_status_filter "$err"
! grep -qE -- '(-s |--filter)' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "all_drops_status_filter: --all must not narrow the status view"
}
grep -qF '[all non-closed]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "all_matches_default_label: --all must name the same view as the default"
}
printf 'all_drops_status_filter: ok\n'

# ── 25. The ceiling reports what it withheld, and only when it withheld ───────

# A repo holding exactly ceiling + 1 tasks: the ceiling publishes the ceiling and
# the extra row is the proof that something was withheld.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/edge.out"; err="$TEST_ROOT/edge.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=10 SGT_TD_LIST_MAX_LIMIT=10 -- edge
_expect_status 2 ceiling_boundary "$err"
grep -qF '── edge (10)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "ceiling_boundary: the ceiling must publish exactly SGT_TD_LIST_MAX_LIMIT rows"
}
grep -qF 'at least 11 task(s)' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "ceiling_boundary: the warning must prove more tasks exist than were published"
}

# The same repo under a ceiling it fits inside is complete and silent.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/edge-ok.out"; err="$TEST_ROOT/edge-ok.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=11 SGT_TD_LIST_MAX_LIMIT=11 -- edge
_expect_status 0 ceiling_boundary_fits "$err"
grep -qF '── edge (11)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "ceiling_boundary_fits: a repo that fits the ceiling must be reported in full"
}
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "ceiling_boundary_fits: a complete report must not warn"
}
printf 'ceiling_boundary: ok\n'
printf 'ceiling_boundary_fits: ok\n'

# ── 26. A repo reached twice is counted once ──────────────────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/dup.out"; err="$TEST_ROOT/dup.err"
_run "$out" "$err" -- example --repos small,small
_expect_status 0 duplicate_repo_counted_once "$err"
[[ "$(grep -c -- '── small (' "$out")" == "1" ]] || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "duplicate_repo_counted_once: a repeated --repos entry must be listed once"
}
grep -qF '7 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "duplicate_repo_counted_once: the total must not double-count"
}
grep -qi 'more than once' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "duplicate_repo_counted_once: the duplicate must be reported"
}
printf 'duplicate_repo_counted_once: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/dupjson.out"; err="$TEST_ROOT/dupjson.err"
_run "$out" "$err" -- example --repos small,small --json
_expect_status 0 duplicate_repo_json "$err"
dup_ids="$("$REAL_PYTHON" -c '
import json, sys
tasks = json.load(open(sys.argv[1]))
ids = [t["id"] for t in tasks]
print("%d %d" % (len(ids), len(set(ids))))' "$out")"
[[ "$dup_ids" == "7 7" ]] || {
  printf 'tasks vs distinct ids: %s\n' "$dup_ids" >&2
  _fail "duplicate_repo_json: --json must not repeat tasks"
}
printf 'duplicate_repo_json: ok\n'

# ── 27. A signal must never leave a clean-looking empty report ────────────────

: > "$TEST_ROOT/td.log"
signal_tmp="$TEST_ROOT/signal-tmp"; mkdir -p "$signal_tmp"
out="$TEST_ROOT/signal.out"; err="$TEST_ROOT/signal.err"
env HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
  TMPDIR="$signal_tmp" SGT_TD_LIST_TEST_SLOW_REPO=big \
  "$ROOT_DIR/bin/sgt-td-list" example >"$out" 2>"$err" &
signal_pid=$!
# Wait until the slow repo read is under way, then terminate the run.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -s "$TEST_ROOT/td.log" ]] && break
  sleep 0.2
done
kill -TERM "$signal_pid" 2>/dev/null || true
signal_status=0
wait "$signal_pid" || signal_status=$?

[[ "$signal_status" -ne 0 ]] || {
  printf 'actual stdout:\n%s\nactual stderr:\n%s\n' "$(cat "$out")" "$(cat "$err")" >&2
  _fail "signal_never_reports_success: a terminated run must not exit 0"
}
! grep -qF 'task(s) total' "$out" || {
  printf 'actual stdout:\n%s\n' "$(cat "$out")" >&2
  _fail "signal_never_reports_success: a terminated run must not print an authoritative total"
}
! grep -qF 'No tasks found' "$out" || {
  printf 'actual stdout:\n%s\n' "$(cat "$out")" >&2
  _fail "signal_never_reports_success: a terminated run must not claim the project is empty"
}
[[ -z "$(ls -A "$signal_tmp" 2>/dev/null)" ]] || {
  printf 'leftovers in TMPDIR: %s\n' "$(ls -A "$signal_tmp")" >&2
  _fail "signal_never_reports_success: the workspace must be removed when a signal ends the run"
}
printf 'signal_never_reports_success: ok\n'

# ── 28. Status filtering is explicit, and the complete view is complete ────────

# The default view is every non-closed task: narrowing it to status=open used to
# hide in_progress, in_review and blocked work — and whole repos — from a report
# whose job is a truthful backlog.  The header always names the active view.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/mixed.out"; err="$TEST_ROOT/mixed.err"
_run "$out" "$err" -- mixed
_expect_status 0 default_view_is_complete "$err"
grep -qF '[all non-closed]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "default_view_is_complete: the header must name the active view"
}
grep -qF '── mixed (9)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "default_view_is_complete: the default must report all 9 non-closed tasks"
}
grep -qF '9 task(s) total' "$out" || _fail "default_view_is_complete: total must match"
for status in in_progress blocked in_review; do
  grep -qF "$status" "$out" || {
    printf 'actual output:\n%s\n' "$(cat "$out")" >&2
    _fail "default_view_is_complete: the default must include $status tasks"
  }
done
# The 8th fixture task is the closed one; the header legitimately contains the
# word "non-closed", so assert on the task itself, not on the word.
! grep -qF 'td-000008' "$out" || _fail "default_view_is_complete: closed tasks must stay out"
printf 'default_view_is_complete: ok\n'

# --all is still accepted and still means every non-closed status.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/mixed-all.out"; err="$TEST_ROOT/mixed-all.err"
_run "$out" "$err" -- mixed --all
_expect_status 0 all_matches_default "$err"
grep -qF '── mixed (9)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "all_matches_default: --all must report the same 9 non-closed tasks as the default"
}
grep -qF '9 task(s) total' "$out" || _fail "all_matches_default: total must match"
printf 'all_matches_default: ok\n'

# The same must hold on the machine-readable path, statuses included.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/mixed-json.out"; err="$TEST_ROOT/mixed-json.err"
_run "$out" "$err" -- mixed --json
_expect_status 0 all_json_reports_every_status "$err"
[[ ! -s "$err" ]] || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "all_json_reports_every_status: the complete default view has nothing to disclaim"
}
statuses="$("$REAL_PYTHON" -c '
import collections, json, sys
tasks = json.load(open(sys.argv[1]))
counts = collections.Counter(t["status"] for t in tasks)
print(len(tasks), " ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)))' "$out")"
[[ "$statuses" == "9 blocked=2 in_progress=2 in_review=1 open=4" ]] || {
  printf 'actual statuses: %s\n' "$statuses" >&2
  _fail "all_json_reports_every_status: --all --json must carry every non-closed status"
}
printf 'all_json_reports_every_status: ok\n'

# An explicit --status still narrows to exactly that status.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/mixed-blocked.out"; err="$TEST_ROOT/mixed-blocked.err"
_run "$out" "$err" -- mixed --status blocked
_expect_status 0 explicit_status_filter "$err"
grep -qF '── mixed (2)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "explicit_status_filter: --status blocked must report exactly the blocked tasks"
}
grep -qF '[status=blocked]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "explicit_status_filter: the header must name the narrowed view"
}
printf 'explicit_status_filter: ok\n'

# ── 29. A repo whose tasks are all non-open still appears ─────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nonopen.out"; err="$TEST_ROOT/nonopen.err"
_run "$out" "$err" -- nonopen
_expect_status 0 repo_without_open_tasks_appears "$err"
grep -qF '── nonopen (3)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "repo_without_open_tasks_appears: a repo with only in_progress/blocked/in_review work must be listed"
}
grep -qF '10 task(s) total' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "repo_without_open_tasks_appears: the total must include it (3 + 7)"
}
printf 'repo_without_open_tasks_appears: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/nonopen-json.out"; err="$TEST_ROOT/nonopen-json.err"
_run "$out" "$err" -- nonopen --json
_expect_status 0 repo_without_open_tasks_json "$err"
json_repos="$("$REAL_PYTHON" -c '
import collections, json, sys
tasks = json.load(open(sys.argv[1]))
counts = collections.Counter(t["_repo"] for t in tasks)
print(" ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)))' "$out")"
[[ "$json_repos" == "nonopen=3 small=7" ]] || {
  printf 'actual repo tags: %s\n' "$json_repos" >&2
  _fail "repo_without_open_tasks_json: --json must include the repo with no open tasks"
}
printf 'repo_without_open_tasks_json: ok\n'

# ── 30. A narrowed --json run discloses the view that produced it ─────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/prov.out"; err="$TEST_ROOT/prov.err"
_run "$out" "$err" -- mixed --status open --json
_expect_status 0 json_states_narrowed_view "$err"
json_count="$("$REAL_PYTHON" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$out")" \
  || _fail "json_states_narrowed_view: stdout must stay valid JSON"
[[ "$json_count" == "4" ]] || _fail "json_states_narrowed_view: expected the 4 open tasks, got $json_count"
grep -qF 'status=open' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "json_states_narrowed_view: a narrowed --json run must name its view on stderr"
}
printf 'json_states_narrowed_view: ok\n'

# ── 31. Deferred tasks are non-closed, so the default view includes them ──────

# td hides deferred tasks from its default answer and returns them only from a
# separate --deferred query, so a single read loses them silently.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/defer.out"; err="$TEST_ROOT/defer.err"
_run "$out" "$err" -- mixed
_expect_status 0 deferred_tasks_included "$err"
grep -qF '── mixed (9)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "deferred_tasks_included: all 9 non-closed tasks must be reported, deferred ones included"
}
for id in td-000003 td-000006; do
  grep -qF "$id" "$out" || {
    printf 'actual output:\n%s\n' "$(cat "$out")" >&2
    _fail "deferred_tasks_included: deferred task $id is non-closed and must appear"
  }
done
grep -qF -- '--deferred' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "deferred_tasks_included: the deferred half of the repo must actually be read"
}
# The two reads overlap in nothing, and a task must never be counted twice.
[[ "$(grep -c -- 'td-000003' "$out")" == "1" ]] || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "deferred_tasks_included: merging the two reads must not duplicate a task"
}
printf 'deferred_tasks_included: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/defer-json.out"; err="$TEST_ROOT/defer-json.err"
_run "$out" "$err" -- mixed --json
_expect_status 0 deferred_tasks_included_json "$err"
json_ids="$("$REAL_PYTHON" -c '
import json, sys
tasks = json.load(open(sys.argv[1]))
ids = [t["id"] for t in tasks]
print(len(ids), len(set(ids)), "td-000003" in ids, "td-000006" in ids)' "$out")"
[[ "$json_ids" == "9 9 True True" ]] || {
  printf 'actual (count distinct has3 has6): %s\n' "$json_ids" >&2
  _fail "deferred_tasks_included_json: --json must carry every non-closed task exactly once"
}
printf 'deferred_tasks_included_json: ok\n'

# A narrowed --status view narrows the deferred half too: task 6 is in_review.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/defer-status.out"; err="$TEST_ROOT/defer-status.err"
_run "$out" "$err" -- mixed --status in_review
_expect_status 0 deferred_respects_status_filter "$err"
grep -qF 'td-000006' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "deferred_respects_status_filter: a deferred in_review task must appear under --status in_review"
}
! grep -qF 'td-000003' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "deferred_respects_status_filter: a deferred open task must not appear under --status in_review"
}
printf 'deferred_respects_status_filter: ok\n'

# A caller's own --filter expression bypasses td's closed and deferred
# exclusions, so the header must not claim a non-closed view, and the redundant
# second read must not be issued.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/callerfilter.out"; err="$TEST_ROOT/callerfilter.err"
_run "$out" "$err" -- mixed --filter 'status=open'
_expect_status 0 caller_filter_view_is_honest "$err"
grep -qF 'caller --filter governs which statuses appear' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "caller_filter_view_is_honest: the header must say the caller's filter governs the statuses"
}
! grep -qF 'deferred excluded' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "caller_filter_view_is_honest: td returns deferred rows for --filter, so claiming otherwise is false"
}
grep -qF 'td-000003' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "caller_filter_view_is_honest: td's --filter answer includes deferred rows, so they must be listed"
}
! grep -qF -- '--deferred' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "caller_filter_view_is_honest: a second read that adds nothing must not be issued"
}
printf 'caller_filter_view_is_honest: ok\n'

# ── 32. --all and --status cannot silently disagree ───────────────────────────

out="$TEST_ROOT/conflict.out"; err="$TEST_ROOT/conflict.err"
_run "$out" "$err" -- mixed --all --status blocked
_expect_status 1 all_status_conflict_is_explicit "$err"
grep -qF 'mutually exclusive' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "all_status_conflict_is_explicit: combining --all and --status must be an explicit error"
}
printf 'all_status_conflict_is_explicit: ok\n'

# ── 33. A configured repo that is not cloned is visible, not invisible ────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/ghost.out"; err="$TEST_ROOT/ghost.err"
_run "$out" "$err" -- notcloned
_expect_status 0 uncloned_repo_is_noted "$err"
grep -qF 'ghostrepo' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "uncloned_repo_is_noted: a configured repo that is not cloned must be named"
}
grep -qF 'sgt-sync' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "uncloned_repo_is_noted: the note must say how to include it"
}
grep -qF '── small (7)' "$out" || _fail "uncloned_repo_is_noted: cloned repos must still be reported"
printf 'uncloned_repo_is_noted: ok\n'

# ── 34. Only an explicit --status closed may surface closed tasks ─────────────

# Regression: narrowing used to be sent as a hand-built `--filter` expression,
# and td applies its closed exclusion to -s/-p but NOT to --filter, so
# `--priority P<n>` reported closed tasks under a header claiming "all
# non-closed".  Fixture task 8 is the closed one, and it is P3 (8 % 4 == 3).
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/prio-closed.out"; err="$TEST_ROOT/prio-closed.err"
_run "$out" "$err" -- mixed --priority P3
_expect_status 0 priority_view_excludes_closed "$err"
! grep -qF 'td-000008' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "priority_view_excludes_closed: a closed task must never appear in a non-closed view"
}
! grep -qF 'closed  ' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "priority_view_excludes_closed: no row may carry the closed status"
}
printf 'priority_view_excludes_closed: ok\n'

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/prio-closed-json.out"; err="$TEST_ROOT/prio-closed-json.err"
_run "$out" "$err" -- mixed --priority P3 --json
_expect_status 0 priority_view_excludes_closed_json "$err"
closed_seen="$("$REAL_PYTHON" -c '
import json, sys
tasks = json.load(open(sys.argv[1]))
print(sum(1 for t in tasks if t["status"] == "closed"), len(tasks))' "$out")"
[[ "${closed_seen%% *}" == "0" ]] || {
  printf 'closed tasks in --json output: %s\n' "$closed_seen" >&2
  _fail "priority_view_excludes_closed_json: --json must not carry closed tasks"
}
printf 'priority_view_excludes_closed_json: ok\n'

# A caller who explicitly asks for closed tasks still gets them.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/status-closed.out"; err="$TEST_ROOT/status-closed.err"
_run "$out" "$err" -- mixed --status closed
_expect_status 0 explicit_closed_status_works "$err"
grep -qF 'td-000008' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "explicit_closed_status_works: --status closed must reach the closed task"
}
printf 'explicit_closed_status_works: ok\n'

# A negative caller limit is td's unlimited idiom, and must not lose the
# deferred half of a repo.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/neg.out"; err="$TEST_ROOT/neg.err"
_run "$out" "$err" -- mixed --limit -1
_expect_status 0 negative_limit_keeps_deferred "$err"
grep -qF '── mixed (9)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "negative_limit_keeps_deferred: --limit -1 must still report all 9 non-closed tasks"
}
for id in td-000003 td-000006; do
  grep -qF "$id" "$out" || {
    printf 'actual output:\n%s\n' "$(cat "$out")" >&2
    _fail "negative_limit_keeps_deferred: deferred task $id must not be dropped"
  }
done
printf 'negative_limit_keeps_deferred: ok\n'

# The -n=<n> spelling is a caller limit too, and must win over the default.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/neq.out"; err="$TEST_ROOT/neq.err"
_run "$out" "$err" -- example --repos big -n=5
_expect_status 2 caller_limit_eq_shorthand "$err"
grep -qF '── big (5)' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "caller_limit_eq_shorthand: -n=5 must cap the printed rows at 5"
}
if ! grep -qF 'big' "$err" || ! grep -qi 'truncat' "$err"; then
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "caller_limit_eq_shorthand: -n=5 withheld 55 tasks, so it must warn"
fi
printf 'caller_limit_eq_shorthand: ok\n'

# ── 35. Caller-passed td flags can never desync the header from the rows ───────

# td flags that change which statuses appear are claimed by sgt-td-list itself,
# so a forwarded copy can never land after ours and win while the header still
# describes the view we asked for.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/dashs.out"; err="$TEST_ROOT/dashs.err"
_run "$out" "$err" -- mixed -s closed
_expect_status 0 short_status_flag_is_claimed "$err"
grep -qF '[status=closed]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "short_status_flag_is_claimed: -s closed must be labelled like --status closed"
}
grep -qF 'td-000008' "$out" || _fail "short_status_flag_is_claimed: -s closed must reach the closed task"
printf 'short_status_flag_is_claimed: ok\n'

for spelling in "--status=closed" "-s=closed" "-sclosed"; do
  : > "$TEST_ROOT/td.log"
  out="$TEST_ROOT/spell.out"; err="$TEST_ROOT/spell.err"
  _run "$out" "$err" -- mixed "$spelling"
  _expect_status 0 "status_spelling($spelling)" "$err"
  grep -qF '[status=closed]' "$out" || {
    printf 'actual output:\n%s\n' "$(cat "$out")" >&2
    _fail "status_spelling($spelling): every status spelling must be claimed and labelled"
  }
done
printf 'status_spelling: ok\n'

# -o is exactly --status open, and must be labelled as such.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/dasho.out"; err="$TEST_ROOT/dasho.err"
_run "$out" "$err" -- mixed -o
_expect_status 0 open_shorthand_is_claimed "$err"
grep -qF '[status=open]' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "open_shorthand_is_claimed: -o must be labelled status=open"
}
grep -qF '── mixed (4)' "$out" || _fail "open_shorthand_is_claimed: -o must report the 4 open tasks"
printf 'open_shorthand_is_claimed: ok\n'

# td's -a widens to closed and deferred, which no view here claims: refuse it.
out="$TEST_ROOT/dasha.out"; err="$TEST_ROOT/dasha.err"
_run "$out" "$err" -- mixed -a
_expect_status 1 td_all_flag_refused "$err"
grep -qF 'not supported' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "td_all_flag_refused: -a must be refused with a pointer to the supported flags"
}
printf 'td_all_flag_refused: ok\n'

# --deferred would flip the base read; the default already covers it.
out="$TEST_ROOT/dashdef.out"; err="$TEST_ROOT/dashdef.err"
_run "$out" "$err" -- mixed --deferred
_expect_status 1 deferred_flag_refused "$err"
grep -qF 'not needed' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "deferred_flag_refused: --deferred must be refused as redundant"
}
printf 'deferred_flag_refused: ok\n'

# Every --all/--status spelling collides, not just the long one with a space.
for narrowing in "--status closed" "--status=closed" "-s closed" "-sclosed"; do
  out="$TEST_ROOT/conf.out"; err="$TEST_ROOT/conf.err"
  # shellcheck disable=SC2086
  _run "$out" "$err" -- mixed --all $narrowing
  _expect_status 1 "all_status_conflict($narrowing)" "$err"
  grep -qF 'mutually exclusive' "$err" || {
    printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
    _fail "all_status_conflict($narrowing): --all with $narrowing must be refused"
  }
done
printf 'all_status_conflict_spellings: ok\n'

# A status or priority passed twice would accumulate inside td; refuse it.
out="$TEST_ROOT/twice.out"; err="$TEST_ROOT/twice.err"
_run "$out" "$err" -- mixed --status open -s closed
_expect_status 1 status_passed_twice_refused "$err"
grep -qF 'once' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "status_passed_twice_refused: two statuses would accumulate in td, so refuse"
}
printf 'status_passed_twice_refused: ok\n'

# An empty value is a caller bug, not a request for everything.
for flag in --status --priority; do
  out="$TEST_ROOT/empty.out"; err="$TEST_ROOT/empty.err"
  _run "$out" "$err" -- mixed "$flag" ""
  _expect_status 1 "empty_value_refused($flag)" "$err"
  grep -qF -- "$flag requires a value" "$err" || {
    printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
    _fail "empty_value_refused($flag): an empty value must be refused"
  }
done
printf 'empty_value_refused: ok\n'

# Any other forwarded td flag may narrow the answer, so the label says so.
: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/sel.out"; err="$TEST_ROOT/sel.err"
_run "$out" "$err" -- mixed --sort priority
_expect_status 0 caller_selection_flag_labelled "$err"
grep -qF 'caller td flags may narrow which tasks appear' "$out" || {
  printf 'actual output:\n%s\n' "$(cat "$out")" >&2
  _fail "caller_selection_flag_labelled: a forwarded td flag must be disclosed in the label"
}
printf 'caller_selection_flag_labelled: ok\n'

# ── 36. A td flag error is reported with td's reason, not its usage banner ─────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/usage.out"; err="$TEST_ROOT/usage.err"
_run "$out" "$err" SGT_TD_LIST_TEST_USAGE_ERROR_REPO=big -- example
_expect_status 2 td_error_omits_usage_banner "$err"
grep -qF 'unknown flag' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "td_error_omits_usage_banner: td's own reason must be reported"
}
! grep -qF 'td list [filters]' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "td_error_omits_usage_banner: the usage banner must not be borrowed"
}
! grep -qF 'Usage:' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "td_error_omits_usage_banner: the usage banner must not be borrowed"
}
printf 'td_error_omits_usage_banner: ok\n'

# ── 37. A ceiling that skips the deferred half says so ────────────────────────

: > "$TEST_ROOT/td.log"
out="$TEST_ROOT/ceildef.out"; err="$TEST_ROOT/ceildef.err"
_run "$out" "$err" SGT_TD_LIST_LIMIT=2 SGT_TD_LIST_MAX_LIMIT=2 -- mixed
_expect_status 2 ceiling_names_unread_deferred "$err"
grep -qF 'deferred tasks, which were not read' "$err" || {
  printf 'actual stderr:\n%s\n' "$(cat "$err")" >&2
  _fail "ceiling_names_unread_deferred: the ceiling must say the deferred half went unread"
}
! grep -qF -- '--deferred' "$TEST_ROOT/td.log" || {
  printf 'actual td calls:\n%s\n' "$(cat "$TEST_ROOT/td.log")" >&2
  _fail "ceiling_names_unread_deferred: no deferred read is issued once the ceiling is hit"
}
printf 'ceiling_names_unread_deferred: ok\n'

printf '\nAll sgt-td-list tests passed.\n'
