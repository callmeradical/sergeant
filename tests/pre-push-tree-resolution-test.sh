#!/usr/bin/env bash
# Regression: the pre-push gate must validate the worktree being pushed, and the
# drain task must validate the tree it is handed -- not one it re-derives.
#
# Seam under test: the scripts/hooks/pre-push -> `mise run test:docker:drain`
# handoff, and the task's own tree resolution.  Both are exercised as public
# boundaries with mise and docker stubbed, so this test needs neither.
#
# Why (td-85b6bf).  On 2026-08-14, pushing fix/dispatch-sweep-followup from a
# linked worktree failed the gate while the identical command run by hand from
# that worktree passed:
#
#   mise run --cd <worktree>       test:docker:drain  -> 2 passed, 0 failed
#   mise run --cd ~/dev/sergeant   test:docker:drain  -> 0 passed, 2 failed
#   git push  (hook)                                  -> 0 passed, 2 failed
#
# The hook resolved the pushed worktree correctly and passed it via --cd, but the
# task then re-derived the tree itself:
#
#   REPO_DIR="$(git -C "${MISE_PROJECT_ROOT:-.}" rev-parse --show-toplevel ...)"
#
# MISE_PROJECT_ROOT is empty in practice, so that falls back to `.` and ignores
# the --cd. The Docker mount therefore came from the main checkout. Confirming
# detail from the incident: the pushed branch added yq to Dockerfile.test, yet the
# hook run still failed with "yq is required" -- proving the image was built from
# a tree without the change being pushed.
#
# scripts/hooks/pre-push already documents this hazard and claims to fix it. Both
# directions matter: the gate can fail a correct branch (observed) and can pass a
# broken one, because it becomes a function of uncommitted state in an unrelated
# tree.
#
# What must hold:
#   1. The hook tells the task which tree to validate, explicitly.
#   2. The task honours that instead of re-deriving it.
#   3. From a linked worktree, the pushed worktree is validated even when the
#      main checkout differs.
#   4. The validated host path is reported, so a wrong-tree run is visible.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_CONFIG="$TEST_ROOT/config"
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_FLEET="$TEST_ROOT/fleet"
export TMUX_TMPDIR="$TEST_ROOT/tmux"
mkdir -p "$SERGEANT_CONFIG" "$SERGEANT_DRAIN_DIR" "$SERGEANT_FLEET" "$TMUX_TMPDIR" \
  "$TEST_ROOT/bin"

PASS=0; FAIL=0
_pass() { PASS=$(( PASS + 1 )); printf 'PASS: %s\n' "$1"; }
_fail() { FAIL=$(( FAIL + 1 )); printf 'FAIL: %s\n' "$1" >&2; }

# ── Fixture: a main checkout plus a linked worktree ──────────────────────────
main_repo="$TEST_ROOT/main-checkout"
mkdir -p "$main_repo"
git -C "$main_repo" init -q
git -C "$main_repo" config user.email test@example.invalid
git -C "$main_repo" config user.name 'Test'
mkdir -p "$main_repo/scripts/hooks"
cp "$ROOT_DIR/scripts/hooks/pre-push" "$main_repo/scripts/hooks/pre-push"
chmod +x "$main_repo/scripts/hooks/pre-push"
printf 'main\n' > "$main_repo/marker"
# The task refuses a directory that is not a Sergeant checkout, so both fixture
# trees need the markers it looks for.
mkdir -p "$main_repo/tests"
printf 'FROM scratch\n' > "$main_repo/Dockerfile.test"
git -C "$main_repo" add -A
git -C "$main_repo" commit -qm fixture

linked_wt="$TEST_ROOT/linked-worktree"
git -C "$main_repo" worktree add -q "$linked_wt" -b feature 2>/dev/null
printf 'linked\n' > "$linked_wt/marker"
mkdir -p "$linked_wt/tests"
printf 'FROM scratch\n' > "$linked_wt/Dockerfile.test"

# Make the two trees distinguishable the same way the incident did: only the
# pushed tree carries the change under test.
printf 'main-checkout-differs\n' > "$main_repo/only-in-main"
git -C "$main_repo" add -A && git -C "$main_repo" commit -qm 'main diverges'

# ── Stub mise: records the tree the hook asked it to validate ───────────────
cat > "$TEST_ROOT/bin/mise" <<'MISE'
#!/usr/bin/env bash
# Record --cd and the explicit tree variable, then exit success.
cd_value=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--cd" ]] && cd_value="$arg"
  prev="$arg"
done
{
  printf 'cd=%s\n' "$cd_value"
  printf 'explicit=%s\n' "${SGT_TEST_REPO_DIR:-}"
  printf 'cwd=%s\n' "$PWD"
} > "$MISE_CALL_LOG"
exit 0
MISE
chmod +x "$TEST_ROOT/bin/mise"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/docker"
chmod +x "$TEST_ROOT/bin/docker"

