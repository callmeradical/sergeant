# Sergeant — Dead Code Audit, July 2026

> **Status (August 2026):** D-1 through D-7 actioned in PR #190 (GH #181).
> D-8 and D-9 were already resolved in the working tree before this pass;
> the audit's line numbers for those items were stale. See below for corrections.



**Scope:** All 25 scripts in `bin/`, cross-referenced against call sites in
`bin/`, `tests/`, and `skills/`.  
**Method:** Function-level call-graph analysis plus targeted variable and branch
tracing. Call counts were derived by counting non-definition occurrences of each
function name across the entire `bin/` tree.

Findings are grouped from most-impactful to least. Each entry names the file,
line, the dead artefact, and a concrete fix.

---

## Category 1 — Functions defined, never called

### D-1 🔴 `_record_dispatch_orphan` — dead helper in `sgt-dispatch`

**File:** `bin/sgt-dispatch`, line 381  
**Call sites:** 0

```bash
_record_dispatch_orphan() {
  local repo_task_dir="$1"
  local worktree_path="$2"
  local reason="$3"
  printf 'orphaned\n' > "$repo_task_dir/status"
  printf '%s\n' "$reason" > "$repo_task_dir/diagnostic"
  "$SCRIPT_DIR/sgt-td-memory" handoff "$repo_task_dir" "$worktree_path" || true
}
```

The body is identical to the inline orphan-recording block that appears at
**four** separate `_die` sites in the tmux-launch section of the same file
(lines 814–816, 826–828, 833–835, 839–841). The helper was defined to
consolidate these sites but was never wired in. The function was left in place
while the inline copies were written.

**Fix:** Either call `_record_dispatch_orphan` at all four inline sites and
delete the repeated three-liner, or delete the function entirely and leave the
inlines. The inline pattern calls `_die` immediately after, so a helper that
does not exit is the correct form — wire it up.

---

### D-2 🔴 `_require_treehouse` — dead guard in `_sgt-lib.sh`

**File:** `bin/_sgt-lib.sh`, line 365  
**Call sites:** 0

```bash
_require_treehouse() {
  command -v treehouse &>/dev/null || _die "treehouse is required: ..."
}
```

`sgt-treehouse-init` — the only script that gates on treehouse — performs its
own inline check:

```bash
command -v treehouse &>/dev/null || _die "treehouse is required: ..."
```

`sgt-dispatch` uses `command -v treehouse` directly without calling the lib
guard. No script calls `_require_treehouse`.

**Fix:** Delete the function from the lib. If `sgt-treehouse-init` and
`sgt-dispatch` should both use a consistent guard, add `_require_treehouse`
calls where they now do the check inline and keep the lib definition.

---

## Category 2 — Variables assigned, never read

### D-3 🔴 `all_results="[]"` — dead assignment in `sgt-td-list`

**File:** `bin/sgt-td-list`, line 81  
**Referenced after assignment:** never

```bash
all_results="[]"   # ← line 81, never read again

if $JSON_OUT; then
  combined="[]"    # JSON mode builds into `combined`
  …
fi
# Human mode builds a `total` counter
```

The variable was presumably a predecessor to `combined` that was renamed but
the initialisation line was not deleted. `all_results` appears exactly once:
the assignment. It has no effect.

**Fix:** Delete line 81.

---

### D-4 🟡 `session_id` in `sgt-td-memory` always reads "unavailable"

**File:** `bin/sgt-td-memory`, line 29

```bash
session_id="$(cat "$REPO_STATE/session_id" 2>/dev/null || echo unavailable)"
```

No script in the codebase writes a `session_id` file to any repo state
directory. A `grep -rn 'session_id'` across `bin/` finds this read, wiki
session-ID references in `wiki-daily-digest`, and `OPENCODE_SESSION_ID` env
var reads — none of which write the file at `$REPO_STATE/session_id`.

The resulting td handoff message always embeds `session=unavailable`, which
provides no recovery value.

**Fix:** Either (a) start writing the session ID to fleet state at dispatch or
worker-start time, or (b) remove the field from the td handoff message and
drop the dead `cat` call.

---

### D-5 🟡 `DEPS_TMP` created unconditionally; double `trap` registration

**File:** `bin/sgt-dispatch`, lines 170 and 364–365

```bash
# Line 155–170: initial temp files created, cleanup registered
INTENT_TMP="$(mktemp)"
REPO_TD_MAP="$(mktemp)"
TD_CREATE_STATE_FILE="$(mktemp)"
TD_CREATE_STDERR="$(mktemp)"
_cleanup_dispatch_tmps() {
  rm -f "$REPO_TD_MAP" "$TD_CREATE_STATE_FILE" "$TD_CREATE_STDERR" \
        "$INTENT_TMP" "${DEPS_TMP:-}"
}
trap _cleanup_dispatch_tmps EXIT    # ← first registration

# Line 364–365: deps temp file created only here
DEPS_TMP="$(mktemp)"               # ← always created, even without --deps
trap _cleanup_dispatch_tmps EXIT    # ← second registration replaces first
```

Two issues:

1. **`DEPS_TMP` is always materialised.** It is only populated when `--deps`
   is supplied, which is uncommon. The temp file is always created, always
   registered in the cleanup function, and almost always empty. The
   `${DEPS_TMP:-}` guard in `_cleanup_dispatch_tmps` was added precisely
   because DEPS_TMP didn't exist at the time of the first `trap` — but now
   it is unconditionally created.

