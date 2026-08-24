---
name: progress
description: Turn an approved PRD into an OpenSpec change, dispatch it through sergeant-v2's own /api/dispatch, and drive it to a merged, independently critic-verified state — sergeant-v2's standing builder/critic loop.
disable-model-invocation: true
---

This skill is sergeant-v2's own implementation loop: PRD → OpenSpec change → dispatch → review → mutation-test → merge → independent critic → `progress.html`. It exists so every change lands with the same rigor regardless of who (or which session) is driving. It assumes the repo at hand is sergeant-v2 (or a project following the same conventions) and that `openspec` (the CLI) is installed.

Do not skip steps to move faster. The mutation-testing and independent-critic steps exist because this loop has repeatedly caught real gaps that build/test-passing alone missed (a background loop wired but never started, a shared guard with zero test coverage, a stale-looking edge case that turned out to have live rows in the database). Treat their findings as real work, not formality.

## 0. Preconditions

- A PRD exists at `docs/prd-<slug>.md`, states **what and why only** (no API routes, function/field names, or algorithms — that is OpenSpec's job), and has explicit human approval to proceed (the user said "implement it," "feed it into openspec," or equivalent — a PRD sitting in draft is not itself authorization).
- If no PRD exists yet, write one first: `Status: Draft, awaiting explicit human PRD approval`, a `Summary`, `Problem`, `Proposal`, explicit `Out of scope`, and `Open questions`. Reference the project's existing decision ledger (`docs/prd-sergeant-v2.md`'s "Settled decisions" section, D-numbers/R-numbers/O-numbers) where the PRD extends or is served by an existing decision — most PRDs are `Extends: docs/prd-sergeant-v2.md, <decision or requirement>`.
- Confirm nothing is mid-flight that this change would conflict with: `curl -s http://localhost:8484/api/runs` and check for other active dispatches touching the same files.

## 1. Draft the OpenSpec change

Create `openspec/changes/<change-id>/`:

- `README.md` — one paragraph, plain language, what the change does and why.
- `proposal.md` — `## Repository` (which repo(s)), `## Requirements served` (link the PRD), `## Problem`, `## Proposal` (the actual mechanism — this is where "how" belongs, unlike the PRD), `## Out of scope`.
- `design.md` — concrete: exact function signatures, file locations, data shapes, migration statements, the specific existing code being read/extended/replaced. Include a `## Rejected alternatives` section with the real reasons alternatives were not chosen — a future reader (including the critic) should not have to re-litigate them.
- `specs/<area>/spec.md` — `## ADDED Requirements`, each with one or more `#### Scenario:` blocks in **WHEN/THEN** form. These scenarios are the binding acceptance criteria; the tasks file and every reviewer (including the critic) will check test coverage against them by name.
- `tasks.md` — one task per repository touched. State: what to read first (existing code, this change's own design.md), what to build, the exact verification command (`go build ./... && go vet ./... && go test ./internal/... -count=1` or the project's equivalent), and an explicit list of which spec.md scenarios need direct test coverage — call out any scenario that needs a test exercising the real mechanism directly (e.g., "call the automatic path's function directly in a test, not only through the HTTP handler it shares code with").

Validate before committing:

```
openspec change validate <change-id> --strict
```

Commit the PRD (if new) and the OpenSpec change together.

## 2. Dispatch

