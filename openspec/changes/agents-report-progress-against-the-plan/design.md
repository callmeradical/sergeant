# Design — A dispatched agent reports progress against its plan

## Ownership and merge order

One repository, `sergeant-v2`. One bullet, no merge order.

## The checklist lives in the worktree

At dispatch, after the change is resolved and the worktree prepared, sergeant
writes `.sergeant/plan.json` into the worktree: one item per `#### Scenario:`
declared in the resolved change, each with a stable id, its text, and
`status: "pending"`.

A file in the worktree rather than an MCP call, because it works with every
harness. `SupportedAgents` lists six, and only some are configured against
sergeant's MCP server; a plan only some agents can report against is a plan the
dashboard cannot trust to mean the same thing twice. The agent already has the
worktree open, and writing a file needs no capability negotiation.

`.sergeant/` is already used for prompt files, so nothing new appears in the
repository, and the directory is already excluded from the commit path.

## Sergeant reads, never writes after seeding

Sergeant seeds the file and then only reads it. If sergeant also updated it there
would be two writers and no way to tell a stale read from a concurrent one.

Reads happen when the run is sampled — the same tick that already serves the
change stream. A malformed or absent file is reported as "no progress reported",
never as zero progress: those are different statements, and an agent that has not
written yet has not reported 0/8.

## Publishing

Each observed change to the checklist appends to the `changes` sequence added by
`dispatch-produces-a-durable-record`, so the dashboard receives it over the
existing SSE stream with no new endpoint and no polling.

## Reported is not proven

The run row shows `5/8 reported` alongside, never instead of, the phase status. A
reported 8/8 with a failing gate must render as 8/8 reported and a failed run.
The words matter: gates decide done, the agent describes where it is.

## Rejected alternatives

**Parsing progress from agent stdout.** Every harness formats differently, and the
format is not a contract — it changes between versions and would break silently.

**Deriving progress from files changed or commits.** Available for free and
already visible on disk, but it measures activity, not progress toward the plan.
Six modified files says nothing about which scenarios are satisfied.

**An MCP tool for reporting progress.** Cleaner where MCP is configured, and
unavailable where it is not. Worth adding later as a second writer to the same
file; not as the only route.

**Estimating time remaining.** Refuted by the data: r = -0.91 across five changes.
