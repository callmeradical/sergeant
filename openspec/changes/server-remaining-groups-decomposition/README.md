# server-remaining-groups-decomposition

Extracts the three smaller, lower-risk groups left in
`internal/ui/server.go` after the prior pass and after
`server-dispatch-execution-decomposition`: plans/bullets-approval,
workflow/DAG-discovery, and run-cancel/resume/delete — each
characterization-tested first, each into its own file, none needing a new
interface seam.
