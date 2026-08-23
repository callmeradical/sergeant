# Design — Serve the workflow as a graph definition

## Ownership

One repository, `sergeant-v2`, `internal/ui`. One bullet, no merge order.

## Where the values come from

Every node is derived from configuration, never from a literal in the handler:

- stages from `factory.pipeline`, falling back to the engine's default pipeline
  read from `internal/dag` rather than restated, so the description of the
  workflow cannot disagree with its execution;
- gates from `factory.gates`, ordered by the same sort the engine applies, because
  map iteration order would present a different first gate on each request;
- the lifecycle tail from the documented `BulletRecord` statuses.

## Why a definition rather than observed history

A view built from recorded phases can only answer "what happened". D8 asks for
"what will happen, and how far along is it", which requires the definition to be
the source and the phase records to be an overlay on it.

## Rejected alternatives

**Inferring the pipeline from the phases a run produced.** Cannot show an unstarted
stage, which is the entire point.

**Hardcoding the default pipeline in the handler.** A second authority that drifts
from the engine's, so the graph would eventually describe a workflow that is not
the one being run.
