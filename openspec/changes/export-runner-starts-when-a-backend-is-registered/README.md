# export-runner-starts-when-a-backend-is-registered

Closes a caveat from Review 026: `cmd/sergeant/main.go` never actually constructs or starts an `internal/export.Runner`, even though the type is fully built and tested — it only logs a warning. This change adds a name-keyed backend registry so that once any future change registers a real `Target` constructor, the process starts exporting for it automatically, with no further wiring work needed at that point.
