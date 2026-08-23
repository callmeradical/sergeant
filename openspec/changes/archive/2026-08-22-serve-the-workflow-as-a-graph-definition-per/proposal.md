# Proposal — Serve the workflow as a graph definition

> **Written retroactively.** The implementation merged in `3ac6e29` before this
> change carried any specs. Recorded here because a merged change with no spec is
> exactly the undocumented work OpenSpec was adopted to eliminate (§3b), and the
> gap was found during review rather than declared at the time.

## Repository

One repository: `sergeant-v2`, in `internal/ui`.

## Requirements and decisions served

- **D8 — the dashboard renders the workflow from a definition.** A stage that has
  not started must still be visible, rather than absent.

## Problem

The dashboard derived its stage columns from phases that had already run, so it
could only ever show history. A pipeline stage that had not started was invisible,
which makes the view a log rather than a workflow. `factory.pipeline` was never
sent to the client at all.

## Proposal

Serve `GET /api/workflow?project=&repo=` returning nodes and edges derived from
project configuration: pipeline stages in declared order, gates in the engine's
execution order, and the bullet lifecycle tail. Everything comes from
configuration, so adding a gate changes the graph with no code change.

## Out of scope

- Cross-repository dependency edges, tracked separately.
- The dashboard rendering itself, which landed alongside but is a separate concern
  from serving the definition.
