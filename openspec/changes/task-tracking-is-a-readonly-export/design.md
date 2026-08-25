# Design — Task tracking is a read-only export

## Ownership

One repository, `sergeant-v2`. Touches: a new `internal/export` package
(new files only), `internal/store/store.go` (one new table, added the
`migrateAddTables` way — no changes to any existing table or method),
`internal/config/config.go` (one new optional field, following the
`Graphify` pattern exactly), and `cmd/sergeant/main.go` (wiring the runner
into `sergeant ui`'s startup, the same place `SubscribeChanges` consumers
already start).

## `internal/export.Target` — the interface, and why it is small and here

```go
package export

import "context"

// Target is anything that can receive one exported, read-only record. It is
// defined in this package (the consumer of a Target, not a Target's own
// implementation package) because the Runner is what needs it — a future
// backend package imports export and implements Target, not the reverse.
type Target interface {
	Export(ctx context.Context, rec Record) error
}

// Record is a redacted, minimal projection of one intent or bullet
// transition — never the row itself. Field names are exporter-neutral
// (no Sergeant-internal column names) since a Target may map them onto an
// arbitrary external schema.
type Record struct {
	Kind      string    // "intent" or "bullet"
	ID        string
	Project   string
	Repo      string    // empty for an intent record
	Position  int       // merge order; -1 for an intent record
	Status    string
	Statement string    // redacted via internal/redact.Text before this is built; empty for a bullet record
	CreatedAt time.Time
	UpdatedAt time.Time
}
```

One method, because a `Target` only ever needs to accept a record — there
is no second behavior an exporter must implement, and no case in this
change where a caller holds a `Target` and needs anything else from it.

## `internal/export.Runner` — a second, independent reader of the existing change log

```go
// Runner polls the store's durable change log for intent/bullet transitions
// and hands each one to a Target, advancing a durable cursor only after a
// successful delivery.
type Runner struct {
	Store    *store.Store
	Target   Target
	Interval time.Duration // poll period; falls back to a sane default if zero
}

// Run polls until ctx is cancelled. It never returns an error for a failed
// delivery — that is logged and retried next tick with the cursor
// unadvanced — because a Target being unreachable must never look like a
// Sergeant failure to anything that started this loop.
func (r *Runner) Run(ctx context.Context) error
```

`Run` is a poll loop, not a subscription, even though `Store.SubscribeChanges`
exists: `SubscribeChanges`'s own doc comment says a subscriber "must also
re-read on a slow fallback tick" because it only sees one process's writes,
and `sergeant mcp` writing the same database file while `sergeant ui` runs
this loop is exactly that case. Building on the fallback tick alone, with
`SubscribeChanges` as a purely optional latency improvement the first cut
does not need, is simpler and already correct for every writer, not just
the one process that happens to host the loop.

Each tick: `cursor, err := loadCursor(); changes, err :=
Store.ListChangesSince(cursor, 0)`. For each `ChangeRecord` whose `Channel`
is `store.ChannelIntent` or `store.ChannelBullet`: decode `Payload`, resolve
the full row via `Store.GetIntent`/one bullet from
`Store.ListBulletsForIntent` (payloads are deliberately partial — see
`changes.go`'s own comment on `ChangeRecord.Payload` — so the current row,
not the payload, is the source for `Record`), build a `Record` (redacting
`Statement` with `redact.Text`), call `Target.Export`. Advance and persist
the cursor to the highest `Seq` successfully exported **only if every
record in the batch exported without error** — a partial-batch failure
leaves the cursor at the last fully-exported `Seq`, so the next tick retries
from there rather than skipping the record that failed.

## Cursor storage — one row, the `migrateAddTables` way

```go
const createExportCursorTable = `
	CREATE TABLE IF NOT EXISTS export_cursor (
		id INTEGER PRIMARY KEY CHECK (id = 1),
		last_seq INTEGER NOT NULL DEFAULT 0
	);`
```

