package repopolicy

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// extractMiseTaskScript pulls one task's `run = """...."""` body out of
// mise.toml, mirroring the awk extraction tests/mise-check-test.sh and
// tests/mise-install-test.sh used before this port. header is the exact
// table header line, e.g. "[tasks.check]".
func extractMiseTaskScript(t *testing.T, root, header string) string {
	t.Helper()
	f, err := os.Open(filepath.Join(root, "mise.toml"))
	if err != nil {
		t.Fatalf("reading mise.toml: %v", err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	var body []string
	inTask, inRun := false, false
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case !inTask:
			if line == header {
				inTask = true
			}
		case inTask && !inRun:
			if line == `run = """` {
				inRun = true
			}
		case inRun:
			if line == `"""` {
				goto done
			}
			body = append(body, line)
		}
	}
done:
	if err := scanner.Err(); err != nil {
		t.Fatalf("scanning mise.toml: %v", err)
	}
	if len(body) == 0 {
		t.Fatalf("mise.toml task %s has no run body (or was not found)", header)
	}

	script := ""
	for _, l := range body {
		script += l + "\n"
	}
	return script
}

// writeExecutableScript writes script to dir/name and makes it executable.
func writeExecutableScript(t *testing.T, dir, name, script string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("writing %s: %v", path, err)
	}
	return path
}

// writeStub writes a fake executable at dir/name that just prints body's
// output when invoked with any arguments (used to fake git/gh/openspec/an
// agent harness being present on PATH without needing the real tool).
func writeStub(t *testing.T, dir, name, printLine string) {
	t.Helper()
	script := fmt.Sprintf("#!/usr/bin/env bash\nprintf '%%s\\n' %q\n", printLine)
	writeExecutableScript(t, dir, name, script)
}
