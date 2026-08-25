package export

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/callmeradical/sergeant/internal/redact"
	"github.com/callmeradical/sergeant/internal/store"
)

// defaultInterval is the poll period used when Runner.Interval is zero.
const defaultInterval = 5 * time.Second

// Runner polls the store's durable change log for intent/bullet transitions
// and hands each one to a Target, advancing a durable cursor only after a
// successful delivery.
//
// It is a poll loop, not a subscription, even though Store.SubscribeChanges
// exists: SubscribeChanges only sees writes made by this process, and a
// second process writing the same database file (`sergeant mcp` while
// `sergeant ui` runs this loop) is exactly the case its own doc comment warns
// about. Polling the durable log is correct for every writer, not only the
// one that happens to host this loop.
type Runner struct {
	Store    *store.Store
	Target   Target
	Interval time.Duration // poll period; falls back to defaultInterval if zero
}

// Run polls until ctx is cancelled. It never returns an error for a failed
// delivery — that is logged and retried next tick with the cursor
// unadvanced — because a Target being unreachable must never look like a
// Sergeant failure to anything that started this loop.
func (r *Runner) Run(ctx context.Context) error {
	interval := r.Interval
	if interval <= 0 {
		interval = defaultInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		if err := r.Tick(ctx); err != nil {
			log.Printf("export: %v", err)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

// Tick runs one poll-and-deliver pass: load the cursor, fetch what followed
// it, deliver each intent/bullet transition to Target in order, and persist
// the cursor past only the run of records that delivered without error. A
// delivery failure partway through a batch leaves the cursor at the last
// fully-exported sequence number, so the next Tick retries from there rather
// than skipping the record that failed.
//
// A Tick is not called by the write path that produced any transition it
// exports; it exists so a call site — a test or Run's own loop — can
// exercise one pass without waiting on a timer.
func (r *Runner) Tick(ctx context.Context) error {
	cursor, err := r.Store.LoadExportCursor()
	if err != nil {
		return fmt.Errorf("loading export cursor: %w", err)
	}

	changes, err := r.Store.ListChangesSince(cursor, 0)
	if err != nil {
		return fmt.Errorf("listing changes since %d: %w", cursor, err)
	}

	advanced := cursor
	for _, c := range changes {
		if c.Channel != store.ChannelIntent && c.Channel != store.ChannelBullet {
			// Not a task-tracker-shaped channel; nothing to deliver, but there
			// is also nothing that can fail, so the cursor moves past it.
			advanced = c.Seq
			continue
		}

		rec, err := r.buildRecord(c)
		if err != nil {
			log.Printf("export: resolving %s %q (seq %d): %v", c.Channel, c.EntityID, c.Seq, err)
			break
		}

		if err := r.Target.Export(ctx, rec); err != nil {
			log.Printf("export: delivering %s %q (seq %d): %v", c.Channel, c.EntityID, c.Seq, err)
			break
		}

		advanced = c.Seq
	}

	if advanced == cursor {
		return nil
	}
	if err := r.Store.SaveExportCursor(advanced); err != nil {
		return fmt.Errorf("saving export cursor: %w", err)
	}
	return nil
}

// buildRecord resolves a ChangeRecord's current row and projects it into a
// Record. The row, not the change log's own deliberately partial payload
// (changes.go's ChangeRecord.Payload doc comment), is the source of truth —
// a payload that was complete at the moment of the transition can be stale
// by the time this runs.
func (r *Runner) buildRecord(c store.ChangeRecord) (Record, error) {
	switch c.Channel {
	case store.ChannelIntent:
		intent, err := r.Store.GetIntent(c.EntityID)
		if err != nil {
			return Record{}, fmt.Errorf("loading intent %q: %w", c.EntityID, err)
		}
		return Record{
			Kind:      "intent",
			ID:        intent.ID,
			Project:   intent.Project,
			Position:  -1,
			Status:    intent.Status,
			Statement: redact.Text(intent.Statement),
			CreatedAt: intent.CreatedAt,
			UpdatedAt: intent.UpdatedAt,
		}, nil

	case store.ChannelBullet:
		bullet, err := r.Store.GetBullet(c.EntityID)
		if err != nil {
			return Record{}, fmt.Errorf("loading bullet %q: %w", c.EntityID, err)
		}
		intent, err := r.Store.GetIntent(bullet.IntentID)
		if err != nil {
			return Record{}, fmt.Errorf("loading intent %q for bullet %q: %w", bullet.IntentID, bullet.ID, err)
		}
		return Record{
			Kind:      "bullet",
			ID:        bullet.ID,
			Project:   intent.Project,
			Repo:      bullet.Repo,
			Position:  bullet.Position,
			Status:    bullet.Status,
			CreatedAt: bullet.CreatedAt,
			UpdatedAt: bullet.UpdatedAt,
		}, nil

	default:
		return Record{}, fmt.Errorf("unexpected channel %q", c.Channel)
	}
}
