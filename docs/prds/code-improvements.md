# Product Requirements: Code Improvements

Status: Draft

Audit baseline: current as of `2026-07-25`, after the following simplifications
already landed: `d08ecfc`/`80825e1` removed remote execution support (−1,500
lines of tests, gutted `sgt-watch`, `sgt-respond`, and `sgt-dispatch`);
`45cfd98` deprecated `oc-inject` and simplified `sgt-notify`. The findings
below reflect work remaining after those changes.

Audit source: `docs/audit-2026-07.md` and `docs/dead-code-2026-07.md`

Related epic: td-4ffd5e "Code improvements" P0

---

## Summary

A July 2026 audit of the 25 Sergeant `bin/` scripts, shared libraries, schema,
and docs identified two correctness bugs with data-loss risk, nine dead-code
artifacts, two duplicate function bodies, and a set of simplicity, elegance,
and performance improvements. The audit also identified four architectural gaps:
missing fleet state versioning, undocumented notification protocol, missing
cancel command, and ambiguous tool placement.

This PRD defines the acceptance criteria and delivery scope for correcting
these findings. It is organized by priority tier matching the audit's
recommendations. Tier 1 corrections are blocking; lower tiers are non-blocking
but required before this epic closes.

---

## Users

- **Agent operators:** run Sergeant commands; affected by incorrect orphan
  classification and unrolled TD tasks after dispatch failures.
- **Maintainers:** read, modify, and extend Sergeant scripts; affected by
  duplicate helpers, inconsistent Python styles, and undocumented protocols.
- **Human operators:** invoke `sgt-cancel` and `sgt-cleanup`; affected by
  missing cancel command and opaque cleanup blockers.

---

## Problem

The audit found two categories of correctness problem:

**C-1 (data loss risk):** When `sgt-dispatch` fails during the worktree loop,
TD tasks created for earlier repos are not rolled back. Fleet state for those
repos is recorded as `dispatched` with no matching worker process. There is no
way to clean this state without manual intervention.

**C-2 (false orphan):** `sgt-watch --sync` treats `dispatched` status the same
as `in_progress` when checking pane liveness. Because a worker writes
`in_progress` only after `sgt-interactive-worker` initializes — a seconds-wide
window — a sync run during that window incorrectly marks the worker orphaned.

Beyond correctness, nine dead-code artifacts accumulate maintenance surface
with no runtime value, and scattered Python invocations, duplicate helpers,
and per-field `yq` loops make the scripts harder to read and slower to run.

---

## Product Principle

Each finding must reach a documented resolution: corrected, deleted, or
explicitly accepted with a dated rationale. No finding may be left in an
undated limbo. A finding that cannot be corrected in this cycle is recorded
in its owning td task with an expiry date and reopened when that date passes.

---

## Non-Goals

- Rewriting the Sergeant toolbelt in a new language.
- Changing any externally observable command behavior beyond the documented
  bug fixes.
- Adding new Sergeant features as part of this cleanup pass.
- Migrating fleet state or worker protocol contracts.

---

## Tier 1 — Correctness / Data Loss (blocking)

### C-1: TD task rollback on worktree failure (`sgt-dispatch`)

**Finding:** `sgt-dispatch` creates TD tasks for all target repos before the
per-repo worktree loop. If worktree creation fails for repo N, TD tasks for
repos 1 through N are already created and not rolled back. Fleet state for
those repos is `dispatched` with no matching process.

**Required fix:**

- Accumulate successfully-dispatched repos in an array inside the per-repo
  loop.
- Register a cleanup trap around the dispatch loop that rolls back created TD
  tasks and removes orphaned fleet state directories when the loop exits with
  an error.
- `_rollback_generated_td_tasks` is already defined but not called at worktree
  failure sites; wire it up at all four inline sites (lines 814–816, 826–828,
  833–835, 839–841 at audit baseline) or call the existing helper and delete
  the inlines.

**Acceptance:**

1. A simulated worktree creation failure for repo N causes TD tasks for repos
   1 through N to be rolled back and their fleet state directories to be
   removed.
2. Existing dispatch tests pass without modification.
3. A successful dispatch is unaffected by the new trap.

