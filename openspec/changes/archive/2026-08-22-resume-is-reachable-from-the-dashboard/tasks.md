# Tasks — Resume is reachable from the dashboard

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — offer resume in the run detail drawer

Repository: `sergeant-v2`. Depends on: nothing.

- Add a server-computed boolean to the run payload stating whether the run may be
  resumed, derived from the same `ResumableStatuses` the endpoint enforces. Do not
  restate the status list in JavaScript.
- Render a resume control in the run detail drawer when that boolean is true, and
  not otherwise.
- Show the phases the resume will skip before the operator confirms, using the
  data the endpoint already returns.
- On confirmation, call `POST /api/run-resume` and let the existing change stream
  carry the transition back to `running`. Add no polling.
- On refusal, show the reason the server returned rather than a generated message.

Verification: `go build ./... && go vet ./internal/... && go test ./internal/...
-count=1` for the payload field and its derivation, including a test asserting the
boolean is false for `passed` and `running` and true for `failed`. The embedded
HTML requires a rebuild to serve, so also assert the control's presence and
absence by rendering logic or a browser check, and state in the summary exactly how
it was verified. Exit status decides the outcome.
