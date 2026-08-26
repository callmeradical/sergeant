Adds a read-only "Work analytics" view to the dashboard: total runs, a
breakdown by outcome (passed/failed/cancelled/interrupted/running), a
breakdown by work type (decision O2's feat/fix/refactor/docs/chore/test),
a breakdown by agent/model/provider (already captured per phase since
`phases-record-their-model-and-provider`), and how many bullets have
actually reached `merged` versus how many exist in total. It reads fields
that already exist; it records nothing new.
