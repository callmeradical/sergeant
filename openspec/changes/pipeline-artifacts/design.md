# Design — Pipeline artifacts

## Ownership

One repository, `sergeant-v2`. Touches `internal/store/store.go` (new
table), a new `internal/store/artifact.go`, `internal/runner/runner.go`
(`RunCodeGate`, `RunAgentPhase`), a new `internal/ui/artifacts.go`,
`internal/ui/server.go` (two new routes), and
`internal/ui/static/index.html`.

## Storage: filesystem tree + metadata rows

Mirrors the existing split between metadata (SQLite) and content that the
project's other evidence types already use — `deliveries` rows reference
an envelope rather than embedding its full payload. Artifact bytes
(images, traces — up to a few MB each) go on the filesystem, not into
SQLite as a blob, so the database itself stays small and query-fast
regardless of how many screenshots accumulate:

```
~/.local/share/sergeant/artifacts/<run_id>/<phase_id>/<filename>
```

(`SERGEANT_ARTIFACTS_ROOT` env override, mirroring `SERGEANT_UI_LOCK`'s
override pattern in `internal/ui/lock.go`, for tests.)

## `internal/store/store.go` — new table

Added via `migrateAddTables`'s `wanted` list, alongside `deliveries`/
`export_cursor`:

```sql
CREATE TABLE IF NOT EXISTS artifacts (
  id            TEXT PRIMARY KEY,
  run_id        TEXT NOT NULL,
  phase_id      TEXT NOT NULL,
  repo          TEXT NOT NULL,
  filename      TEXT NOT NULL,
  content_type  TEXT NOT NULL,
  size_bytes    INTEGER NOT NULL,
  path          TEXT NOT NULL,
  captured_at   DATETIME NOT NULL,
  dropped_count INTEGER NOT NULL DEFAULT 0,
  dropped_reason TEXT NOT NULL DEFAULT ''
)
```

`dropped_count`/`dropped_reason` are populated on the one row that
represents "we hit the cap" — see below — never left implicit.

## `internal/store/artifact.go` — new file

```go
type ArtifactRecord struct {
	ID            string
	RunID         string
	PhaseID       string
	Repo          string
	Filename      string
	ContentType   string
	SizeBytes     int64
	Path          string
	CapturedAt    time.Time
	DroppedCount  int
	DroppedReason string
}

func (s *Store) RecordArtifact(a *ArtifactRecord) error
func (s *Store) ListArtifactsForRun(runID string) ([]*ArtifactRecord, error)
func (s *Store) GetArtifact(id string) (*ArtifactRecord, bool, error)
```

Exactly the same shape as `store/delivery.go`'s
`RecordDelivery`/`ListDeliveriesForRun`/`GetDelivery`.

## Capture: a new `internal/runner` helper, called from both capture sites

```go
// captureArtifacts reads dir for files, copies each into the durable
// artifacts root under runID/phaseID, and records one ArtifactRecord per
// file via store. Bounded by maxArtifactCount and maxArtifactTotalBytes;
// anything beyond the bound is skipped and folded into a single row's
// DroppedCount/DroppedReason rather than silently omitted. Never returns
// an error to the caller — a capture problem is logged and recorded as
// best-effort metadata, never a phase failure, matching the existing
// non-critical posture of SSE progress sampling in dispatch.go.
func captureArtifacts(store *store.Store, runID, phaseID, repo, dir string)
```

Call sites, both after the command has already run and the phase record's
`Payload` has been built (so `phaseID` — `phaseRec.ID` — is known):

- `RunCodeGate` (`runner.go:264`): before building `cmd`, create
  `artifactDir := filepath.Join(pr.Worktree, ".sergeant", "artifacts")`,
  `os.MkdirAll` it, and append
  `"SERGEANT_ARTIFACT_DIR="+artifactDir` to `cmd.Env` (currently unset —
  `cmd.Env` must default to `os.Environ()` plus this one addition, since an
  explicitly-set `cmd.Env` replaces the inherited environment entirely).
  After `pr.Store.RecordPhase(phaseRec)`, call
  `captureArtifacts(pr.Store, pr.RunID, phaseRec.ID, pr.RepoName, artifactDir)`.
- `RunAgentPhase` (`runner.go:461`, around its `cmd.Env = append(os.Environ(), extraEnv...)`
  at line 520): same addition to `extraEnv`, same
  `captureArtifacts` call after that function's own phase record is
  written.

Both call sites already run inside `pr.Worktree`, which is reclaimed only
after the run reaches a terminal state (`automated-fleet-cleanup`'s
`RunsEligibleForCleanup`) — strictly after every phase, including this
capture step, has already returned. No additional synchronization is
needed between capture and reclaim.

## Routes (`internal/ui/artifacts.go`)

- **`GET /api/artifacts?run_id=<id>`** — `writeJSON` of
  `Store.ListArtifactsForRun(id)`, same shape as `handleDeliveryHistory`.
  Empty list, not an error, for a run with none.
- **`GET /api/artifacts/<id>/content`** — looks up the record, sets
  `Content-Type` from the stored value, and serves the file via
  `http.ServeFile`. 404 if the id or its file is missing (the artifact
  passed its own retention horizon per `data-retention-and-rotation`, or
  was never captured).

## Frontend

`internal/ui/static/index.html`'s `renderWorkflowGraph` (the function that
already renders one `laneHTML` per repo into `#workflow-graph`) gains one
more `fetch` — `GET /api/artifacts?run_id=...` — and, when the list is
non-empty, appends an "Artifacts" `<section>` after the repo lanes: one
group per `phase_id` present, each an image thumbnail grid (`content_type`
starting `image/`) or a plain filename link otherwise, `<img src="/api/artifacts/<id>/content">`.
Absent entirely (no extra DOM, no empty "Artifacts" heading) when the list
is empty — this is additive, not a mandatory element every run shows.

## Rejected alternatives

**Storing artifact bytes as a SQLite blob column.** Rejected for the same
reason `deliveries` doesn't embed envelope payloads: images are large
enough, and numerous enough over a project's lifetime, that keeping them
out of the query path (`sergeant.db`'s size and every `SELECT *` against
tables sharing its pages) matters. A plain file tree with a metadata row is
simpler to reason about and to prune later (`data-retention-and-rotation`
only has to delete files + rows, not run a `VACUUM`).

**Capturing artifacts asynchronously, after the phase returns.** Rejected:
it would need its own synchronization against worktree reclaim (a race
this design avoids entirely by capturing before the phase's own result is
returned), for no real benefit — capture is a local file copy, not a
network call, so it is already fast.
