package plan_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/callmeradical/sergeant/internal/plan"
)

// ---------------------------------------------------------------------------
// ParseScenarios
// ---------------------------------------------------------------------------

func TestParseScenariosEightDeclarations(t *testing.T) {
	spec := `
# Requirements

#### Scenario: The checklist has one item per declared scenario

Some body text.

#### Scenario: The checklist exists before the agent starts

Another body.

#### Scenario: A change declaring no scenarios yields an empty plan, not a missing one

Body.

#### Scenario: Marking an item is observable

Body.

#### Scenario: An unwritten plan reports nothing, not zero

Body.

#### Scenario: A malformed plan does not fail the run

Body.

#### Scenario: A fully reported plan does not pass a run

Body.

#### Scenario: Progress is shown alongside status, not instead of it

Body.
`
	scenarios := plan.ParseScenarios(spec)
	if len(scenarios) != 8 {
		t.Fatalf("got %d scenarios, want 8; texts: %v", len(scenarios), scenarios)
	}
}

func TestParseScenariosExtractsText(t *testing.T) {
	spec := "#### Scenario: The checklist has one item per declared scenario\n\nbody\n"
	scenarios := plan.ParseScenarios(spec)
	if len(scenarios) != 1 {
		t.Fatalf("got %d scenarios, want 1", len(scenarios))
	}
	if scenarios[0] != "The checklist has one item per declared scenario" {
		t.Errorf("text = %q; want %q", scenarios[0], "The checklist has one item per declared scenario")
	}
}

func TestParseScenariosZeroDeclarations(t *testing.T) {
	spec := "# Requirement\n\nSome prose with no scenarios.\n"
	scenarios := plan.ParseScenarios(spec)
	if len(scenarios) != 0 {
		t.Fatalf("got %d scenarios, want 0", len(scenarios))
	}
}

func TestParseScenariosIgnoresLowerLevelHeadings(t *testing.T) {
	// Only #### Scenario: counts; ### or ##### must not match.
	spec := `
### Scenario: not a scenario (three hashes)
##### Scenario: not a scenario (five hashes)
#### Scenario: this one counts
`
	scenarios := plan.ParseScenarios(spec)
	if len(scenarios) != 1 {
		t.Fatalf("got %d scenarios, want 1; texts: %v", len(scenarios), scenarios)
	}
	if scenarios[0] != "this one counts" {
		t.Errorf("text = %q", scenarios[0])
	}
}

func TestParseScenariosTrimsWhitespace(t *testing.T) {
	spec := "#### Scenario:   Leading and trailing spaces   \n\nbody\n"
	scenarios := plan.ParseScenarios(spec)
	if len(scenarios) != 1 {
		t.Fatalf("got %d scenarios, want 1", len(scenarios))
	}
	if scenarios[0] != "Leading and trailing spaces" {
		t.Errorf("text = %q", scenarios[0])
	}
}

// ---------------------------------------------------------------------------
// ParseScenariosFromDir — reads all spec.md files under specs/
// ---------------------------------------------------------------------------

