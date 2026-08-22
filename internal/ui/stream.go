package ui

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// GET /api/stream is how a client follows state without re-reading the world.
//
// Server-Sent Events rather than a WebSocket: the traffic is one-directional. The
// client sends commands over the existing POST endpoints and only reads here, so
// there is no framing to invent, no upgrade handshake, and the browser reconnects
// on its own and tells us where it left off via Last-Event-ID.

const (
	// streamTailInterval is the fallback wake-up for a connected client.
	//
	// The primary wake-up is the store's in-process notification, which fires the
	// moment a change is appended. This tick exists only because a second process
	// can write the same database file — `sergeant mcp` records envelopes while
	// `sergeant ui` serves this stream — and an in-process notification cannot see
	// that. Without it, an MCP-driven change would never reach the dashboard.
	streamTailInterval = time.Second

	// streamHeartbeatInterval bounds how long an idle connection stays silent. A
	// comment is not an event and carries no state; it exists because a silent
	// connection is indistinguishable from a dead one to anything in between.
	streamHeartbeatInterval = 20 * time.Second

	// streamReplayPage bounds one replay batch, so a client resuming from far
	// behind is served in pages instead of one unbounded query.
	streamReplayPage = 500

	// streamSnapshotRuns matches what GET /api/runs returns, so a client that
	// applies a snapshot holds the same list it would have fetched.
	streamSnapshotRuns = 50
)

func (srv *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		// Without flushing, every event would sit in a buffer until the handler
		// returned, which for a stream is never. Say so rather than serving a
		// connection that looks open and delivers nothing.
		http.Error(w, "this connection cannot stream events", http.StatusInternalServerError)
		return
	}

	// Subscribe before reading anything, so a change appended while the snapshot
	// is being built cannot be missed. The loop below queries by cursor before it
	// ever blocks, so a notification that arrives early is harmless.
	notify, unsubscribe := srv.Store.SubscribeChanges()
	defer unsubscribe()

	from, hasCursor := streamCursor(r)

	replayable := false
	if hasCursor {
		var err error
		replayable, err = srv.Store.CanReplayFrom(from)
		if err != nil {
			http.Error(w, fmt.Sprintf("reading the change sequence: %v", err), http.StatusInternalServerError)
			return
		}
	}

	// Headers before the first byte. No Content-Length: the body has no length.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Defeats response buffering in a reverse proxy, which would otherwise hold
	// events until its buffer filled and make a live stream look frozen.
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	cursor := from
	if !replayable {
		// An unknown or pruned cursor is caught up, never refused. The client
		// applies the snapshot wholesale and continues from the sequence it names.
		seq, err := srv.writeSnapshot(w)
		if err != nil {
			// The status line is already sent, so this cannot become a 500. Say what
			// failed on the stream itself and stop, rather than looping on an error.
			writeSSEComment(w, fmt.Sprintf("snapshot failed: %v", err))
			flusher.Flush()
			return
		}
		cursor = seq
	}
	flusher.Flush()

	ticker := time.NewTicker(streamTailInterval)
	defer ticker.Stop()
	heartbeat := time.NewTicker(streamHeartbeatInterval)
	defer heartbeat.Stop()

	for {
		next, full, err := srv.writeChangesSince(w, cursor)
		if err != nil {
			writeSSEComment(w, fmt.Sprintf("replay failed: %v", err))
			flusher.Flush()
			return
		}
		cursor = next
		flusher.Flush()

		if full {
			// A full page means there is more behind it. Keep draining rather than
			// waiting for the next wake-up, or a client resuming from far behind
			// would advance one page per tick.
			continue
		}

		select {
		case <-r.Context().Done():
			return
		case _, open := <-notify:
			if !open {
				return
			}
		case <-ticker.C:
		case <-heartbeat.C:
			writeSSEComment(w, "heartbeat")
			flusher.Flush()
		}
	}
}

// streamCursor reports the sequence the client has already applied.
//
// Last-Event-ID wins over ?from. An EventSource reconnects to the URL it was
// given, so ?from still names the sequence the page loaded with, while
// Last-Event-ID names the last event actually delivered. Preferring the query
// string would re-deliver everything since page load on every reconnect.
//
// An absent or unparseable cursor reports "no cursor", which asks for a snapshot.
// That is deliberate: a client whose cursor cannot be understood is a client whose
// position is unknown, and the spec answers an unknown position with a snapshot
// rather than an error.
func streamCursor(r *http.Request) (int64, bool) {
	if v := strings.TrimSpace(r.Header.Get("Last-Event-ID")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n, true
		}
	}
	v := strings.TrimSpace(r.URL.Query().Get("from"))
	if v == "" {
		return 0, false
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// writeSnapshot sends the current state and the sequence it corresponds to.
//
// The sequence is read *before* the runs, not after. A change landing between the
// two reads is then both inside the snapshot and replayed afterwards, and applying
// it twice is harmless because the client re-reads by id. Reading the sequence
// last would instead skip that change entirely.
func (srv *Server) writeSnapshot(w io.Writer) (int64, error) {
	seq, err := srv.Store.CurrentSequence()
	if err != nil {
		return 0, fmt.Errorf("reading the current sequence: %w", err)
	}
	runs, err := srv.Store.ListRecentRuns(streamSnapshotRuns)
	if err != nil {
		return 0, fmt.Errorf("reading the run list: %w", err)
	}
	if runs == nil {
		runs = []store.RunRecord{}
	}
	// runPayloads, not the bare records: the snapshot must hold what GET /api/runs
	// would have returned, including the server's resume answer, or a client that
	// applied a snapshot would render a drawer with no answer at all.
	return seq, writeSSE(w, "snapshot", seq, map[string]interface{}{
		"seq":  seq,
		"runs": runPayloads(runs),
	})
}

// writeChangesSince replays one page of changes above cursor. It reports the
// cursor it reached and whether the page was full, which means more remain.
func (srv *Server) writeChangesSince(w io.Writer, cursor int64) (int64, bool, error) {
	changes, err := srv.Store.ListChangesSince(cursor, streamReplayPage)
	if err != nil {
		return cursor, false, err
	}
	for _, c := range changes {
		if err := writeSSE(w, "change", c.Seq, c); err != nil {
			return cursor, false, err
		}
		cursor = c.Seq
	}
	return cursor, len(changes) == streamReplayPage, nil
}

// writeSSE emits one event.
//
// The id field is the sequence number, which is what makes a reconnect resumable:
// the browser sends it back as Last-Event-ID without the page having to store it.
//
// The payload is written as a single data line, which is safe because
// json.Marshal escapes newlines inside strings and never emits a raw one. A
// multi-line body would otherwise be read by the client as several events.
func writeSSE(w io.Writer, event string, id int64, data interface{}) error {
	body, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("encoding a %s event: %w", event, err)
	}
	_, err = fmt.Fprintf(w, "event: %s\nid: %d\ndata: %s\n\n", event, id, body)
	return err
}

// writeSSEComment emits a comment line. A comment is not an event: it carries no
// state and no client applies it.
func writeSSEComment(w io.Writer, text string) {
	_, _ = fmt.Fprintf(w, ": %s\n\n", strings.ReplaceAll(text, "\n", " "))
}