`POST /api/dispatch` against the running server (`agent: "claude"`, the work type from decision O2's fixed vocabulary — `feat`/`fix`/`refactor`/`docs`/`chore`/`test` — `change_id`, and the target repo(s)). The brief must tell the dispatched agent to:

- Read `openspec/changes/<change-id>/{proposal,design,tasks}.md` and `specs/<area>/spec.md` first — they are binding, not this skill's paraphrase of them.
- Read `AGENTS.md`.
- Work test-first.
- Read the specific existing files design.md names before writing anything.
- Run the exact verification command and not report done on a failing one.
- Cover every scenario named in `specs/<area>/spec.md`, including any scenario tasks.md flagged as needing the real mechanism exercised directly.

Arm a Monitor (or an equivalent poll loop) on `/api/runs` for that run id, watching for a terminal status, with a stuck-detection fallback based on **real worktree/CPU activity**, not wall-clock time alone — a dispatch that is still writing files is not stuck even if it has been running a while.

## 3. On terminal status

**If `failed`:** do not assume the diff is at fault. Inspect the actual phase output (the run's `test`/`build` phase records in the store — query the real database, e.g. `sqlite3 ~/.local/share/sergeant-v2/sergeant.db` or wherever the project's DB actually lives; do not guess the path, confirm it via the running process's open files if unsure). A failure can be:
- A real defect in the dispatched diff — fix forward in the dispatched worktree, or note the gap for a redispatch.
- An unrelated pre-existing flake the dispatch's own gate happened to trip over. Confirm this by re-running the specific failing test several times in isolation in that same worktree; if it fails intermittently and the failing test's file was not touched by this change's diff, it is not this change's problem — but it is now a **known real bug** (a flaky test is a bug) and should be fixed forward on the target branch directly, separately from this change, before proceeding.
- A genuine gap in the PRD/design itself, not an implementation slip — stop and escalate to the user rather than guessing past it.

**If `passed`:** proceed to review. Either way, once the diff itself is sound, continue below — a `failed` status caused by an unrelated flake does not block merging a diff that is otherwise correct and fully verified independently.

## 4. Review, verify, mutation-test

1. Diff against `git merge-base <target-branch> <dispatch-branch>` — **never** a bare diff against the target branch's current tip, which may have moved since dispatch.
2. Read the diff against that change's own `proposal.md`/`design.md`/`specs/*/spec.md` line by line. Confirm every named function/behavior in design.md is actually what got built, not an approximation of it.
3. Run the full verification command locally in the dispatched worktree, then again after merging.
4. Mutation-test at least one core guarantee per requirement in `spec.md` — ideally every one that's cheap to check: revert the specific guard/logic to what it would be without this change, confirm the specific test that should catch it actually fails, restore exactly, confirm `git diff` is empty.
   - **If a mutation does NOT get caught by any test:** that is a real, reportable gap — not a formality to note and move past. Write the missing test now, confirm it does catch the mutation, then restore and re-verify. This has caught real, previously-invisible holes (a safety guard with zero coverage because the only caller that could exercise it took a different code path).

## 5. Merge and clean up

Merge into the target branch with a commit message that states what was implemented and what was verified (diff reviewed against which spec, which guarantees were mutation-tested, any flake or gap found and how it was resolved). Clean up the dispatch's worktree/branch (`git status --short` first). Confirm **zero** runs show `status: "running"` in `/api/runs` before any binary rebuild — rebuilding while a dispatch is mid-flight orphans it.

If the project has a standing rebuild/restart sequence (check `AGENTS.md` or recent commit history for one), run it now. For sergeant-v2 specifically:

```
go build -o ~/.local/share/sergeant-v2/bin/sgt-p ./cmd/sergeant \
  && codesign --force --sign - --identifier "dev.sergeant.ui" ~/.local/share/sergeant-v2/bin/sgt-p \
  && launchctl kickstart -k gui/$(id -u)/dev.sergeant.ui
```

## 6. Independent critic

Spawn **one fresh, context-free agent** (no shared context with the builder — a plain subagent, not a fork) to review the merge independently. Give it:

- The exact commit(s) to review and the target branch.
- The path to `openspec/changes/<change-id>/` and an explicit instruction to read `proposal.md`/`design.md`/`specs/*/spec.md` in full *before* judging anything, and to judge against those files, not its own assumptions about what the feature should do.
- Explicit checks mirroring what design.md promised (name the specific functions/behaviors to verify), plus anything the design/spec doesn't cover but should — especially any background process or loop: confirm it is not just defined but actually **started** somewhere real (grep for the call site), since "implemented but never wired up" is a real, recurring bug class in this codebase.
- An instruction to run the full verification suite itself rather than trust that it already passed.
- An instruction to append the next sequential `Review N` entry to `progress.html` (read the file first to find the highest existing N; **never alter a prior entry** — this file is an append-only critic log), stating a clear verdict: `MEETS SPEC`, `MEETS SPEC WITH CAVEATS` (list them precisely, and say whether each is blocking against a named spec.md scenario), or `DOES NOT MEET SPEC` (explain exactly why). Commit as `docs(progress): Review N — <one-line summary>`.

## 7. Resolve the critic's findings

- `MEETS SPEC`, or `MEETS SPEC WITH CAVEATS` where every caveat is explicitly non-blocking against a named scenario: done, no further action.
- A real, reproducible gap: fix forward, mutation-test the fix the same way as step 4, re-run the full suite, commit, and rebuild+restart again if the fix touched production code (re-confirming zero runs `running` first). One further critic round is usually enough for a self-contained change; use judgment if the same subsystem keeps producing new real findings — that is a signal the change touched something more load-bearing than it looked like, not a reason to stop checking.

## Guardrails throughout

- Never invent scope beyond what the PRD and OpenSpec change actually specify. A tempting adjacent improvement is a new PRD, not scope creep on this one.
- Stop and escalate to the user, rather than guess past: a critic finding that reveals a conceptual design flaw (not an implementation slip), a dispatch failing twice for the same underlying reason, or genuine ambiguity this skill's own precedents don't resolve.
- `git status --short` before any command that could discard uncommitted work, in this worktree or a fleet worktree being cleaned up.
- If this loop is being run unattended across multiple wake-ups (e.g. via a scheduled `/loop`), state explicit boundaries up front — which initiatives are in scope, which decisions are explicitly not to be touched — so a later wake-up does not drift into inventing a new one.
