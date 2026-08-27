# Product Requirements: Settings Page

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` R7.3 (the embedded UI can list
projects, show project details, and "refine supported project
configuration" without becoming a second execution engine).

## Summary

Sergeant v2 has no settings surface in its dashboard today. Project-level
defaults already exist in the config schema and already have a
patch-preserving API to edit them (`POST /api/refine-project`), but
nothing in the UI calls it, and the patch payload itself doesn't cover
every field the schema defines. This PRD adds a settings page to the
dashboard, and closes the specific gap that motivated it: an operator
should be able to configure, per project, which agent harness and which
model a dispatch uses by default — without hand-editing YAML.

## Problem

`internal/config/config.go`'s `ProjectDefaults` already has `Agent` and
`Model` fields (`yaml:"agent,omitempty"`/`yaml:"model,omitempty"`), and
`POST /api/refine-project` (`internal/ui/refine.go`) already implements a
general, comment-and-order-preserving YAML-node patch mechanism for
project config — confirmed real and working for `Defaults.Agent`
(`refinePayload.Defaults.Agent *string`). But:

- `refinePayload.Defaults` has no `Model` field at all — the patch
  mechanism was never extended to cover it, even though the underlying
  config schema already supports it.
- Nothing in `internal/ui/static/index.html` calls `/api/refine-project`
  anywhere — a grep for `refine-project`/`refineProject` across the
  frontend returns zero matches. The endpoint exists and is reachable by
  direct API call, but there is no UI surface for it today.
- `/api/dispatch`'s request body accepts a per-call `Agent` override
  (validated against `runner.SupportedAgents`: `opencode`, `oc`,
  `claude`, `goose`, `codex`, `pi`, `copilot`) but has no equivalent
  `Model` override field, and no validation function for a model string
  exists anywhere (`Model` is accepted as an unvalidated free string).

So the actual gap is narrower than "build agent/model configuration from
scratch": the schema and half the patch mechanism already exist. What's
missing is the settings page itself, the `Model` field in the patch
payload, and (per the user's own framing of this request) confirming
whether agent/model should be a project-level default, a per-dispatch
choice, or both.

## Proposal

1. **A settings page** in the dashboard, reachable from the existing
   project-detail view, as a new panel/tab alongside the existing
   run-list and delivery-status views R7.3 already describes.
2. **Project-level default agent and model**, editable on that page,
   backed by extending `refinePayload.Defaults` with `Model *string`
   (mirroring the existing `Agent *string` field exactly) and wiring the
   settings page to call `POST /api/refine-project`.
3. **Validation surfaced in the UI, not just the API.** `ValidateAgent`
   already exists server-side; the settings page should show the
   accepted agent list (`runner.SupportedAgents`) as a real choice
   control, not free text, so an operator can't save an unsupported
   value. Model has no equivalent accepted-list validation today — see
   Open Questions.
4. This page is also the natural home for the dispatch-admission-control
   budget setting from `docs/prd-dispatch-admission-control.md`'s first
   open question, if that PRD proceeds — one settings surface, not two.

## Non-Goals

- Building a general-purpose settings framework for every possible
  config field on day one. Agent/model defaults are the concrete,
  requested starting point; the page's structure should not preclude
  adding more settings later, but this PRD does not enumerate them.
- Per-repo agent/model overrides beyond what already exists in the
  schema (`Repo` has no `Agent`/`Model` fields today — only
  project-level `Defaults` does). Adding repo-level overrides is a
  separate decision, not assumed here.
- Changing `ValidateAgent`'s accepted list or adding model validation
  logic beyond what's needed to surface the existing list in the UI.
- Authentication/authorization for who can change settings. Matches the
  existing single-user, local-first, loopback-only trust model.

## Acceptance Criteria

- A settings page exists in the dashboard and is reachable from the
  project-detail view.
- An operator can view and change a project's default agent from a
  choice control populated from `runner.SupportedAgents`, and the
  change persists via `POST /api/refine-project`.
- An operator can view and change a project's default model, and the
  change persists via the same endpoint (`refinePayload.Defaults.Model`
  added, patch-preserving behavior unchanged for every other field).
- Saving a new default takes effect on the next dispatch for that
  project without requiring a server restart.
- Regression coverage: saving a settings change preserves every other
  key in the project's YAML file byte-for-byte except the changed
  field(s) (matching `refine.go`'s existing node-patch guarantee).

## Open Questions

1. Should model be a per-dispatch override too (mirroring `Agent`'s
   existing `req.Agent` field on `/api/dispatch`), or project-default
   only? The user's framing ("configure or set what agent type... what
   model") suggests project-level defaults are the primary ask; a
   per-call override can be a fast-follow if needed.
2. Should the settings page validate model strings against a known-good
   list per provider (the way agent already is), or accept free text
   given the wide and fast-moving range of model identifiers? If
   validated, where does that list come from — a static table, or a
   live query to the provider?
3. What other settings belong on this page at launch — is agent/model
   the only field for v1 of this page, or should it also expose
   `Retries` (already in `ProjectDefaults`) and the dispatch-admission
   budget (if that PRD ships first)?
4. Is there a global (cross-project) settings layer intended eventually
   (e.g. a server-wide default agent/model applied when a project sets
   none), or is every setting strictly project-scoped?
