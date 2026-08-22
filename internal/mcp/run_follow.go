package mcp

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/callmeradical/sergeant/internal/store"
)

// Following a run an agent dispatched.
//
// Decision D1 makes the agent-driven path equal in standing to the
// coordinator-driven one, so an agent that dispatches work must be able to
// observe it. Before these two tools it could not: the MCP surface exposed five
// tools and none accepted a run id, so both known consumers invented a duration
// instead — the dashboard polled every two seconds forever, and an operating
// agent slept for a guessed interval and re-read the run list.
//
// Both tools read sergeant's own store, and nothing else. Decision D7 forbids
// reaching v1 for this: no bin/sgt-* helper, no tmux.

const (
	// defaultRunWaitBound applies when a caller supplies no bound. It exists so
	// the tool cannot block forever, not to express a sensible duration — the
	// bound is the caller's to choose, which is why exceeding it is reported
	// rather than acted on.
	defaultRunWaitBound = 5 * time.Minute

	// maxRunWaitBound caps what a caller may ask for. A wait longer than this is
	// a wait whose answer nobody is still reading.
	maxRunWaitBound = time.Hour

	// runWaitPollInterval is the fallback re-read while waiting.
	//
	// The primary wake-up is the store's change notification, which fires the
	// moment a transition is appended. This tick exists because the run may be
	// driven by a different process — `sergeant ui` executes the run while
	// `sergeant mcp` waits on it — and an in-process notification cannot see that
	// write. Without it a wait would sit until its bound elapsed and then report a
	// run that had finished long before as still executing.
	runWaitPollInterval = time.Second
)

// runNotFound is the answer to a run id sergeant holds no record of.
//
// It is a distinct shape from runStatusResult and carries no status field at all.
// An empty status would be indistinguishable from a run that has not started
// yet, which would let a caller wait forever on a typo.
type runNotFound struct {
	RunID string `json:"run_id"`
	Found bool   `json:"found"`
	Error string `json:"error"`
}

func notFound(runID string) runNotFound {
	return runNotFound{
		RunID: runID,
		Found: false,
		Error: fmt.Sprintf("no run with id %q: sergeant holds no record of it", runID),
	}
}

type phaseResult struct {
	Repo       string `json:"repo"`
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	Status     string `json:"status"`
	Error      string `json:"error,omitempty"`
	DurationMs int64  `json:"duration_ms"`
}

type runStatusResult struct {
	RunID string `json:"run_id"`
	Found bool   `json:"found"`

	Status string `json:"status"`
	// Terminal is stated rather than left to the caller to infer from Status. A
	// caller that kept its own list of terminal statuses would eventually disagree
	// with the store's, and then wait forever on a run the store calls finished.
	Terminal bool   `json:"terminal"`
	Slug     string `json:"slug"`
	Project  string `json:"project"`
	Brief    string `json:"brief,omitempty"`
	ChangeID string `json:"change_id,omitempty"`
	IntentID string `json:"intent_id,omitempty"`

	// Sequence is the change sequence this answer was read at — the same sequence
	// the dashboard consumes. A caller can follow up by subscribing from it
	// instead of guessing when to ask again.
	Sequence int64 `json:"sequence"`

	CreatedAt time.Time     `json:"created_at"`
	UpdatedAt time.Time     `json:"updated_at"`
	Phases    []phaseResult `json:"phases"`
}

type runWaitResult struct {
	RunID string `json:"run_id"`
	Found bool   `json:"found"`

	// Status is whatever the store holds when the wait ends. It is never derived
	// from how long the wait took: a wait that returned "failed" on its own
	// impatience would record a falsehood.
	Status   string `json:"status"`
	Terminal bool   `json:"terminal"`
	TimedOut bool   `json:"timed_out"`
	Slug     string `json:"slug"`
	Sequence int64  `json:"sequence"`

	WaitedMs int64  `json:"waited_ms"`
	BoundMs  int64  `json:"bound_ms"`
	Note     string `json:"note"`
}

// runStatus reports one run by id.
func (s *MCPServer) runStatus(runID string) (string, error) {
	runID = strings.TrimSpace(runID)
	if runID == "" {
		return "", errors.New("run_id is required")
	}

	run, err := s.Store.GetRun(runID)
	if errors.Is(err, sql.ErrNoRows) {
		return encode(notFound(runID))
	}
	if err != nil {
		return "", fmt.Errorf("reading run %q: %w", runID, err)
	}

	seq, err := s.Store.CurrentSequence()
	if err != nil {
		return "", fmt.Errorf("reading the current change sequence: %w", err)
	}
	phases, err := s.Store.ListPhasesForRun(runID)
	if err != nil {
		return "", fmt.Errorf("reading the phases of run %q: %w", runID, err)
	}

	return encode(runStatusResult{
		RunID:     run.ID,
		Found:     true,
		Status:    run.Status,
		Terminal:  store.IsTerminalRunStatus(run.Status),
		Slug:      run.Slug,
		Project:   run.Project,
		Brief:     run.Brief,
		ChangeID:  run.ChangeID,
		IntentID:  run.IntentID,
		Sequence:  seq,
		CreatedAt: run.CreatedAt,
		UpdatedAt: run.UpdatedAt,
		Phases:    phaseResults(phases),
	})
}

