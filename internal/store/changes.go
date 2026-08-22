package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

// The ordered change sequence. Decision D10 adopts AHP's subscribe/snapshot/
// replay model, which treats reconnection as a protocol concern rather than
// leaving every client to re-read the world on a timer.
//
// Two properties carry the whole design and both are enforced by the schema
// rather than by application code:
//
//   - seq INTEGER PRIMARY KEY AUTOINCREMENT is strictly increasing, so a replay
//     ordered by seq is the order in which the transitions happened;
//   - AUTOINCREMENT never reuses a value after a delete, so a pruned history
//     cannot make two different transitions share a sequence number and leave
//     replay ambiguous.
//
// The table is append-only. Nothing in this package updates or deletes a row.

const createChangesTable = `
	CREATE TABLE IF NOT EXISTS changes (
		seq INTEGER PRIMARY KEY AUTOINCREMENT,
		channel TEXT NOT NULL,
		entity_id TEXT NOT NULL,
		payload TEXT NOT NULL,
		created_at DATETIME NOT NULL
	);`

// Channels partition the sequence by the kind of thing that moved, so a client
// can decide what to re-render without decoding every payload.
//
// run, intent and bullet are the domain transitions. phase and envelope are
// included because both already mutate what an operator sees — RecordPhase bumps
// runs.updated_at, and an envelope is what the activity view renders — and a
// client that could not see them would still need a timer to notice them.
const (
	ChannelRun      = "run"
	ChannelIntent   = "intent"
	ChannelBullet   = "bullet"
	ChannelPhase    = "phase"
	ChannelEnvelope = "envelope"
)

// ChangeRecord is one entry in the ordered sequence.
//
// Payload carries what the store knew at the moment of the transition and no
// more. It is deliberately not a snapshot of the whole entity: a payload that
// claimed to be the entity would be stale the moment the next transition landed,
// and the dashboard's rule is that it renders only what the store says now. A
// client that wants the entity reads it by EntityID.
type ChangeRecord struct {
	Seq       int64           `json:"seq"`
	Channel   string          `json:"channel"`
	EntityID  string          `json:"entity_id"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"created_at"`
}

// defaultChangeReplayLimit bounds one replay page. A client that asks for a
// cursor far behind the current sequence is served in pages rather than in one
// unbounded query, and it learns there is more by the cursor it ends up holding.
const defaultChangeReplayLimit = 500

// AppendChange records a state transition and returns its sequence number.
//
// The sequence number is assigned by the database, not by this process. Two
// processes writing the same file therefore cannot assign the same number, which
// a counter held in Go would.
func (s *Store) AppendChange(channel, entityID string, payload interface{}) (int64, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, fmt.Errorf("encoding the payload of a %s change: %w", channel, err)
	}
	res, err := s.db.Exec(
		`INSERT INTO changes (channel, entity_id, payload, created_at) VALUES (?, ?, ?, ?)`,
		channel, entityID, string(body), time.Now().UTC(),
	)
	if err != nil {
		return 0, fmt.Errorf("appending a %s change for %q: %w", channel, entityID, err)
	}
	seq, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("reading back the sequence number of a %s change: %w", channel, err)
	}
	s.notifyChange(seq)
	return seq, nil
}

