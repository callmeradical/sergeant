# Product Requirements: Settings Page

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md` R7.3 (the embedded UI can list
projects, show project details, and "refine supported project
configuration" without becoming a second execution engine).

## Summary

Sergeant v2 has no settings surface today, at any level: no global
settings store exists at all (confirmed — no `dev_root`, `DevRoot`, or
equivalent global-config concept anywhere in `internal/config`, unlike
v1's `~/.config/sergeant/config.yaml`), and the one piece of
project-level settings machinery that does exist
(`POST /api/refine-project`) has no UI calling it and doesn't cover every
field the schema defines. This PRD adds a settings page with two tiers —
**global defaults, overridable per project** — starting with agent,
model, a base directory repos resolve under, and feature flags; agent
and model additionally get a third tier, a per-dispatch override,
mirroring how `Agent` already works on `/api/dispatch` today.

## Problem

`internal/config/config.go`'s `ProjectDefaults` already has `Agent` and
`Model` fields (`yaml:"agent,omitempty"`/`yaml:"model,omitempty"`), and
`POST /api/refine-project` (`internal/ui/refine.go`) already implements a
general, comment-and-order-preserving YAML-node patch mechanism for
project config — confirmed real and working for `Defaults.Agent`
(`refinePayload.Defaults.Agent *string`). But:

- **There is no global settings layer at all.** Every setting today is
  either compiled-in or per-project. `config.LoadProject` resolves a
  named project's own YAML file; nothing loads a machine-wide default
  first. v1 had exactly this concept (`~/.config/sergeant/config.yaml`'s
  `dev_root`), and v2 has no equivalent — a project that wants a setting
  today must repeat it in every project file.
- **Repo paths have no base-directory resolution.** `Repo.Path` is used
  as-is (only `~/`-prefix expansion exists, inline in
  `internal/mcp/server.go`'s `sergeant_run_gates` handler — not even in
  `config.go` itself); there is no concept of "resolve this repo's path
  relative to a configured base directory" the way v1's `dev_root`
  worked. Adding a global "dev folder base" setting requires adding this
  resolution, not just storing a string.
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
- **No feature-flag concept exists anywhere** in the codebase (confirmed
  by grep — zero hits for any spelling of "feature flag"). This would be
  new from scratch, not an existing mechanism missing a UI.

## Proposal

1. **A new global settings store.** A single file (mirroring v1's
   `~/.config/sergeant/config.yaml` precedent — e.g.
   `~/.config/sergeant/settings.yaml`, distinct from any per-project
   YAML) holding machine-wide defaults: agent, model, the dev-folder
   base directory, and feature flags. Loaded once, read by every place
   that currently only consults project-level `Defaults`.
2. **Two-tier resolution for every setting: global default, overridable
   per project.** A project's own `Defaults` (or a new per-project
   settings block, for fields that don't already live in
   `ProjectDefaults`) wins when set; otherwise the global value applies.
   This is the general shape every setting on this page follows.
3. **A settings page** in the dashboard with (at minimum, for this
   PRD's launch scope) four sections: default agent, default model, dev
   folder base, and feature flags — each showing its resolved value
   (global vs. project-overridden) and which tier is in effect.
4. **Agent and model additionally get a third tier: per-dispatch
   override**, exactly mirroring `Agent`'s existing behavior on
   `/api/dispatch` (`req.Agent` overrides `proj.Defaults.Agent` for one
   call). This PRD adds the equivalent `Model` field to that same
   request body. Dev-folder-base and feature flags are not given a
   per-dispatch override in this PRD — a single dispatch call has no
   natural per-call meaning for "use a different repo base directory"
   or "toggle a flag for one run," so that tier is deliberately not
   added for those two.
5. **Validation surfaced in the UI, not just the API.** `ValidateAgent`
   already exists server-side; the settings page shows the accepted
   agent list (`runner.SupportedAgents`) as a real choice control, not
   free text. **Model strings are validated too** (settled below) —
   against a known-good list per provider, not accepted as free text.
6. **Dev-folder-base resolution.** A repo path that is not already
   absolute resolves relative to the configured dev-folder base (global
   or project-overridden) — the actual missing mechanism identified in
   Problem, not just a stored string with no effect.
7. **Feature flags: a simple named boolean registry**, global default
   per flag, overridable per project, checked at the specific call
   sites that need to branch on them (which flags ship at launch is an
   open question below, since none exist today to migrate).
8. This page is also the natural home for the dispatch-admission-control
   budget setting from `docs/prd-dispatch-admission-control.md`'s first
   open question, if that PRD proceeds — one settings surface, not two.

## Non-Goals

- Building a general-purpose settings framework that anticipates every
  future field. This PRD's four sections (agent, model, dev-folder-base,
  feature flags) are the concrete, requested launch scope; the page's
  structure should not preclude adding more later, but this PRD does
  not enumerate them.
- Per-repo agent/model overrides beyond what already exists in the
  schema (`Repo` has no `Agent`/`Model` fields today — only
  project-level `Defaults` does). Adding repo-level overrides is a
  separate decision, not assumed here.
- A per-dispatch override for dev-folder-base or feature flags — see
  Proposal item 4 for why.
- Authentication/authorization for who can change settings. Matches the
  existing single-user, local-first, loopback-only trust model.

## Acceptance Criteria

- A global settings store exists, is loaded once, and is consulted
  wherever a setting is resolved.
- A settings page exists in the dashboard, showing global defaults and
  allowing project-level overrides, reachable from the project-detail
  view for the project tier and from a top-level settings entry point
  for the global tier.
- An operator can view and change the default agent (choice control
  populated from `runner.SupportedAgents`) and default model (choice
  control populated from a known-good per-provider list) at both the
  global and project tier; a project-level change persists via
  `POST /api/refine-project` (`refinePayload.Defaults.Model` added).
- Saving a new default takes effect on the next dispatch without
  requiring a server restart.
- `/api/dispatch` accepts an optional `Model` field, applied over the
  resolved default (project override, else global) the same way `Agent`
  already overrides `Defaults.Agent`.
- A repo path that is not already absolute resolves relative to the
  resolved dev-folder-base setting (project override, else global).
- At least one feature flag exists end-to-end (global default,
  project-overridable, read at a real call site) as a working example
  of the mechanism, even if it flags something low-stakes for launch.
- Regression coverage: saving a project-level override preserves every
  other key in that project's YAML file byte-for-byte except the
  changed field(s) (matching `refine.go`'s existing node-patch
  guarantee); a dispatch with an explicit `Model` override produces a
  run using that model regardless of any configured default at either
  tier.

## Settled Decisions

1. **Two-tier settings: global default, overridable per project.** Not
   project-scoped-only as originally drafted — a global layer is
   required, and this PRD must build it since none exists today.
2. **Agent and model get a third tier on top: per-dispatch override**,
   mirroring `Agent`'s existing `/api/dispatch` behavior exactly.
3. **Model strings are validated** against a known-good list per
   provider, not accepted as free text.
4. **Launch scope for this PRD: agent, model, dev-folder base, and
   feature flags.** `Retries` and the dispatch-admission budget are
   explicitly deferred, not launch-blocking.
5. **The global settings file lives under `~/.config/sergeant/` on
   macOS and Linux** — deliberately preserving v1's exact convention
   rather than switching to Go's OS-idiomatic default (`os.UserConfigDir()`
   returns `~/Library/Application Support` on macOS, not `~/.config`).
   **On Windows, use the OS-appropriate location instead** (e.g.
   `os.UserConfigDir()`'s own Windows result, typically
   `%AppData%\sergeant`) rather than forcing the same Unix dotfile
   convention onto a platform where it's foreign. Concretely: branch on
   `runtime.GOOS`, hardcode `~/.config/sergeant` for `darwin`/`linux`,
   defer to `os.UserConfigDir()` for everything else.
6. **The per-provider model list is pulled from `models.dev`**
   (`https://models.dev/api.json`), the same source the user's own
   `token-meter` project already fetches from
   (`TokenMeter/Pricing/PricingStore.swift`) — not a hand-maintained
   static table and not a from-scratch live-query design. `token-meter`
   already has a reusable Go client for this
   (`github.com/lcromley/tokenmeter-client`'s `PricingStore`: fetches
   `models.dev/api.json`, ETag-caches it to disk, keyed by
   `providerID/modelID`) — reuse or vendor that fetch/cache logic rather
   than reimplementing it, since the settings page needs the same
   provider/model identifiers that package already parses out of the
   same response (it happens to also carry pricing, which this PRD has
   no use for, but the model-identity data is the same payload).
7. **Feature flags get their own named block, in both tiers, not folded
   into `Defaults`.** A `feature_flags:` (or similarly named) map of
   flag-name to bool, present in both the global settings file and,
   optionally, a project's YAML — every flag defaults to `false` unless
   explicitly set `true` at either tier. This is a genuinely new block,
   not an extension of `ProjectDefaults` (which is specifically about
   per-dispatch agent/model/retries semantics, a different shape). By
   the same reasoning, dev-folder-base also gets its own top-level key
   rather than living inside `Defaults`.

## Open Questions

1. Which feature flag(s) ship first, to prove the mechanism end-to-end?
   The block shape and default-false semantics are settled, but no
   flag exists today to migrate — this PRD needs at least one concrete
   candidate to implement against rather than a purely speculative,
   empty registry.
2. Is `token-meter`/`tokenmeter-client` importable directly as a Go
   module dependency from the `sergeant` repo (both are private under
   the same GitHub owner — likely just a `go.mod` require plus normal
   private-module auth, but worth confirming rather than assuming), or
   does its model-identity logic need to be vendored/reimplemented
   instead of imported?
