# Tasks — Serve the workflow as a graph definition

One repository, `sergeant-v2`. One task, no cross-repo merge order.

## Task 1 — serve the workflow definition

Repository: `sergeant-v2`. Depends on: nothing. **Already delivered in `3ac6e29`.**

- Serve `GET /api/workflow?project=&repo=` returning nodes and edges.
- Derive stages from `factory.pipeline`, falling back to the engine default read
  from `internal/dag`.
- Order gates by the engine's execution order.
- Refuse an unknown project or repository with a client error naming it.

Verification: `go build ./... && go vet ./... && go test ./internal/... -count=1`.
`internal/ui/workflow_test.go` holds 5 tests covering declared order, the default
pipeline, gate ordering, configuration-driven change, and the unknown-name
refusals. Exit status decides the outcome.