// ListChangesSince returns the changes after from, in ascending sequence order.
//
// The bound is exclusive: a client that has applied N asks for what follows N and
// must not be handed N again. limit of zero or less means the default page size.
func (s *Store) ListChangesSince(from int64, limit int) ([]ChangeRecord, error) {
	if limit <= 0 {
		limit = defaultChangeReplayLimit
	}
	rows, err := s.db.Query(
		`SELECT seq, channel, entity_id, payload, created_at
		 FROM changes WHERE seq > ? ORDER BY seq ASC LIMIT ?`,
		from, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []ChangeRecord
	for rows.Next() {
		var c ChangeRecord
		var payload string
		if err := rows.Scan(&c.Seq, &c.Channel, &c.EntityID, &payload, &c.CreatedAt); err != nil {
			return nil, err
		}
		c.Payload = safeRawJSON(payload)
		list = append(list, c)
	}
	return list, rows.Err()
}

// CurrentSequence reports the highest sequence number ever assigned.
//
// "Ever assigned" rather than "currently stored". AUTOINCREMENT keeps its
// high-water mark in sqlite_sequence, which survives a delete, so after a prune
// MAX(seq) is lower than a number already handed out. Reporting MAX(seq) there
// would tell a client to resume from a sequence that is behind reality, and every
// subsequent append would look like a change it had already seen.
func (s *Store) CurrentSequence() (int64, error) {
	var highest int64
	if err := s.db.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM changes`).Scan(&highest); err != nil {
		return 0, err
	}

	var watermark sql.NullInt64
	err := s.db.QueryRow(`SELECT seq FROM sqlite_sequence WHERE name = 'changes'`).Scan(&watermark)
	if err != nil && err != sql.ErrNoRows {
		return 0, err
	}
	if watermark.Valid && watermark.Int64 > highest {
		highest = watermark.Int64
	}
	return highest, nil
}

// EarliestSequence reports the lowest sequence number still held, or zero when no
// change is held at all.
func (s *Store) EarliestSequence() (int64, error) {
	var earliest int64
	if err := s.db.QueryRow(`SELECT COALESCE(MIN(seq), 0) FROM changes`).Scan(&earliest); err != nil {
		return 0, err
	}
	return earliest, nil
}

// CanReplayFrom reports whether every change after from is still available.
//
// A false answer is not an error. It is the signal that the caller must answer
// with a snapshot and the current sequence instead — the spec requires an unknown
// cursor to be caught up, never refused.
//
// Three cases answer false:
//
//   - from is at or below zero. The client has applied nothing, and the log holds
//     transitions rather than state, so replaying it cannot describe an entity
//     recorded before the log existed.
//   - from is above the current sequence. The server never assigned it; this is
//     the client that returns after the database was rebuilt.
//   - from is below the oldest retained row minus one. The changes between the
//     cursor and what is still held have been pruned away, so a replay would be
//     silently incomplete.
func (s *Store) CanReplayFrom(from int64) (bool, error) {
	if from <= 0 {
		return false, nil
	}
	current, err := s.CurrentSequence()
	if err != nil {
		return false, err
	}
	if from > current {
		return false, nil
	}
	earliest, err := s.EarliestSequence()
	if err != nil {
		return false, err
	}
	if earliest == 0 {
		// Nothing is held. Replay is complete only if the client is already at the
		// end of the sequence, in which case there is genuinely nothing to send.
		return from == current, nil
	}
	// from itself is excluded from a replay, so holding everything from from+1
	// upwards is sufficient.
	return from >= earliest-1, nil
}

// SubscribeChanges returns a channel that receives the sequence number of each
// change appended by this process, and a function that stops delivery.
//
// This exists so a subscriber does not have to invent an interval. It is a
// notification, not a transport: the channel has a capacity of one and a send
// that would block is dropped, because a subscriber that has not caught up
// already knows it is behind and re-reads by cursor. A sequence number is
// therefore a hint that something moved, never the only copy of a change.
//
// It only sees writes from this process. A second process writing the same
// database file — `sergeant mcp` while `sergeant ui` serves the stream — is why
// every subscriber must also re-read on a slow fallback tick rather than trusting
// this channel to be complete.
func (s *Store) SubscribeChanges() (<-chan int64, func()) {
	s.subMu.Lock()
	defer s.subMu.Unlock()

	if s.subs == nil {
		s.subs = map[int64]chan int64{}
	}
	s.nextSubID++
	id := s.nextSubID
	ch := make(chan int64, 1)
	s.subs[id] = ch

	var once bool
	unsubscribe := func() {
		s.subMu.Lock()
		defer s.subMu.Unlock()
		if once {
			return
		}
		once = true
		delete(s.subs, id)
		close(ch)
	}
	return ch, unsubscribe
}

func (s *Store) notifyChange(seq int64) {
	s.subMu.Lock()
	defer s.subMu.Unlock()
	for _, ch := range s.subs {
		select {
		case ch <- seq:
		default:
		}
	}
}

// recordTransition appends a change and wraps its failure with the write it
// describes.
//
// The change row is written after the row it reports, not inside a transaction
// with it, and its failure is returned rather than swallowed. Swallowing it would
// leave the store holding a transition that no subscriber can ever learn about,
// and every client would sit waiting for an event that was never recorded — the
// silent divergence the stream exists to remove. Returning it means a caller can
// see an error for a write that landed; that is the honest report, because the
// write did land and its notification did not.
func (s *Store) recordTransition(channel, entityID string, payload interface{}) error {
	_, err := s.AppendChange(channel, entityID, payload)
	return err
}
