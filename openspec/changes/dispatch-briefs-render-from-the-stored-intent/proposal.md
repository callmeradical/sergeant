# Proposal — Dispatch briefs render from the stored intent

## Repository

One repository: `sergeant-v2`.

## Requirements served

**D1** — "Two ways in, one set of records": agent-driven (MCP) and
coordinator-driven (UI dispatch) both create the same intents, bullets and
evidence.

**D4** — "Sergeant stores intents and bullets itself": intents and bullets
are first-class rows with referential integrity; a second durable copy
elsewhere is not needed for a fact already recorded here.

PRD: `docs/prd-canonical-intent-brief.md`.

## Problem

The two dispatch paths D1 requires to "create the same intents, bullets and
evidence" do not describe the same work identically:

- The UI-dispatched path passes the caller's raw HTTP request text straight
  through as the agent's entire prompt. `internal/dag/engine.go:353`:
  `prompt := stage.Brief`, falling back to a generic one-line string
  (`fmt.Sprintf("Execute %s phase for stage %s on %s", ...)`,
  `engine.go:354-356`) when empty. Neither branch reads the bullet's
  lifecycle state, its position in the intent's merge order, or the
  OpenSpec change it resolved to (O3) — all of which already exist as
  fields on the `IntentRecord`/`BulletRecord` rows created earlier in the
  same request (`internal/ui/server.go`'s `handleDispatch`/
  `createRunAndDispatch`).
- `sergeant_get_brief`, the MCP tool D1 names as the agent-driven path's way
  to get context, is registered with the description "Get the intent
  brief, acceptance criteria, and worktree paths for a project stage"
  (`internal/mcp/server.go:101-109`) but its implementation
  (`internal/mcp/server.go:298-305`) calls `config.LoadProject(projName)`
  and dumps the raw project YAML config — no intent, no bullet, no
  acceptance criteria. The registered description already promises what
  this proposal builds; the implementation does not provide it.

This also leaves no durable, human-readable artifact answering "what was
this bullet actually asked to do" outside a direct database query or the
dashboard — the role v1's `.sergeant-intent.md` played, now unfilled.

## Proposal

Add `Store.RenderIntentBrief(intentID, repo string, gates []string) (string,
error)` (`internal/store/`, new file): loads the `IntentRecord` via the
existing `GetIntent`, finds the one `BulletRecord` for `repo` via the
existing `ListBulletsForIntent`, and renders a single Markdown document from
their fields (statement, repo, position, status, blocked reason if any,
change id/repo, and the caller-supplied gate names). It touches no new
schema and performs no write.

Change both call sites to use it instead of constructing their own text:

- `internal/dag/engine.go`'s `RunStage`: replace `prompt := stage.Brief` with
  a call to `e.Store.RenderIntentBrief(run.IntentID, repoName, gateNames)`
  (the run is already loadable via `e.Store.GetRun(runID)`; `gateNames`
  is the same `SortedGateNames(repoCfg)` this function already computes for
  the `"test"` phase branch immediately above). Retain `stage.Brief` as the
  fallback exactly when a run has no intent id (pre-existing runs, or a
  caller that predates this change) so this proposal introduces no new
  failure mode for that case.
- `internal/mcp/server.go`'s `sergeant_get_brief` case: change its
  `InputSchema` from `project` (required) to `intent_id` (required) and
  `repo` (required) (`server.go:101-109`); the implementation
  (`server.go:298-305`) calls `s.Store.GetIntent(intentID)` to learn the
  project, loads that project's config the same way `sergeant_run_gates`
  already does (`server.go:307+`) to compute the repo's configured gate
  names, and calls the same `RenderIntentBrief`.

## Out of scope

- **An intent-wide brief spanning every bullet.** The PRD leaves this an
  open question; this proposal builds only the per-bullet brief both
  current call sites actually need today.
- **Any new schema or stored field.** Every input to the rendering already
  exists on `IntentRecord`/`BulletRecord`.
- **A second durable copy of the rendered brief on disk or in the store.**
  Rejected below.
- **Changing `sergeant_get_brief`'s tool name or removing it.** Only its
  input schema and implementation change.