### C-2: False orphan on `dispatched` status (`sgt-watch`)

**Finding:** `sgt-watch --sync` checks pane liveness for repos in `dispatched`
status the same way it does for `in_progress`. Because `dispatched` is the
initial status before the worker initializes, a sync run during initialization
incorrectly marks the worker orphaned.

**Required fix:**

- Do not run the orphan pane-liveness check for repos in `dispatched` status.
- Only check pane liveness after status has advanced to `in_progress`.
- Add a comment explaining the race window and the invariant that
  `dispatched` may have no confirmed pane identity.

**Acceptance:**

1. A `sgt-watch --sync` run during the dispatched-to-in_progress window does
   not write `orphaned` to fleet state.
2. A repo that is genuinely orphaned after reaching `in_progress` is still
   correctly classified.
3. Existing watch tests pass.

---

## Tier 2 — Simplicity (high ROI, low risk)

### S-1: Worker brief extracted from `sgt-dispatch` heredoc

**Finding:** `sgt-dispatch` embeds a ~200-line worker brief as a heredoc,
making the file 41 KB and the brief difficult to diff or edit independently.

**Required fix:**

- Extract the brief to `templates/worker-brief.md` with `{{PLACEHOLDER}}`
  tokens for the interpolated values.
- Add a `_sgt_render_template` helper to `_sgt-lib.sh` using `envsubst` or
  a pure-bash token substitution loop.
- Update `sgt-dispatch` to call the helper instead of the heredoc.

**Acceptance:**

1. `sgt-dispatch` file size decreases by at least 10 KB.
2. `templates/worker-brief.md` contains the full brief with placeholders.
3. A test verifies that every placeholder in the template is substituted.
4. The rendered brief matches the previous heredoc output for the same input
   values.

### S-2: Duplicate process-management helpers promoted to shared lib

**Finding:** `_worktree_cwd_pids` and `_process_group_pids` are defined
independently in `sgt-cleanup` and `sgt-validate` with identical bodies.

**Required fix:**

- Promote `_worktree_cwd_pids`, `_process_group_pids`, `_terminate_pids`, and
  `_terminate_process_group` to `_sgt-lib.sh`.
- Delete the local copies from `sgt-cleanup` and `sgt-validate`.
- Update `sgt-cleanup` and `sgt-validate` to call the lib versions.

**Acceptance:**

1. No duplicate function body remains across `sgt-cleanup`, `sgt-validate`,
   and `_sgt-lib.sh`.
2. All existing cleanup and validate tests pass.

### S-4: `oc-inject` prototype resolved

**Finding:** `oc-inject` carries a `# DELETE when prototype question is
answered.` comment with no issue number, no question, and no timeline. The
script is 4.5 KB, symlinked by `mise install`, and referenced by `sgt-notify`.

