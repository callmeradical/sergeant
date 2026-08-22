# Tasks — Every fleet path resolves through one helper

One repository, `sergeant-v2`, so one task and no cross-repo merge order.

## Task 1 — resolve every fleet path through one helper

Repository: `sergeant-v2`. Depends on: nothing.

- Add `FleetRoot()` to `internal/dag`, resolving `SERGEANT_FLEET_DIR` then falling
  back to `~/.local/share/sergeant-v2/fleet`.
- Re-express `FleetDir(runID, repoName)` as a join on `FleetRoot()` so the two
  cannot disagree.
- Replace all four hand-built fleet paths in `internal/ui/server.go` — the three
  pointing at v1's root and the one that is correct but duplicated — with calls to
  the helper.
- Add a test that scans the Go sources under `internal/` and fails on any non-test
  occurrence of `share/sergeant/fleet` outside the helper.
- Write the scan so it fails before the change: it must report the three current
  offenders by file and line.

Verification: `go build ./... && go vet ./internal/... && go test ./internal/...
-count=1`. The scan test must fail on the pre-change tree and pass after. Exit
status decides the outcome.
