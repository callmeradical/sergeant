package repopolicy

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// TestDistributionHasNoRemoteExecutionContract asserts the obsolete remote
// execution contract (a distinct, now-removed feature, not v1's local
// bash/tmux toolbelt) left no trace across the paths an operator or agent
// actually reads. The forbidden terms are built from concatenated parts so
// this file's own source never contains the literal strings it forbids
// elsewhere -- ported from tests/no-remote-test.sh, which obfuscated the
// same way for the same reason (that script's own scanned path list included
// tests/, so a plain literal would have matched itself).
func TestDistributionHasNoRemoteExecutionContract(t *testing.T) {
	root := repoRoot(t)

	forbidden := regexp.MustCompile(
		"baby" + "driver" +
			"|--" + "remote" +
			"|remote-" + "baby" + "driver" +
			"|remote_" + "project_dir" +
			"|remote_" + "session" +
			"|remote_" + "window" +
			"|remote_" + "td_task" +
			"|remote_" + "response_pending",
	)

	scanPaths := []string{"AGENTS.md", "README.md", "bin", "mise.toml", "schema", "skills", "tests"}

	var offenders []string
	for _, rel := range scanPaths {
		full := filepath.Join(root, rel)
		info, err := os.Stat(full)
		if err != nil {
			// bin/ and tests/ always exist in this repo; a missing path here
			// is not this test's concern, so skip rather than fail on it.
			continue
		}
		if !info.IsDir() {
			offenders = append(offenders, scanFileForRemoteContract(t, root, full, forbidden)...)
			continue
		}
		walkErr := filepath.WalkDir(full, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}
			offenders = append(offenders, scanFileForRemoteContract(t, root, path, forbidden)...)
			return nil
		})
		if walkErr != nil {
			t.Fatalf("walking %s: %v", full, walkErr)
		}
	}

	if len(offenders) > 0 {
		t.Errorf("obsolete remote execution contract remains:\n  %s", joinLines(offenders))
	}
}

func scanFileForRemoteContract(t *testing.T, root, path string, forbidden *regexp.Regexp) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	if !forbidden.Match(b) {
		return nil
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		rel = path
	}
	return []string{rel}
}

func joinLines(lines []string) string {
	out := ""
	for i, l := range lines {
		if i > 0 {
			out += "\n  "
		}
		out += l
	}
	return out
}