**Prior work:** `45cfd98` ("refactor: deprecate OpenCode notification
injection") added a runtime deprecation warning to `oc-inject` and simplified
`sgt-notify` to prefer durable fleet state and `sgt-watch`. The prototype
comment and script remain; the deprecation warning is a partial resolution.

**Required fix (complete the decision started in 45cfd98):**

- **Delete (preferred, consistent with the deprecation):** remove `oc-inject`,
  update `sgt-notify` to use tmux fallback only, remove the symlink from
  `mise.toml`, and delete `docs/oc-inject.md`.
- **Promote:** if the prototype is to be kept, remove the prototype comment,
  remove the deprecation warning, document stable behavior in `docs/oc-inject.md`,
  and add tests for the core delivery loop.

The decision must be recorded in this PRD or in an owning td task.
The prototype comment must not remain in the shipped script.

**Acceptance:**

1. `oc-inject` either has no prototype comment and passes a basic delivery
   test, or it is deleted and `sgt-notify` compiles and passes tests without
   it.
2. `mise run install` does not fail after the change.

---

## Tier 3 — Elegance and Performance

### E-1: Remove `_die` redefinition in `sgt-respond` and `sgt-watch`

**Finding:** Both scripts redefine `_die` after sourcing `_sgt-lib.sh`. The
redefinition is byte-for-byte identical to the lib definition.

**Fix:** Delete the local `_die` definitions from `sgt-respond` and
`sgt-watch`.

### E-2: Standardize Python invocation style

**Finding:** Four distinct Python invocation forms are used across seven
scripts.

**Fix:** Adopt `python3 - "$arg1" "$arg2" <<'PY'` everywhere — positional
arguments via `sys.argv`, script as heredoc, no environment injection.
Apply consistently across all affected scripts.

### E-5 / P-1: Single-call `yq` repo lookup

**Finding:** `sgt-dispatch`, `sgt-td-create`, `sgt-context`, `sgt-status`, and
`sgt-sync` each issue 8–10 `yq` subprocess calls per repo. For a 10-repo
project this is 800–3200 ms of `yq` startup time.

**Fix:** Add `_sgt_repo_fields_json` to `_sgt-lib.sh`:

```bash
_sgt_repo_fields_json() {
  local config="$1" rname="$2"
  yq -o=json ".repos[] | select(.name == \"$rname\")" "$config"
}
```

Update all five scripts to call `_sgt_repo_fields_json` once per repo and
parse with `jq` or Python for individual fields.

### P-2: Single Python pass in `sgt-td-list` JSON mode

**Finding:** JSON mode spawns two Python processes per repo (one to tag, one to
merge-sort). For a 10-repo project this is 20 Python subprocess launches.

**Fix:** Collect all `td list` JSON output into a bash array (one `td` call
per repo), then pass all of it to a single Python process that tags and
merges in one pass.

### C-4: `_sgt_detect_agent` default

**Finding:** `_sgt_detect_agent` defaults to `opencode` when no env vars match,
causing confusing failures for Goose-only users.

**Fix:** Default to empty string; update `_require_interactive_agent` to print
a useful install hint when the agent is empty.

### C-5: YAML `name` checked against filename

**Finding:** A project file named `smith.yaml` with `name: jones` silently
emits confusing output.

**Fix:** Add to `sgt-context`:

```bash
yaml_name="$(yq '.name' "$CONFIG_FILE")"
[[ "$yaml_name" == "$PROJECT" ]] || \
  _die "Project name mismatch: file is $PROJECT.yaml but name: $yaml_name"
```

### C-7: Fix `wiki-daily-digest` default model name

**Finding:** Default is `claude-haiku-4-5`, which does not match any known
Anthropic model identifier and produces an API error on every invocation.

**Fix:** Update the default to a current, real model name; verify it against
the Anthropic API before shipping.

---

## Dead Code Removal

All nine findings from `docs/dead-code-2026-07.md` must be resolved.

| ID | File | Artifact | Resolution |
|---|---|---|---|
| D-1 | `sgt-dispatch:381` | `_record_dispatch_orphan()` never called | Wire up at the four inline sites (preferred) or delete |
| D-2 | `_sgt-lib.sh:365` | `_require_treehouse()` never called | Delete or wire up in callers |
| D-3 | `sgt-td-list:81` | `all_results="[]"` never read | Delete the assignment |
| D-4 | `sgt-td-memory:29` | `session_id` always reads "unavailable" | Write session ID at dispatch time, or drop the field |
| D-5 | `sgt-dispatch:364–365` | `DEPS_TMP` unconditional mktemp + double trap | Move mktemp inside `--deps` block; one trap registration |
| D-6 | `sgt-watch:12`, `sgt-respond:14` | `_die()` identical no-op redefinition | Delete both local copies |
| D-7 | `sgt-td-list:21` | `_require_td()` weaker diverged copy | Delete; call `_require_marcus_td` from lib |
| D-8 | `sgt-cleanup:45`, `sgt-validate:68` | `_worktree_cwd_pids()` duplicate | Promote to lib (covered by S-2); delete local copies |
| D-9 | `sgt-cleanup:123`, `sgt-validate:101` | `_process_group_pids()` duplicate | Promote to lib (covered by S-2); delete local copies |

**Acceptance for each dead-code finding:**

1. The dead artifact does not appear in the shipped codebase.
2. The replacement (wire-up, lib promotion, or deletion) passes relevant tests.
3. No new dead code is introduced as a side effect.

---

## Tier 4 — Architecture (non-urgent, required before epic close)

### A-1: Fleet state schema version

Add a `schema_version` file written at dispatch time to
`$FLEET_DIR/$TASK_ID/schema_version`. The file contains a monotonically
increasing integer. Migration code in individual scripts must reference this
file rather than detecting schema version by field presence.

**Acceptance:** `sgt-dispatch` writes `schema_version`; existing fleet state
without the file is treated as version 0 (legacy).

### A-2: Notification protocol documentation

Write `docs/notification-protocol.md` describing the file names, field names,
proof-chain semantics, and invariants for the notification and response
protocol. The document must be derived from the source, not from memory.

**Acceptance:** The document is reviewed and merged; at least one invariant
from the protocol is verified by a test that references the document.

### A-3: `sgt-cancel` command

Implement `sgt-cancel <task-id> --reason <reason>`. The command must:

- Mark all non-terminal repos as `failed: cancelled` in fleet state.
- Stop live workers through existing supervision (SIGTERM, then verify).
- Call `sgt-cleanup` after all workers reach terminal state.
- Require an interactive terminal confirmation before stopping any process.
- Record a cancellation reason in fleet state.

**Acceptance:** `sgt-cancel` stops all workers, records the reason, and runs
cleanup for a task with one live and one non-live worker without manual
intervention.

### S-3: `wiki-daily-digest` placement decision

Decide and document whether `wiki-daily-digest` remains in `bin/` or moves to
`tools/` or a separate repository. The decision must be recorded in this PRD
or in an owning td task. If it stays in `bin/`, add a comment explaining why.
If it moves, update `mise.toml` and the README toolbelt table.

### A-6: Rename `sgt-td-memory`

Rename `sgt-td-memory` to `sgt-td-checkpoint` or `sgt-td-handoff` to better
convey its purpose. Update all call sites and symlinks.

### E-3: Remove `sgt-watch` migration path for `_pane_is_supervisor`

Verify whether any active fleet state lacks a `pane_identity` file. If none
do, remove the migration fallback branch in `sgt-watch`'s
`_pane_is_supervisor` and collapse it to a one-liner calling the lib function.
Add a comment with the verification date.

### C-3: `_migrate_legacy_response_state` expiry date

Add a comment to `_migrate_legacy_response_state` in `sgt-respond` stating
the date it was added, the schema version it migrates from, and the date after
which it is safe to remove (target: 2026-Q4).

### C-8: `_sgt-response-lock.sh` format documentation

Document which lock format (hardlink or directory) is current. If the directory
branch is legacy, add a dated removal comment.

---

## Measurable Acceptance Criteria

1. C-1: A simulated worktree failure rolls back all created TD tasks for that
   dispatch run; no orphaned fleet state directories remain.
2. C-2: `sgt-watch --sync` does not write `orphaned` for a repo in `dispatched`
   status during the initialization window.
3. D-1 through D-9: No dead artifact from the dead-code audit appears in the
   shipped codebase.
4. S-1: `sgt-dispatch` file size decreases by at least 10 KB; brief template
   test passes.
5. S-2: No duplicate function body across `sgt-cleanup`, `sgt-validate`, and
   `_sgt-lib.sh`.
6. E-5 / P-1: Per-repo `yq` subprocess count is 1 in affected scripts for any
   repo lookup.
7. P-2: `sgt-td-list` JSON mode spawns at most 1 Python process for any
   project size.
8. A-1: `sgt-dispatch` writes `schema_version` to every new fleet state
   directory.
9. A-2: `docs/notification-protocol.md` exists, is reviewed, and at least one
   protocol invariant is verified by a test.
10. A-3: `sgt-cancel` stops workers, records reason, and runs cleanup without
    manual intervention.
11. The full shell test suite passes after every tier of changes.
12. No new dead code, duplicate helper, or undocumented migration is introduced.

---

## Delivery Boundary

Tier 1 findings (C-1, C-2) are blocking and must ship first. Tiers 2–4 may be
batched and delivered in any order after Tier 1. The epic closes only when all
tiers are complete and the full acceptance criteria are verified.