# ── 1. The hook hands the task an explicit tree, and it is the pushed one ────
# git runs pre-push with the cwd of the worktree being pushed, and sets GIT_DIR
# to that worktree's gitdir -- reproduce both.
MISE_CALL_LOG="$TEST_ROOT/mise-call.log"
rm -f "$MISE_CALL_LOG"
(
  cd "$linked_wt"
  GIT_DIR="$(git rev-parse --absolute-git-dir)" \
  MISE_CALL_LOG="$MISE_CALL_LOG" \
  PATH="$TEST_ROOT/bin:$PATH" \
    bash "$main_repo/scripts/hooks/pre-push" origin https://example.invalid/x.git \
    < /dev/null > "$TEST_ROOT/hook.out" 2>&1
) || {
  printf 'FAIL: hook exited nonzero\n' >&2
  sed 's/^/    /' "$TEST_ROOT/hook.out" >&2
  exit 1
}

explicit="$(sed -n 's/^explicit=//p' "$MISE_CALL_LOG")"
cd_value="$(sed -n 's/^cd=//p' "$MISE_CALL_LOG")"

linked_real="$(cd "$linked_wt" && pwd -P)"
main_real="$(cd "$main_repo" && pwd -P)"

if [[ -n "$explicit" ]]; then
  _pass "hook passes the target tree explicitly, not only via --cd"
else
  _fail "hook passed no explicit tree; the task is free to re-derive it"
fi

if [[ "$explicit" == "$linked_real" ]]; then
  _pass "explicit tree is the pushed worktree"
else
  _fail "explicit tree is not the pushed worktree (got '$explicit', want '$linked_real')"
fi

if [[ "$explicit" != "$main_real" ]]; then
  _pass "explicit tree is not the main checkout"
else
  _fail "hook selected the main checkout, the tree nobody is pushing"
fi

if [[ "$cd_value" == "$linked_real" ]]; then
  _pass "--cd still names the pushed worktree"
else
  _fail "--cd is not the pushed worktree (got '$cd_value')"
fi

# ── 2. The task honours the handed tree instead of re-deriving it ────────────
# Run the real task body with the explicit variable pointing at the linked
# worktree while cwd and MISE_PROJECT_ROOT both say main checkout -- the exact
# disagreement that produced the incident.  docker is stubbed, so this observes
# only which tree the task chose.
task_body="$TEST_ROOT/drain-task.sh"
python3 - "$ROOT_DIR/mise.toml" "$task_body" <<'PY'
import re, sys
toml = open(sys.argv[1]).read()
start = toml.index('[tasks."test:docker:drain"]')
run = re.search(r'run = """(.*?)"""', toml[start:], re.S)
assert run, 'could not extract the test:docker:drain body'
body = run.group(1)
# `run = """..."""` is a TOML multi-line BASIC string, so TOML resolves its
# escapes before mise ever sees the script.  Reading the raw file skips that
# step, which would leave `\\n` in printf formats and emit literal backslash-n
# instead of newlines -- the extracted body must match what mise executes.
body = body.replace('\\\\', '\\').replace('\\"', '"')
open(sys.argv[2], 'w').write(body)
PY
[[ -s "$task_body" ]] || { printf 'FAIL: could not extract task body\n' >&2; exit 1; }

set +e
task_out="$(
  cd "$main_repo" && \
  SGT_TEST_REPO_DIR="$linked_real" \
  MISE_PROJECT_ROOT="$main_real" \
  PATH="$TEST_ROOT/bin:$PATH" \
    bash "$task_body" 2>&1
)"
set -e

if grep -Fq "Validating tree: $linked_real" <<<"$task_out"; then
  _pass "task validates the tree it was handed"
else
  _fail "task ignored the handed tree; it re-derived one"
  printf '    task output: %s\n' "$(head -3 <<<"$task_out")" >&2
fi
if grep -Fq "Validating tree: $main_real" <<<"$task_out"; then
  _fail "task validated the main checkout despite being handed another tree"
else
  _pass "task did not fall back to the main checkout"
fi

# ── 3. The validated path is reported, so a wrong tree is visible ────────────
if grep -Eq "^Validating tree: ${linked_real}\$" <<<"$task_out"; then
  _pass "task reports the host path it validated"
else
  _fail "task does not report which host tree it validated"
fi

# ── 4. Without an explicit tree the task still works (back-compat) ───────────
set +e
fallback_out="$(
  cd "$linked_wt" && \
  MISE_PROJECT_ROOT="$linked_real" \
  PATH="$TEST_ROOT/bin:$PATH" \
    bash "$task_body" 2>&1
)"
set -e
if grep -Fq "Validating tree: $linked_real" <<<"$fallback_out"; then
  _pass "manual invocation without the explicit tree still resolves cwd's tree"
else
  _fail "manual invocation broke"
  printf '    task output: %s\n' "$(head -3 <<<"$fallback_out")" >&2
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
