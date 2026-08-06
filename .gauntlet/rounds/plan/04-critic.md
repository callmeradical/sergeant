# Plan critic — round 4

## Winner

Quality bar. The plan was internally consistent on substrate and decomposition
but could not execute its own first shipping phase.

## Largest gap

Phase -2 needed to ship 166 unpushed commits under the coordinator-owned
validation gate, while the gate is broken today and its repair lived in Phase 5.
That created an unstated cycle through every earlier phase.

## Additional conflicts

- Phase -2 performed real GitHub/tmux/fleet mutations before Phase -1 created
  the closed boundary inventory.
- `--check-base` required the initial base forever, so the first successful
  merge would invalidate the plan.
- The plan overclaimed that zero tests isolate HOME; some do, but no conformance
  rule makes that universal.

## Exact challenge

Bootstrap the validation capability first with a one-time direct no-mistakes
exception, inventory existing work read-only, build the hermetic substrate, then
dispose/ship existing branches through the repaired gate. Re-record the
integration SHA after every merge while retaining the initial base as history.
