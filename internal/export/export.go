// Package export provides a read-only, out-of-band export of intent and
// bullet transitions to an external task tracker (D4: exporting a copy is
// optional; Sergeant remains the sole authority over the state itself).
package export

import (
	"context"
	"time"
)

// Target is anything that can receive one exported, read-only record. It is
// defined in this package (the consumer of a Target, not a Target's own
// implementation package) because the Runner is what needs it — a future
// backend package imports export and implements Target, not the reverse.
type Target interface {
	Export(ctx context.Context, rec Record) error
}

// Record is a redacted, minimal projection of one intent or bullet
// transition — never the row itself. Field names are exporter-neutral (no
// Sergeant-internal column names) since a Target may map them onto an
// arbitrary external schema.
type Record struct {
	Kind      string // "intent" or "bullet"
	ID        string
	Project   string
	Repo      string // empty for an intent record
	Position  int    // merge order; -1 for an intent record
	Status    string
	Statement string // redacted via internal/redact.Text before this is built; empty for a bullet record
	CreatedAt time.Time
	UpdatedAt time.Time
}
