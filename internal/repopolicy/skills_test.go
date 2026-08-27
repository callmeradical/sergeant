package repopolicy

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// expectedCanonicalSkills is the inventory .agents/skills/ is expected to
// hold. Ported verbatim from tests/repo-skills-test.sh, including its
// pre-existing drift against the real directory (sergeant-setup is listed
// here but does not exist on disk; "progress" and "to-tickets" exist on
// disk but one of them is not listed here) -- TestCanonicalSkillInventoryMatchesExpected
// already fails on main for this exact reason before this port, and
// continues to fail identically after it.
var expectedCanonicalSkills = []string{
	"code-review",
	"codebase-design",
	"diagnosing-bugs",
	"domain-modeling",
	"grill-with-docs",
	"grilling",
	"implement",
	"no-mistakes",
	"prototype",
	"research",
	"resolving-merge-conflicts",
	"sergeant-setup",
	"tdd",
	"to-spec",
	"to-tickets",
	"triage",
	"wayfinder",
}

func TestProjectLicenseAndSkillProvenanceFilesExist(t *testing.T) {
	root := repoRoot(t)

	licenseText, err := readFile(t, root, "LICENSE")
	if err != nil {
		t.Fatalf("missing project LICENSE: %v", err)
	}
	if !strings.Contains(licenseText, "Copyright (c) 2026 Lars Cromley") {
		t.Error("LICENSE does not contain the expected copyright line")
	}

	if _, err := readFile(t, root, filepath.Join(".agents", "skills", "PROVENANCE.md")); err != nil {
		t.Errorf("missing skill provenance: %v", err)
	}
	if _, err := readFile(t, root, filepath.Join(".agents", "skills", "THIRD_PARTY_NOTICES.md")); err != nil {
		t.Errorf("missing third-party notices: %v", err)
	}
}

func TestCanonicalSkillInventoryMatchesExpected(t *testing.T) {
	root := repoRoot(t)
	canonicalDir := filepath.Join(root, ".agents", "skills")

	entries, err := os.ReadDir(canonicalDir)
	if err != nil {
		t.Fatalf("reading %s: %v", canonicalDir, err)
	}

	var actual []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		skill := e.Name()
		actual = append(actual, skill)
		checkSkillFrontmatter(t, filepath.Join(canonicalDir, skill, "SKILL.md"), skill)
	}

	sort.Strings(actual)
	want := append([]string(nil), expectedCanonicalSkills...)
	sort.Strings(want)

	if !reflect.DeepEqual(actual, want) {
		t.Errorf("canonical inventory drift: got %v, want %v", actual, want)
	}

	if _, err := os.Stat(filepath.Join(canonicalDir, "no-mistakes")); err != nil {
		t.Error("no-mistakes skill must be vendored")
	}
}

// checkSkillFrontmatter asserts a SKILL.md's frontmatter: line 1 is "---",
// line 2 is "name: <skill>", line 3 starts "description: ", and a closing
// "---" line exists after line 1.
func checkSkillFrontmatter(t *testing.T, skillFile, skill string) {
	t.Helper()
	f, err := os.Open(skillFile)
	if err != nil {
		t.Errorf("missing SKILL.md: %s", skill)
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	var lines []string
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
		if len(lines) >= 3 {
			break
		}
	}
	if len(lines) < 3 {
		t.Errorf("%s: SKILL.md has fewer than 3 lines", skill)
		return
	}
	if lines[0] != "---" {
		t.Errorf("invalid frontmatter start: %s", skill)
	}
	if lines[1] != "name: "+skill {
		t.Errorf("invalid frontmatter name: %s", skill)
	}
	if !strings.HasPrefix(lines[2], "description: ") {
		t.Errorf("missing frontmatter description: %s", skill)
	}

	closed := false
	for scanner.Scan() {
		if scanner.Text() == "---" {
			closed = true
			break
		}
	}
	if !closed {
		t.Errorf("invalid frontmatter end: %s", skill)
	}
}