// runWait returns when the run reaches a terminal status, or when bound elapses.
//
// The bound is the caller's. Exceeding it changes what is reported *about the
// wait*, never what is reported about the run: the run's status is whatever the
// store says, so an exceeded bound answers with that status and says the run is
// still executing.
func (s *MCPServer) runWait(runID string, bound time.Duration) (string, error) {
	runID = strings.TrimSpace(runID)
	if runID == "" {
		return "", errors.New("run_id is required")
	}

	// Subscribe before the first read. A transition landing between the read and
	// the subscription would otherwise be missed, and the wait would then depend
	// on the fallback tick to notice a run that had already finished.
	notify, unsubscribe := s.Store.SubscribeChanges()
	defer unsubscribe()

	started := time.Now()
	deadline := started.Add(bound)

	ticker := time.NewTicker(runWaitPollInterval)
	defer ticker.Stop()

	for {
		run, err := s.Store.GetRun(runID)
		if errors.Is(err, sql.ErrNoRows) {
			// An unknown id is reported at once. Waiting out the bound on a typo is
			// exactly the "wait forever" this requirement removes.
			return encode(notFound(runID))
		}
		if err != nil {
			return "", fmt.Errorf("reading run %q: %w", runID, err)
		}

		seq, err := s.Store.CurrentSequence()
		if err != nil {
			return "", fmt.Errorf("reading the current change sequence: %w", err)
		}

		if store.IsTerminalRunStatus(run.Status) {
			return encode(runWaitResult{
				RunID:    run.ID,
				Found:    true,
				Status:   run.Status,
				Terminal: true,
				TimedOut: false,
				Slug:     run.Slug,
				Sequence: seq,
				WaitedMs: time.Since(started).Milliseconds(),
				BoundMs:  bound.Milliseconds(),
				Note:     fmt.Sprintf("run %s finished with status %q.", run.ID, run.Status),
			})
		}

		remaining := time.Until(deadline)
		if remaining <= 0 {
			return encode(runWaitResult{
				RunID:    run.ID,
				Found:    true,
				Status:   run.Status,
				Terminal: false,
				TimedOut: true,
				Slug:     run.Slug,
				Sequence: seq,
				WaitedMs: time.Since(started).Milliseconds(),
				BoundMs:  bound.Milliseconds(),
				Note: fmt.Sprintf(
					"run %s is STILL EXECUTING: its status is %q and the wait's bound of %s elapsed first. "+
						"This is not a terminal status; wait again or subscribe from sequence %d.",
					run.ID, run.Status, bound, seq),
			})
		}

		timeout := time.NewTimer(remaining)
		select {
		case _, open := <-notify:
			if !open {
				// The subscription was torn down. Fall through to one more read so the
				// answer still comes from the store rather than from this failure.
				timeout.Stop()
				notify = nil
				continue
			}
		case <-ticker.C:
		case <-timeout.C:
		}
		timeout.Stop()
	}
}

func phaseResults(phases []store.PhaseRecord) []phaseResult {
	out := make([]phaseResult, 0, len(phases))
	for _, p := range phases {
		out = append(out, phaseResult{
			Repo:       p.Repo,
			Name:       p.Name,
			Kind:       p.Kind,
			Status:     p.Status,
			Error:      p.Error,
			DurationMs: p.DurationMs,
		})
	}
	return out
}

// runWaitBound reads the caller's bound out of the tool arguments.
//
// JSON numbers arrive as float64. An absent, unreadable or non-positive value
// falls back to the default rather than to zero, because a zero bound is a wait
// that never waits, and a caller that omitted the field did not ask for that.
func runWaitBound(raw interface{}) time.Duration {
	seconds, ok := raw.(float64)
	if !ok || seconds <= 0 {
		return defaultRunWaitBound
	}
	bound := time.Duration(seconds * float64(time.Second))
	if bound > maxRunWaitBound {
		return maxRunWaitBound
	}
	return bound
}

// encode renders a tool result. Indented because a human reads these in an agent
// transcript as often as a program parses them.
func encode(v interface{}) (string, error) {
	out, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return "", fmt.Errorf("encoding the tool result: %w", err)
	}
	return string(out), nil
}
