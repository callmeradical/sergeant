package naming

import (
	"regexp"
	"strings"
	"testing"
)

// A run id is the run's identity, the name of its git branch, and the name of its
// worktree directory. Two runs created in the same second must not share one.
//
// The id used to be fmt.Sprintf("sgt-%d", time.Now().Unix()), so two dispatches
// inside one second produced the same id and the second silently collided on the
// runs primary key. That made a same-second repeat look deduplicated when nothing
// had deduplicated it. Deliberate deduplication belongs to the caller's
// request_id; the id must simply be unique.
func TestRunIDsAreDistinctWithinOneSecond(t *testing.T) {
	const n = 10000
	seen := make(map[string]bool, n)
	for i := 0; i < n; i++ {
		id := RunID()
		if seen[id] {
			t.Fatalf("RunID returned %q twice in %d calls", id, i+1)
		}
		seen[id] = true
	}
}

// The id is interpolated into a git branch name and a directory path, so it must
// hold nothing that needs quoting or that git would reject.
func TestRunIDIsSafeInABranchNameAndAPath(t *testing.T) {
	safe := regexp.MustCompile(`^sgt-[0-9]+-[0-9a-f]+$`)
	for i := 0; i < 100; i++ {
		id := RunID()
		if !safe.MatchString(id) {
			t.Fatalf("RunID() = %q, want it to match %s", id, safe)
		}
		if strings.ContainsAny(id, "/\\ .:~*?[]^") {
			t.Fatalf("RunID() = %q holds a character git or the filesystem would object to", id)
		}
	}
}

// The prefix and the epoch are kept so an operator can still read roughly when a
// run started out of its id, which is what the previous format bought.
func TestRunIDKeepsThePrefixAndTheEpoch(t *testing.T) {
	id := RunID()
	if !strings.HasPrefix(id, "sgt-") {
		t.Errorf("RunID() = %q, want the sgt- prefix", id)
	}
	parts := strings.Split(id, "-")
	if len(parts) != 3 {
		t.Fatalf("RunID() = %q, want three dash-separated parts", id)
	}
	if len(parts[1]) < 10 {
		t.Errorf("RunID() = %q: %q does not look like a unix timestamp", id, parts[1])
	}
}