func TestClaudeSkillsAreSymlinksIntoCanonicalTree(t *testing.T) {
	root := repoRoot(t)
	canonicalDir := filepath.Join(root, ".agents", "skills")
	claudeDir := filepath.Join(root, ".claude", "skills")

	for _, skill := range expectedCanonicalSkills {
		link := filepath.Join(claudeDir, skill)
		info, err := os.Lstat(link)
		if err != nil {
			t.Errorf("Claude skill is not present: %s (%v)", skill, err)
			continue
		}
		if info.Mode()&os.ModeSymlink == 0 {
			t.Errorf("Claude skill is not a symlink: %s", skill)
			continue
		}
		resolved, err := filepath.EvalSymlinks(link)
		if err != nil {
			t.Errorf("Claude skill link is broken: %s (%v)", skill, err)
			continue
		}
		wantTarget, err := filepath.EvalSymlinks(filepath.Join(canonicalDir, skill))
		if err != nil {
			t.Errorf("canonical skill target missing: %s (%v)", skill, err)
			continue
		}
		if resolved != wantTarget {
			t.Errorf("Claude skill link escapes canonical tree: %s (resolved %s, want %s)", skill, resolved, wantTarget)
		}
	}
}

func TestProceduralSkillFrontmatter(t *testing.T) {
	root := repoRoot(t)
	for _, skill := range []string{"load-project", "cross-repo-work", "dispatch"} {
		skillFile := filepath.Join(root, "skills", skill, "SKILL.md")
		f, err := os.Open(skillFile)
		if err != nil {
			t.Errorf("missing Sergeant procedural skill: %s (%v)", skill, err)
			continue
		}
		scanner := bufio.NewScanner(f)
		var lines []string
		for scanner.Scan() && len(lines) < 2 {
			lines = append(lines, scanner.Text())
		}
		f.Close()
		if len(lines) < 2 {
			t.Errorf("%s: SKILL.md has fewer than 2 lines", skill)
			continue
		}
		if lines[0] != "---" {
			t.Errorf("invalid procedural frontmatter: %s", skill)
		}
		if lines[1] != "name: "+skill {
			t.Errorf("invalid procedural skill name: %s", skill)
		}
	}
}

func TestOpenCodeConfigDeclaresSkillPaths(t *testing.T) {
	root := repoRoot(t)
	raw, err := readFile(t, root, "opencode.json")
	if err != nil {
		t.Fatalf("reading opencode.json: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatalf("parsing opencode.json: %v", err)
	}

	want := map[string]any{
		"$schema": "https://opencode.ai/config.json",
		"skills": map[string]any{
			"paths": []any{".agents/skills", "skills"},
		},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("opencode.json = %v, want %v", got, want)
	}
}

func TestThirdPartyNoticesAndProvenanceNameEveryVendoredSkill(t *testing.T) {
	root := repoRoot(t)
	notices, err := readFile(t, root, filepath.Join(".agents", "skills", "THIRD_PARTY_NOTICES.md"))
	if err != nil {
		t.Fatalf("reading THIRD_PARTY_NOTICES.md: %v", err)
	}

	for _, skill := range []string{
		"codebase-design", "code-review", "diagnosing-bugs", "domain-modeling",
		"grilling", "grill-with-docs", "implement", "prototype", "research",
		"resolving-merge-conflicts", "tdd", "to-spec", "triage", "wayfinder",
	} {
		if !strings.Contains(notices, "`"+skill+"`") {
			t.Errorf("missing notice: %s", skill)
		}
	}
	if !strings.Contains(notices, "Copyright (c) 2026 Matt Pocock") {
		t.Error("THIRD_PARTY_NOTICES.md missing Matt Pocock copyright")
	}
	if !strings.Contains(notices, "https://github.com/mattpocock/skills") {
		t.Error("THIRD_PARTY_NOTICES.md missing upstream skills URL")
	}
	if !strings.Contains(notices, "`to-tickets`") {
		t.Error("THIRD_PARTY_NOTICES.md missing to-tickets notice")
	}
	if !strings.Contains(notices, "`no-mistakes`") {
		t.Error("THIRD_PARTY_NOTICES.md missing no-mistakes notice")
	}
	if !strings.Contains(notices, "`sergeant-setup`") {
		t.Error("THIRD_PARTY_NOTICES.md missing sergeant-setup notice")
	}

	provenance, err := readFile(t, root, filepath.Join(".agents", "skills", "PROVENANCE.md"))
	if err != nil {
		t.Fatalf("reading PROVENANCE.md: %v", err)
	}
	if !strings.Contains(provenance, "no-mistakes") {
		t.Error("PROVENANCE.md missing no-mistakes")
	}
}
