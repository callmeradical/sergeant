// Package plan manages the agent progress checklist written into the worktree
// at dispatch time.
//
// Lifecycle:
//
//  1. Sergeant calls SeedPlan(changeDir, worktree) after the change is resolved
//     and the worktree is prepared, but BEFORE the agent phase starts.
//
//  2. The agent reads .sergeant/plan.json from its worktree and updates item
//     statuses as it works, marking items "in_progress" then "complete".
//
//  3. Sergeant calls ReadPlan(worktree) when the run is sampled and publishes
//     the result over the existing change stream.
//
// Sergeant is the sole seeder and thereafter only reads. Two writers would make
// a stale read indistinguishable from a concurrent write.
//
// An absent or malformed plan.json returns nil from ReadPlan — "no progress
// reported", never zero progress. Those are different statements, and only one
// of them is true before the agent has written.
package plan

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Item status values. The string constants are part of the file format, so
// they must not change without a migration. The agent prompt uses these exact
// strings.
const (
	StatusPending    = "pending"
	StatusInProgress = "in_progress"
	StatusComplete   = "complete"
)

// PlanItem is one declared scenario in the change, with its current status.
type PlanItem struct {
	// ID is a stable, unique identifier derived from the item's position in the
	// scenario list. Stable means it does not change when the file is rewritten
	// by the agent; position-based means no random number is needed.
	ID string `json:"id"`

	// Scenario is the text extracted from the #### Scenario: heading, trimmed.
	Scenario string `json:"scenario"`

	// Status is one of StatusPending, StatusInProgress, StatusComplete.
	Status string `json:"status"`
}

// Plan is the serialised form of .sergeant/plan.json.
type Plan struct {
	Items []PlanItem `json:"items"`
}

// Complete returns the number of items whose status is StatusComplete.
func (p *Plan) Complete() int {
	n := 0
	for _, item := range p.Items {
		if item.Status == StatusComplete {
			n++
		}
	}
	return n
}

// Total returns the total number of items in the plan.
func (p *Plan) Total() int { return len(p.Items) }

// InProgressItem returns the first item with StatusInProgress, or nil if none
// is in that state. The spec permits exactly one in-progress item at a time;
// this returns the first in case the agent writes two (which is a reporting
// oddity, not a fatal error).
func (p *Plan) InProgressItem() *PlanItem {
	for i := range p.Items {
		if p.Items[i].Status == StatusInProgress {
			return &p.Items[i]
		}
	}
	return nil
}

// ParseScenarios extracts the text of every #### Scenario: heading from a
// Markdown string. Only exactly four leading hashes followed by a space and
// "Scenario:" match; three or five hashes are silently ignored so that a
// sub-requirement's scenario does not inflate the count.
func ParseScenarios(markdown string) []string {
	const prefix = "#### Scenario:"
	var out []string
	for _, line := range strings.Split(markdown, "\n") {
		text := strings.TrimRight(line, "\r")
		if !strings.HasPrefix(text, prefix) {
			continue
		}
		scenario := strings.TrimSpace(text[len(prefix):])
		if scenario != "" {
			out = append(out, scenario)
		}
	}
	return out
}

// ParseScenariosFromDir walks changeDir/specs/**/*.md and collects all
// #### Scenario: headings across every file.
//
// An absent specs/ directory is not an error; it means the change has no spec
// files and therefore no scenarios, which yields an empty (non-nil) slice.
func ParseScenariosFromDir(changeDir string) ([]string, error) {
	specsRoot := filepath.Join(changeDir, "specs")
	if _, err := os.Stat(specsRoot); os.IsNotExist(err) {
		return []string{}, nil
	}

	var scenarios []string
	err := filepath.WalkDir(specsRoot, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".md") {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return fmt.Errorf("reading %s: %w", path, readErr)
		}
		scenarios = append(scenarios, ParseScenarios(string(data))...)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if scenarios == nil {
		scenarios = []string{}
	}
	return scenarios, nil
}

// planFilePath is the canonical path of plan.json inside a worktree.
func planFilePath(worktree string) string {
	return filepath.Join(worktree, ".sergeant", "plan.json")
}

// SeedPlan writes .sergeant/plan.json into worktree, one pending item per
// #### Scenario: found in changeDir/specs/**/*.md. It is idempotent on first
// call: if plan.json already exists it is overwritten.
//
// A change with no declared scenarios produces a zero-item plan file. The
// absence of scenarios is a fact about the change; a missing file would be
// indistinguishable from a seed that failed.
//
// Sergeant seeds the file and then never writes to it again. The agent is the
// only subsequent writer.
func SeedPlan(changeDir, worktree string) error {
	scenarios, err := ParseScenariosFromDir(changeDir)
	if err != nil {
		return fmt.Errorf("parsing scenarios from %s: %w", changeDir, err)
	}

	items := make([]PlanItem, 0, len(scenarios))
	for i, text := range scenarios {
		items = append(items, PlanItem{
			ID:       fmt.Sprintf("s-%d", i+1),
			Scenario: text,
			Status:   StatusPending,
		})
	}

	p := Plan{Items: items}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding plan: %w", err)
	}

	dir := filepath.Dir(planFilePath(worktree))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating .sergeant dir in worktree: %w", err)
	}

	if err := os.WriteFile(planFilePath(worktree), data, 0o644); err != nil {
		return fmt.Errorf("writing plan.json: %w", err)
	}
	return nil
}

// ReadPlan reads .sergeant/plan.json from the worktree and returns the parsed
// plan, or nil if the file is absent or cannot be parsed.
//
// nil means "no progress reported" — the caller must render this differently
// from a plan with zero complete items. Sergeant never fails a run because the
// plan file is unreadable.
func ReadPlan(worktree string) *Plan {
	data, err := os.ReadFile(planFilePath(worktree))
	if err != nil {
		// Absent file is the expected state before the first seed: not an error.
		return nil
	}
	var p Plan
	if err := json.Unmarshal(data, &p); err != nil {
		// Malformed file must not fail the run.
		return nil
	}
	return &p
}
