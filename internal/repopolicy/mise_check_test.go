package repopolicy

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestMiseCheckValidatesV2EnginePrerequisites runs mise.toml's real
// [tasks.check] script (extracted, not reimplemented) against a controlled
// PATH of fake stub binaries, so the assertions exercise the actual
// automation an operator runs via `mise run check`.
func TestMiseCheckValidatesV2EnginePrerequisites(t *testing.T) {
	root := repoRoot(t)
	checkScript := writeExecutableScript(t, t.TempDir(), "check.sh", extractMiseTaskScript(t, root, "[tasks.check]"))

	writeRequiredStubs := func(dir string) {
		for _, cmd := range []string{"git", "gh", "openspec"} {
			writeStub(t, dir, cmd, cmd+" version 1.0")
		}
	}

	runCheck := func(agent string) (string, error) {
		dir := t.TempDir()
		writeRequiredStubs(dir)
		switch agent {
		case "opencode":
			writeStub(t, dir, "opencode", "OpenCode 1.0")
		case "claude":
			writeStub(t, dir, "claude", "Claude Code 1.0")
		}
		cmd := exec.Command(checkScript)
		cmd.Env = append(os.Environ(),
			"PATH="+dir+":/usr/bin:/bin:/usr/sbin:/sbin",
			"MISE_PROJECT_ROOT="+root,
		)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}

	t.Run("no supported agent harness fails", func(t *testing.T) {
		out, err := runCheck("none")
		if err == nil {
			t.Errorf("dependency check did not fail when no supported agent harness was present:\n%s", out)
		}
		if !strings.Contains(out, "MISSING") || !strings.Contains(out, "opencode oc claude goose codex pi") {
			t.Errorf("dependency check did not fail when no supported agent harness was present:\n%s", out)
		}
	})

	t.Run("opencode present passes", func(t *testing.T) {
		out, err := runCheck("opencode")
		if err != nil || !strings.Contains(out, "agent") || !strings.Contains(out, "ok   opencode") || !strings.Contains(out, "All v2 prerequisites present.") {
			t.Errorf("dependency check did not pass with a supported agent harness:\n%s (err=%v)", out, err)
		}
	})

	t.Run("claude present passes", func(t *testing.T) {
		out, err := runCheck("claude")
		if err != nil || !strings.Contains(out, "ok   claude") || !strings.Contains(out, "All v2 prerequisites present.") {
			t.Errorf("dependency check did not accept Claude:\n%s (err=%v)", out, err)
		}
	})

	t.Run("missing openspec fails even with an agent present", func(t *testing.T) {
		dir := t.TempDir()
		for _, cmd := range []string{"git", "gh"} {
			writeStub(t, dir, cmd, cmd+" version 1.0")
		}
		writeStub(t, dir, "opencode", "OpenCode 1.0")
		cmd := exec.Command(checkScript)
		cmd.Env = append(os.Environ(),
			"PATH="+dir+":/usr/bin:/bin:/usr/sbin:/sbin",
			"MISE_PROJECT_ROOT="+root,
		)
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), "openspec") || !strings.Contains(string(out), "MISSING") {
			t.Errorf("dependency check did not fail when openspec was missing:\n%s (err=%v)", out, err)
		}
	})
}
