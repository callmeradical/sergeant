# Plan critic — round 10

## Winner

Quality bar on one remaining bootstrap deadlock.

## Largest gap

The canonical isolation and validation branches are owned by orphaned records
with dead panes `%2674` and `%2885`. The plan blocked adoption until ownership
was reconciled, but no existing command can do it: recover requires
`in_progress`, respond requires a response, wake requires a wake condition, and
global sync is prohibited.

## Exact challenge

Add a Phase -3.5 per-record adjudicator. It proves exact old identity/process is
dead, freezes branch/td/PR evidence, obtains explicit human approval, and writes
an audited owner-handover marker without rewriting `orphaned` status. Reusing the
pane number for a live foreign process must make adjudication fail.