2. **`trap _cleanup_dispatch_tmps EXIT` appears twice.** The second
   registration (line 365) silently replaces the first (line 170). This is
   harmless because both register the same function, but it signals that the
   code evolved in two passes and was never reconciled.

**Fix:** Move `DEPS_TMP="$(mktemp)"` inside the `if [[ -n "$DEPS_ARG" ]]`
block, keep only one `trap` registration (at line 170 after all four initial
`mktemp` calls), and update `_cleanup_dispatch_tmps` to guard with
`[[ -n "${DEPS_TMP:-}" ]]` before removing.

---

## Category 3 — Identical no-op function redefinitions

### D-6 🟡 `_die` redefined after `source` in `sgt-watch` and `sgt-respond`

**Files:** `bin/sgt-watch` line 12, `bin/sgt-respond` line 14  
**Lib definition:** `bin/_sgt-lib.sh` line 86

All three definitions are byte-for-byte identical:
```bash
_die() { echo "ERROR: $*" >&2; exit 1; }
```

Both scripts source `_sgt-lib.sh` *before* their local `_die` definition, so
the local definition replaces the lib version with itself. The override has no
observable effect.

**Fix:** Delete the local `_die` definitions from `sgt-watch` and `sgt-respond`.

---

## Category 4 — Diverged duplicate (should call lib)

### D-7 🟡 `_require_td` in `sgt-td-list` is a weaker version of `_require_marcus_td`

**File:** `bin/sgt-td-list`, line 21

```bash
_require_td() {
  command -v td &>/dev/null || _die "td is required. See your td installation."
}
```

The lib provides `_require_marcus_td` which additionally checks the version
output format and verifies `--work-dir` support in `td create --help`. A user
with an incompatible `td` binary (wrong implementation, missing flags) gets a
working `sgt-td-list` invocation that then fails silently when `td list
--json --work-dir` is called.

**Fix:** Delete `_require_td` from `sgt-td-list` and call `_require_marcus_td`
(already available via the sourced lib).

---

## Category 5 — Duplicate function bodies (should live in lib)

These were flagged in the main audit as a factoring issue; they are also
dead code in the sense that one copy of each is unreachable from the other
script's context.

### D-8 `_worktree_cwd_pids` defined in both `sgt-cleanup` and `sgt-validate`

**Files:** `bin/sgt-cleanup` line 45, `bin/sgt-validate` line 68  
Bodies are functionally identical (same `lsof` invocation, same line parser).

### D-9 `_process_group_pids` defined in both `sgt-cleanup` and `sgt-validate`

**Files:** `bin/sgt-cleanup` line 123, `bin/sgt-validate` line 101 (July audit)

> **August 2026 correction:** `_process_group_pids` is defined only in
> `bin/sgt-cleanup` in the current working tree. `bin/sgt-validate` uses
> `pgrep -g` inline and no longer defines a separate helper. D-9 as stated
> is already resolved; no further action required.

---

## Summary table

| ID | File | Artefact | Kind | Status (Aug 2026) |
|---|---|---|---|---|
| D-1 | `sgt-dispatch` | `_record_dispatch_orphan()` | Function never called | ✅ Deleted (PR #190) |
| D-2 | `_sgt-lib.sh` | `_require_treehouse()` | Function never called | ✅ Deleted (PR #190) |
| D-3 | `sgt-td-list` | `all_results="[]"` | Variable never read | ✅ Deleted (PR #190) |
| D-4 | `sgt-td-memory` | `session_id` cat from unwritten file | Always reads "unavailable" | ✅ Removed field (PR #190) |
| D-5 | `sgt-dispatch` | `DEPS_TMP` + double `trap` | Unconditional mktemp + redundant trap | ✅ Fixed: conditional mktemp, one trap (PR #190) |
| D-6 | `sgt-watch`, `sgt-respond` | `_die()` redefinitions | Identical no-op shadow | ✅ Deleted both local copies (PR #190) |
| D-7 | `sgt-td-list` | `_require_td()` | Weaker diverged copy of lib function | ✅ Deleted; calls `_require_marcus_td` (PR #190) |
| D-8 | `sgt-cleanup`, `sgt-validate` | `_worktree_cwd_pids()` | Alleged duplicate | ✅ Already resolved before this pass; `sgt-validate` uses `lsof -t +D` inline |
| D-9 | `sgt-cleanup`, `sgt-validate` | `_process_group_pids()` | Alleged duplicate | ✅ Already resolved before this pass; `sgt-validate` uses `pgrep -g` inline |

---

## What was checked and found clean

- All other functions with 1 apparent call site were verified to be genuinely
  called (the grep counts include the definition line for some patterns, so
  apparent 1-calls were spot-checked).
- `_sgt_bash_version_supported` has one caller (`_sgt_require_bash_version`)
  within the same file — intentional helper, not dead.
- `_cleanup_response_input` is called three times in `sgt-respond` by design:
  once via the `_cleanup_respond` trap, and once explicitly in each of the two
  early-exit fast paths before `trap - EXIT` is issued. Not dead.
- `_pane_is_supervisor` is defined twice (sgt-watch and sgt-respond) with
  different bodies — the sgt-watch version has migration logic, not a copy.
  Flagged in the main audit as a factoring issue, not dead code.
- `TD_CONTEXT` and `TD_REPO` are both read after being set (`sgt-dispatch`
  lines 616, 628–629) — not dead despite the late read.
- `OC_SESSION` and the OC registry block in `sgt-dispatch` are live: the
  computed value is written to `oc_target.json` and consumed by `sgt-notify`.

*Audit conducted against commit state as of 2026-07-25.*
