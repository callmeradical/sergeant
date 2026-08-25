# Product Requirements: Canonical Intent Brief

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, D1 ("Two ways in, one set of records"),
D4 ("Sergeant stores intents and bullets itself"), and AGENTS.md's listed
v2 gap "canonical intent files."

## Summary

v1 gave every dispatched agent a durable, human-readable file —
`.sergeant-intent.md` — as the one canonical statement of what it was asked
to do and why, plus a rendered worker brief (`templates/worker-brief.md`,
removed with the rest of v1) built from it. v2 stores the same information
instead as first-class `Intent` and `Bullet` rows (D4) — a real
improvement, since it gives referential integrity to worktree, branch,
commit, and PR that a flat file never had. But nothing today renders that
stored intent back out as the single canonical brief a dispatched agent (or
a human) reads. `sergeant_get_brief`, the MCP tool D1 names as one of the
two ways an agent gets context, currently returns raw project YAML
(`internal/mcp/server.go`'s `sergeant_get_brief` case calls
`config.LoadProject` and dumps the config) — not the intent or bullet the
agent is actually working on.

This PRD adds that missing rendering: one canonical, generated document per
intent, derived entirely from stored state, that both dispatch paths (D1's
"two ways in") hand to an agent as its brief.

## Problem

There is currently no single answer to "what is this agent actually being
asked to do, and why" that both dispatch paths produce identically. An
agent dispatched via the UI gets whatever the run's phase construction
happens to assemble; an agent connecting via MCP and calling
`sergeant_get_brief` gets a project config dump with no bullet-specific
content at all. D1 requires both paths to "create the same intents, bullets
and evidence" — today they do not even describe the same work identically,
which is a gap in the requirement, not just a UX rough edge.

This also means there is no durable, human-readable artifact an operator
can point to and say "this is what we agreed this bullet would do" the way
`.sergeant-intent.md` was in v1 — only database rows, reachable only
through the dashboard or direct queries.

## Proposal

Define a canonical, generated intent brief: a single rendering function
that takes an `Intent` and (when scoped to one) its `Bullet` and produces
one document containing, at minimum:

- The intent's durable statement of desired change, verbatim.
- The specific bullet's repository, and its position in the intent's
  declared merge order (D6).
- The bullet's current lifecycle state (`proposed → pending → red → green →
  sealed → merged`, or `blocked`/`failed`) and, if blocked, the recorded
  reason (building on the existing blocked-bullet mechanism).
- The gates that will run and the OpenSpec change, if any, this bullet
  resolves to (O3).

Both dispatch paths call this same rendering function to produce an agent's
brief — the UI-dispatched path when it constructs a run's initial phase,
and `sergeant_get_brief` over MCP when an agent asks for context on a
specific intent/bullet. Neither path is permitted to construct its own,
different description of the same intent.

The rendering is read-only and fully derived: it is never itself stored as
a separate authoritative copy (that would recreate exactly the flat-file
durability problem D4 already resolved by storing intents as rows). An
operator who wants the v1-style durable file can save the rendered output;
Sergeant does not need to maintain one on disk for them.

## Out of scope

- **Changing what `Intent`/`Bullet` store.** This PRD adds a rendering over
  existing fields; it proposes no new schema.
- **A second durable copy of the brief on disk.** Explicitly rejected above
  — would reintroduce a second source of truth for something D4 already
  settled.
- **Free-form editing of a brief by an agent or operator.** The brief is
  generated from stored state, not an editable document; changing intent
  content means updating the Intent record, not the rendered brief.
- **The dashboard's existing intent detail view.** If it already renders
  equivalent information, this PRD's job is to make the same rendering
  function available to both dispatch paths, not to redesign that view.

## Open questions

- Exact document format (Markdown vs. structured JSON with a Markdown
  rendering on top) — an OpenSpec `design.md` decision, not a product
  requirement.
- Whether an intent-level brief (spanning all its bullets) is needed in
  addition to the per-bullet brief, for the human-approval moments D5(a)
  and D5(c) already cover.