func TestParseScenariosFromDirEightScenarios(t *testing.T) {
	dir := t.TempDir()
	specDir := filepath.Join(dir, "specs", "progress")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := buildSpecWith(8)
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	scenarios, err := plan.ParseScenariosFromDir(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(scenarios) != 8 {
		t.Fatalf("got %d scenarios, want 8", len(scenarios))
	}
}

func TestParseScenariosFromDirZeroScenarios(t *testing.T) {
	dir := t.TempDir()
	specDir := filepath.Join(dir, "specs", "req")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte("# no scenarios here\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	scenarios, err := plan.ParseScenariosFromDir(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(scenarios) != 0 {
		t.Fatalf("got %d scenarios, want 0", len(scenarios))
	}
}

func TestParseScenariosFromDirNoSpecsDir(t *testing.T) {
	dir := t.TempDir()
	// No specs/ subdirectory at all.
	scenarios, err := plan.ParseScenariosFromDir(dir)
	if err != nil {
		t.Fatalf("unexpected error for absent specs/: %v", err)
	}
	if scenarios == nil {
		t.Fatal("returned nil; want empty slice")
	}
}

// ---------------------------------------------------------------------------
// SeedPlan
// ---------------------------------------------------------------------------

func TestSeedPlanItemCountMatchesDeclaredScenarios(t *testing.T) {
	// Scenario: The checklist has one item per declared scenario
	changeDir := t.TempDir()
	worktree := t.TempDir()

	specDir := filepath.Join(changeDir, "specs", "progress")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte(buildSpecWith(8)), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := plan.SeedPlan(changeDir, worktree); err != nil {
		t.Fatalf("SeedPlan: %v", err)
	}

	p := readPlanFrom(t, worktree)
	if len(p.Items) != 8 {
		t.Fatalf("plan has %d items, want 8", len(p.Items))
	}
}

func TestSeedPlanItemsArePending(t *testing.T) {
	changeDir := t.TempDir()
	worktree := t.TempDir()

	specDir := filepath.Join(changeDir, "specs", "s")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte(buildSpecWith(3)), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := plan.SeedPlan(changeDir, worktree); err != nil {
		t.Fatalf("SeedPlan: %v", err)
	}

	p := readPlanFrom(t, worktree)
	for i, item := range p.Items {
		if item.Status != plan.StatusPending {
			t.Errorf("item[%d].Status = %q, want %q", i, item.Status, plan.StatusPending)
		}
	}
}

func TestSeedPlanItemsHaveStableIDs(t *testing.T) {
	changeDir := t.TempDir()
	worktree := t.TempDir()

	specDir := filepath.Join(changeDir, "specs", "s")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte(buildSpecWith(3)), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := plan.SeedPlan(changeDir, worktree); err != nil {
		t.Fatalf("SeedPlan: %v", err)
	}

	p := readPlanFrom(t, worktree)

	// IDs must be non-empty and unique.
	seen := map[string]bool{}
	for i, item := range p.Items {
		if item.ID == "" {
			t.Errorf("item[%d] has empty ID", i)
		}
		if seen[item.ID] {
			t.Errorf("item[%d] id %q is a duplicate", i, item.ID)
		}
		seen[item.ID] = true
	}
}

func TestSeedPlanItemsCarryScenarioText(t *testing.T) {
	changeDir := t.TempDir()
	worktree := t.TempDir()

	text := "The checklist has one item per declared scenario"
	spec := "#### Scenario: " + text + "\n\nbody\n"

	specDir := filepath.Join(changeDir, "specs", "s")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte(spec), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := plan.SeedPlan(changeDir, worktree); err != nil {
		t.Fatalf("SeedPlan: %v", err)
	}

	p := readPlanFrom(t, worktree)
	if len(p.Items) != 1 {
		t.Fatalf("got %d items, want 1", len(p.Items))
	}
	if p.Items[0].Scenario != text {
		t.Errorf("item.Scenario = %q, want %q", p.Items[0].Scenario, text)
	}
}

// Scenario: A change declaring no scenarios yields an empty plan, not a missing one
func TestSeedPlanZeroScenariosWritesEmptyPlanNotMissingOne(t *testing.T) {
	changeDir := t.TempDir()
	worktree := t.TempDir()

	// A spec file with no #### Scenario: headings.
	specDir := filepath.Join(changeDir, "specs", "s")
	if err := os.MkdirAll(specDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(specDir, "spec.md"), []byte("# no scenarios\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := plan.SeedPlan(changeDir, worktree); err != nil {
		t.Fatalf("SeedPlan: %v", err)
	}

	// File must exist.
	planPath := filepath.Join(worktree, ".sergeant", "plan.json")
	if _, err := os.Stat(planPath); os.IsNotExist(err) {
		t.Fatal("plan.json does not exist; a zero-scenario change must produce an empty plan, not a missing one")
	}

	p := readPlanFrom(t, worktree)
	if len(p.Items) != 0 {
		t.Fatalf("got %d items, want 0", len(p.Items))
	}
}

// Scenario: The checklist exists before the agent starts — we test this
// structurally: SeedPlan returns before the caller would start an agent.
// The integration ordering test lives in internal/ui.

// ---------------------------------------------------------------------------
// ReadPlan
// ---------------------------------------------------------------------------

// Scenario: A malformed plan does not fail the run
func TestReadPlanMalformedReturnsNilNotError(t *testing.T) {
	worktree := t.TempDir()
	planPath := filepath.Join(worktree, ".sergeant", "plan.json")
	if err := os.MkdirAll(filepath.Dir(planPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(planPath, []byte("this is not json {{{"), 0o644); err != nil {
		t.Fatal(err)
	}

	p := plan.ReadPlan(worktree)
	if p != nil {
		t.Errorf("ReadPlan returned non-nil for malformed file; want nil (no progress reported)")
	}
}

// Scenario: An unwritten plan reports nothing, not zero
func TestReadPlanAbsentReturnsNilNotEmpty(t *testing.T) {
	worktree := t.TempDir()
	// No .sergeant/plan.json exists.
	p := plan.ReadPlan(worktree)
	if p != nil {
		t.Errorf("ReadPlan returned non-nil for absent file; want nil (no progress reported)")
	}
}

func TestReadPlanWellFormedReturnsItems(t *testing.T) {
	worktree := t.TempDir()

	raw := `{
		"items": [
			{"id":"s-1","scenario":"First","status":"complete"},
			{"id":"s-2","scenario":"Second","status":"in_progress"},
			{"id":"s-3","scenario":"Third","status":"pending"}
		]
	}`
	planPath := filepath.Join(worktree, ".sergeant", "plan.json")
	if err := os.MkdirAll(filepath.Dir(planPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(planPath, []byte(raw), 0o644); err != nil {
		t.Fatal(err)
	}

	p := plan.ReadPlan(worktree)
	if p == nil {
		t.Fatal("ReadPlan returned nil for a well-formed file")
	}
	if len(p.Items) != 3 {
		t.Fatalf("got %d items, want 3", len(p.Items))
	}
	if p.Items[0].Status != plan.StatusComplete {
		t.Errorf("item[0].Status = %q, want %q", p.Items[0].Status, plan.StatusComplete)
	}
	if p.Items[1].Status != plan.StatusInProgress {
		t.Errorf("item[1].Status = %q, want %q", p.Items[1].Status, plan.StatusInProgress)
	}
	if p.Items[2].Status != plan.StatusPending {
		t.Errorf("item[2].Status = %q, want %q", p.Items[2].Status, plan.StatusPending)
	}
}

// ---------------------------------------------------------------------------
// Progress helpers
// ---------------------------------------------------------------------------

func TestCountProgress(t *testing.T) {
	p := &plan.Plan{Items: []plan.PlanItem{
		{Status: plan.StatusComplete},
		{Status: plan.StatusComplete},
		{Status: plan.StatusInProgress},
		{Status: plan.StatusPending},
		{Status: plan.StatusPending},
	}}
	if got := p.Complete(); got != 2 {
		t.Errorf("Complete() = %d, want 2", got)
	}
	if got := p.Total(); got != 5 {
		t.Errorf("Total() = %d, want 5", got)
	}
}

// Scenario: Exactly one item is in progress at a time
// (A ReadPlan that sees two in-progress items is still valid JSON; the rule is
// enforced by the agent prompt, not by this package. But we do test InProgress.)
func TestInProgressItem(t *testing.T) {
	p := &plan.Plan{Items: []plan.PlanItem{
		{ID: "s-1", Status: plan.StatusComplete},
		{ID: "s-2", Status: plan.StatusInProgress},
		{ID: "s-3", Status: plan.StatusPending},
	}}
	item := p.InProgressItem()
	if item == nil {
		t.Fatal("InProgressItem() = nil, want item s-2")
	}
	if item.ID != "s-2" {
		t.Errorf("InProgressItem().ID = %q, want s-2", item.ID)
	}
}

func TestInProgressItemNoneReturnsNil(t *testing.T) {
	p := &plan.Plan{Items: []plan.PlanItem{
		{Status: plan.StatusPending},
		{Status: plan.StatusPending},
	}}
	if got := p.InProgressItem(); got != nil {
		t.Errorf("InProgressItem() = %+v, want nil", got)
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func readPlanFrom(t *testing.T, worktree string) *plan.Plan {
	t.Helper()
	planPath := filepath.Join(worktree, ".sergeant", "plan.json")
	data, err := os.ReadFile(planPath)
	if err != nil {
		t.Fatalf("reading plan.json: %v", err)
	}
	var p plan.Plan
	if err := json.Unmarshal(data, &p); err != nil {
		t.Fatalf("unmarshalling plan.json: %v", err)
	}
	return &p
}

func buildSpecWith(n int) string {
	var sb strings.Builder
	sb.WriteString("# Requirements\n\n")
	for i := 0; i < n; i++ {
		sb.WriteString("#### Scenario: Scenario number ")
		sb.WriteString(strings.Repeat("x", i+1))
		sb.WriteString("\n\nSome body text.\n\n")
	}
	return sb.String()
}