Added to `migrateAddTables`'s `wanted` slice
(`internal/store/store.go`, alongside `intents`/`bullets`/`changes`/
`deliveries`), so a pre-existing database gains it on next open exactly the
way `deliveries` already did. `id = 1` is a singleton-row constraint —
there is one export cursor for the whole store, matching `changes`' own
single global sequence (the log is one ordered stream regardless of how
many projects or targets read it; per-target cursors are not needed until
a second `Target` actually exists, which this change does not add).
`Store` gains `LoadExportCursor() (int64, error)` and
`SaveExportCursor(seq int64) error`, following `UpdateBulletStatus`'s
existing `requireOneRow`-free, plain-`Exec` style (a singleton row is
`INSERT OR REPLACE`, not update-and-check).

## Configuration — `Project.Export`, following `Graphify` exactly

```go
// Export declares an optional read-only task-tracking export target for
// this project. A nil pointer (no export: block) is distinguished from an
// empty one the same way Graphify already is.
type Export struct {
	// Backend names which Target implementation to construct. The registry
	// of valid names is an implementation decision for whoever adds the
	// first Target, not fixed by this change.
	Backend string `yaml:"backend" json:"backend"`
}
```

Added to `config.Project` as `Export *Export `yaml:"export,omitempty"
json:"export"`` immediately below the existing `Graphify` field. The
existing YAML-node round-trip (`TestRefineProjectPreservesUnmanagedConfig`)
already preserves any key not modeled on `Project`; modeling `Export`
exactly like `Graphify` keeps a project's `export:` block surviving a
config save the same way `graphify:` already does, with no separate work.

## Wiring

`cmd/sergeant/main.go`'s `startUI` (the `sergeant ui` command) constructs
the `Runner` once, with a `Target` resolved from whichever project(s) have
an `Export` block configured (a project with none constructs no `Target`
and the loop simply has nothing to poll for), and starts `Run` in a
goroutine alongside the HTTP server — the same lifecycle shape as any other
background loop this process already starts, not a new supervision
mechanism.

## Rejected alternatives

**Hooking `recordTransition` directly (an inline call at every intent/bullet
write site) instead of a second reader of the change log.** Rejected: that
would put the export attempt on the same call stack as the write it is
exporting, and PRD's hard requirement — an unreachable target must never
block, delay, or fail the underlying operation — would then depend on every
current and future call site remembering to fire the hook asynchronously
and swallow its error correctly. A second, independent reader of the
already-durable, already-ordered log gets the same guarantee for free: it
runs on its own goroutine, on its own schedule, and a write path that never
calls into it cannot be slowed or broken by it, now or by a call site added
later that forgets to.

**A bidirectional `Target` (e.g., `Target.Sync(ctx) ([]ExternalUpdate,
error)`) so an operator could close a task in the external tracker and have
Sergeant notice.** Rejected outright by D4: Sergeant "cannot enforce rules
about data it does not own." A bidirectional interface would let an
external tracker's state disagree with a bullet's actual gate evidence
(D3) — e.g., a task marked "done" externally while its bullet is still
`red` — with no way for Sergeant to know which is true. The one-method,
export-only `Target` makes that disagreement structurally impossible: there
is no code path for external state to reach Sergeant's store at all.

**Storing the export cursor in a plain file next to the SQLite database
(mirroring some of v1's fleet-file conventions) instead of a table.**
Rejected: this store already keeps every other piece of durable
cross-restart state (`changes`, `deliveries`, bullet/intent rows) in SQLite
specifically so a backup or inspection of one file covers everything;
adding one file-based exception for this cursor alone would recreate the
"is the file or the database the truth" question D4 exists to avoid, one
level down.

**Reading `ChangeRecord.Payload` directly instead of re-fetching the
current row from the store.** Rejected: `changes.go`'s own doc comment on
`ChangeRecord.Payload` states it is deliberately partial ("what the store
knew at the moment of the transition and no more... not a snapshot of the
whole entity") specifically so a client reads the entity by ID for anything
beyond that. An exporter that trusted the payload as complete would
silently export stale or missing fields (e.g. `BlockedReason`, which is not
in every payload map) the moment that comment's warning actually applied.
