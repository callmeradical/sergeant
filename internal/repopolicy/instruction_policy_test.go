package repopolicy

import (
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// requiredFiles must exist for AGENTS.md/skills to have anything to point at.
var requiredFiles = []string{
	"skills/load-project/SKILL.md",
	"skills/cross-repo-work/SKILL.md",
	"skills/dispatch/SKILL.md",
	"skills/wiki/SKILL.md",
	"skills/sergeant-help/SKILL.md",

	"docs/README.md",
	"docs/troubleshooting.md",

	// what-is-sergeant.md, getting-started.md, skills.md, and using-sergeant.md
	// described the removed v1 sgt-* toolbelt throughout with no v2 procedure
	// to substitute in-place; they were archived to docs/archive/v1/ rather
	// than rewritten in place, so no live doc at those paths is required.
	"docs/archive/v1/what-is-sergeant.md",
	"docs/archive/v1/getting-started.md",
	"docs/archive/v1/skills.md",
	"docs/archive/v1/using-sergeant.md",
}

// requiredText asserts Path must contain Text (exact substring).
type requiredText struct {
	path, text string
}

var mustContain = []requiredText{
	{"AGENTS.md", "## Procedural skills"},
	{"AGENTS.md", "`sergeant-help`"},
	{"AGENTS.md", ".sergeant-intent.md"},
	{"AGENTS.md", "same canonical intent revision"},
	// Matches skills/wiki/SKILL.md's own "When to use" wording exactly.
	{"AGENTS.md", "ingest, backfill, regenerate, inspect, update, or change wiki output"},
	{"skills/wiki/SKILL.md", "ingest, backfill, regenerate, inspect, update, or change wiki output"},
	{"AGENTS.md", "Sergeant-owned procedural skills live at `skills/<name>/SKILL.md`"},
	{"AGENTS.md", "read that repository-local file directly"},
	{"AGENTS.md", "takes precedence over any same-named registry skill"},
	{"AGENTS.md", "Do not ask the owner or stop solely because the registry omits"},
	{"AGENTS.md", "Only stop and report the exact repository-local path"},
	{"AGENTS.md", "absent or unreadable; do not reconstruct a partial"},
	{"README.md", "docs/README.md"},

	{"skills/cross-repo-work/SKILL.md", "If the user requested planning only"},
	{"skills/dispatch/SKILL.md", "POST /api/dispatch"},
	{"skills/dispatch/SKILL.md", "POST /api/run-resume"},
	{".agents/skills/to-tickets/SKILL.md", "read-only export"},

	{"skills/load-project/SKILL.md", "## Project registration and edits"},
	{"skills/load-project/SKILL.md", "## Project Graphify"},
	{"skills/wiki/SKILL.md", "## When to use"},
	{"skills/sergeant-help/SKILL.md", "## When to use"},
	{"skills/sergeant-help/SKILL.md", "only when the command supports"},
}

var mustNotContain = []requiredText{
	// v1's "direct mode" (the coordinator implementing one repo's work
	// in-session instead of dispatching) is deliberately not part of v2:
	// v2's AGENTS.md states its two entry paths (agent-driven MCP,
	// coordinator-driven /api/dispatch) and that "adding a third, divergent
	// execution model is a bug." Direct mode would be exactly that third
	// model, so v2's AGENTS.md must not describe it -- confirmed with the
	// user, not merely omitted.
	{"AGENTS.md", "direct executor when requested"},
	{"AGENTS.md", "direct mode"},
	{"AGENTS.md", "td context <id> --work-dir"},
	{"AGENTS.md", "If a required skill cannot be loaded, stop before the procedure"},
	{"AGENTS.md", "gives one repository as the complete scope"},
	{"AGENTS.md", "## Project YAML schema (summary)"},
	{"AGENTS.md", "## td task management integration"},
	{"AGENTS.md", "## Wiki integration"},
	{"AGENTS.md", `no-mistakes axi run --intent "<the user`},

	{"README.md", ".sergeant-intent.md"},
	{"README.md", "--intent-file"},
	{"README.md", "bin/sgt-"},
	{"README.md", "tmux new-session"},

	{"skills/dispatch/SKILL.md", "Ask for confirmation before dispatching."},
	{"skills/dispatch/SKILL.md", "remain alive, and wait"},
	{"skills/dispatch/SKILL.md", "sgt-dispatch"},
	{"skills/dispatch/SKILL.md", "sgt-watch"},
	{"skills/dispatch/SKILL.md", "sgt-respond"},
	{"skills/dispatch/SKILL.md", "treehouse"},
	{"skills/cross-repo-work/SKILL.md", "sgt-context"},
	{"skills/cross-repo-work/SKILL.md", "sgt-status"},
	{"skills/cross-repo-work/SKILL.md", "sgt-dispatch"},
	{"skills/load-project/SKILL.md", "sgt-list"},
	{"skills/load-project/SKILL.md", "sgt-context"},
	{"skills/load-project/SKILL.md", "sgt-sync"},
	{"skills/load-project/SKILL.md", "sgt-graphify"},
	{"skills/wiki/SKILL.md", "sgt-dispatch"},
	{"skills/wiki/SKILL.md", "sgt-notify"},
	{"skills/wiki/SKILL.md", "sgt-cleanup"},
	{".agents/skills/to-tickets/SKILL.md", "sgt-td-create"},
	{".agents/skills/to-tickets/SKILL.md", "sgt-list"},
	{".agents/skills/to-tickets/SKILL.md", "sgt-context"},
	{"docs/troubleshooting.md", "sgt-cleanup"},
	{"docs/troubleshooting.md", "sgt-sync"},
	{"schema/project.yaml.example", "sgt-graphify"},
	{"schema/project.yaml.example", "sgt-sync"},
	{"schema/project.yaml.example", "sgt-dag-run"},
	{"schema/project.yaml.example", "sgt-watch"},
}

func TestInstructionFilesExist(t *testing.T) {
	root := repoRoot(t)
	for _, rel := range requiredFiles {
		if _, err := readFile(t, root, rel); err != nil {
			t.Errorf("missing required instruction file: %s (%v)", rel, err)
		}
	}
}

func TestInstructionTextRequired(t *testing.T) {
	root := repoRoot(t)
	for _, rt := range mustContain {
		content, err := readFile(t, root, rt.path)
		if err != nil {
			t.Errorf("%s: %v", rt.path, err)
			continue
		}
		if !strings.Contains(content, rt.text) {
			t.Errorf("%s must contain: %s", rt.path, rt.text)
		}
	}
}

func TestInstructionTextProhibited(t *testing.T) {
	root := repoRoot(t)
	for _, rt := range mustNotContain {
		content, err := readFile(t, root, rt.path)
		if err != nil {
			t.Errorf("%s: %v", rt.path, err)
			continue
		}
		if strings.Contains(content, rt.text) {
			t.Errorf("%s contains prohibited instruction: %s", rt.path, rt.text)
		}
	}
}

var vagueQualityLanguage = regexp.MustCompile(`(?i)(be thorough|write clean code|high[- ]quality|make it readable|best practices|be careful|do it properly|internalize)`)

// TestSkillsHaveNoVagueQualityLanguage matches this project's own policy: a
// directive that cannot change a decision or be checked after the work is
// removed, not softened into "be thorough"/"best practices"-style prose.
func TestSkillsHaveNoVagueQualityLanguage(t *testing.T) {
	root := repoRoot(t)
	matches, err := filepath.Glob(filepath.Join(root, "skills", "*", "SKILL.md"))
	if err != nil {
		t.Fatalf("globbing skills/*/SKILL.md: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no skills/*/SKILL.md files found")
	}
	for _, path := range matches {
		b, err := readFile(t, root, mustRel(t, root, path))
		if err != nil {
			t.Errorf("%s: %v", path, err)
			continue
		}
		if vagueQualityLanguage.MatchString(b) {
			rel := mustRel(t, root, path)
			t.Errorf("%s contains vague no-op quality language", rel)
		}
	}
}

// TestAGENTSHasNoVagueDirectiveOutsideItsOwnExamples allows a vague phrase to
// appear once (e.g. as a prohibited example inside a policy statement about
// vague language); a second occurrence means it crept back in as real prose.
func TestAGENTSHasNoVagueDirectiveOutsideItsOwnExamples(t *testing.T) {
	root := repoRoot(t)
	content, err := readFile(t, root, "AGENTS.md")
	if err != nil {
		t.Fatalf("AGENTS.md: %v", err)
	}
	lines := strings.Split(strings.ToLower(content), "\n")
	for _, phrase := range []string{"be thorough", "write clean code", "make it readable", "use best practices"} {
		// Matches `grep -Fic`: count lines containing the phrase at least
		// once, not total occurrences (two hits on one line count as one).
		matchingLines := 0
		for _, line := range lines {
			if strings.Contains(line, phrase) {
				matchingLines++
			}
		}
		if matchingLines > 1 {
			t.Errorf("AGENTS.md contains vague no-op directive outside its prohibited examples: %s", phrase)
		}
	}
}

func mustRel(t *testing.T, root, path string) string {
	t.Helper()
	rel, err := filepath.Rel(root, path)
	if err != nil {
		t.Fatalf("computing relative path for %s: %v", path, err)
	}
	return rel
}
