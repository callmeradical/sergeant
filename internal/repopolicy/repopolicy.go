// Package repopolicy tests repository-level policy that has no other natural
// home in the Go source tree: AGENTS.md/README.md content, skill file
// structure, and the mise.toml automation an operator actually runs. These
// were bash scripts under tests/*.sh; ported to go test so `go test ./...`
// covers them on this Go-native branch without needing bash at all.
package repopolicy

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// repoRoot locates the repository from this file rather than the working
// directory, so these tests read the same files regardless of which package
// `go test` is invoked from.
func repoRoot(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed, cannot locate the repository")
	}
	// <root>/internal/repopolicy/repopolicy.go
	return filepath.Dir(filepath.Dir(filepath.Dir(thisFile)))
}

func readFile(t *testing.T, root, rel string) (string, error) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		return "", err
	}
	return string(b), nil
}
