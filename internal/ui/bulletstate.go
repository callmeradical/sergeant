package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/callmeradical/sergeant/internal/store"
)

// runPayload is a run as a client receives it: the stored record, plus the
// server's answer to "may this run be resumed?".
//
// The answer is served rather than left to the client because the refusal in
// handleRunResume is authoritative. A dashboard holding its own list of resumable
// statuses would be a second authority for one rule, and the two would drift into
// offering an action the server rejects. Resumable is derived here from the same
// ResumableStatuses that endpoint enforces, so there is exactly one list.
type runPayload struct {
	store.RunRecord
	Resumable bool `json:"resumable"`
}

// runPayloads answers the resume question for every run in a list. It never
// returns nil, so an empty list serialises as [] rather than null.
func runPayloads(runs []store.RunRecord) []runPayload {
	out := make([]runPayload, 0, len(runs))
	for _, r := range runs {
		out = append(out, runPayload{RunRecord: r, Resumable: isResumable(r.Status)})
	}
	return out
}

// validWorkTypes is the fixed vocabulary decision O2 names for a dispatched
// branch's <type>/<change-id> prefix. It is checked before anything else about
// a dispatch — before change resolution, before either the no-repos or
// explicit-repos branch runs — mirroring where ValidateAgent is checked: reject
// what the engine cannot honor before any record exists.
var validWorkTypes = map[string]bool{
	"feat": true, "fix": true, "refactor": true,
	"docs": true, "chore": true, "test": true,
}

// sortedWorkTypes returns validWorkTypes' keys in a stable order, so a refusal
// names the valid set the same way on every call.
func sortedWorkTypes() []string {
	names := make([]string, 0, len(validWorkTypes))
	for t := range validWorkTypes {
		names = append(names, t)
	}
	sort.Strings(names)
	return names
}

// validateWorkType reports whether typ is one of the fixed work types a
// dispatch may name. An empty or unrecognized value is refused, naming the
// valid set, so the caller learns what would have been accepted.
func validateWorkType(typ string) error {
	if !validWorkTypes[typ] {
		return fmt.Errorf("invalid or missing type %q: must be one of %s", typ, strings.Join(sortedWorkTypes(), ", "))
	}
	return nil
}

func cancelNote(stopped bool) string {
	if stopped {
		return "Run cancelled and in-flight agent work signalled to stop."
	}
	return "No in-flight run found on this server; status recorded as cancelled only."
}

func bulletStatusForRunOutcome(runStatus string) (string, bool) {
	switch runStatus {
	case "passed":
		return "green", true
	case "failed":
		return "blocked", true
	default:
		return "", false
	}
}

// ResumableStatuses are the run statuses a resume accepts.
//
// A passed run is excluded because re-running earned work can only lose it: a
// flaky gate would turn a pass into a failure. A running run is excluded because
// resuming it would put two agents in one worktree.
//
// interrupted is included: the coordinator stopped, not the work. Nothing judged
// the run; it was cut off. ReconcileOrphanedRuns moves orphaned running runs to
// this status at startup so the normal resume path recovers them without operator
// archaeology.
var ResumableStatuses = []string{"failed", "cancelled", "timed_out", "interrupted"}

func isResumable(status string) bool {
	for _, s := range ResumableStatuses {
		if status == s {
			return true
		}
	}
	return false
}
