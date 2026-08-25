package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/callmeradical/sergeant/internal/config"
	"github.com/callmeradical/sergeant/internal/export"
	"github.com/callmeradical/sergeant/internal/store"
)

// recordingTarget is a test-only export.Target that counts how many times
// Export is called, so a test can prove a Runner actually started delivering
// without depending on any real backend.
type recordingTarget struct {
	calls atomic.Int64
}

func (t *recordingTarget) Export(ctx context.Context, rec export.Record) error {
	t.calls.Add(1)
	return nil
}

func writeProjectYAML(t *testing.T, dir, filename, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, filename), []byte(body), 0644); err != nil {
		t.Fatalf("writing project yaml: %v", err)
	}
}

func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "sergeant.db"))
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	return st
}

// A project configuring a backend name that IS registered in the backends
// map passed to startExportRunners causes a Runner to start and actually
// deliver — export.Runner.Run calls Tick immediately, before its first
// ticker interval, so a bounded poll (well under defaultInterval) is enough.
func TestRegisteredBackendStartsExporting(t *testing.T) {
	configDir := t.TempDir()
	t.Setenv("SERGEANT_CONFIG", configDir)
	writeProjectYAML(t, configDir, "proj.yaml", `
project: proj
repos:
  svc:
    path: /tmp/svc
export:
  backend: test-backend
`)

	target := &recordingTarget{}
	backends := map[string]export.Constructor{
		"test-backend": func(cfg config.Export) (export.Target, error) {
			return target, nil
		},
	}

	st := openTestStore(t)
	// A Runner delivers changes recorded on the store's change log; a store
	// with none yet would poll and find nothing, indistinguishable from a
	// Runner that never started. Seed one intent so a delivered call proves
	// the Runner actually ran.
	if err := st.CreateIntent(&store.IntentRecord{ID: "intent-1", Project: "proj", Status: "proposed"}); err != nil {
		t.Fatalf("seeding intent: %v", err)
	}
	startExportRunners(st, backends)

	deadline := time.Now().Add(2 * time.Second)
	for target.calls.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for registered backend's Target.Export to be called")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// A project configuring a backend name with NO entry in the backends map
// must be handled exactly as before this change: reported to stderr,
// nothing constructed, nothing started.
func TestUnregisteredBackendNameStartsNothing(t *testing.T) {
	configDir := t.TempDir()
	t.Setenv("SERGEANT_CONFIG", configDir)
	writeProjectYAML(t, configDir, "proj.yaml", `
project: proj
repos:
  svc:
    path: /tmp/svc
export:
  backend: unknown-backend
`)

	var constructed int32
	backends := map[string]export.Constructor{
		"test-backend": func(cfg config.Export) (export.Target, error) {
			atomic.AddInt32(&constructed, 1)
			return &recordingTarget{}, nil
		},
	}

	st := openTestStore(t)
	stderr := captureStderr(t, func() {
		startExportRunners(st, backends)
		time.Sleep(50 * time.Millisecond)
	})

	if atomic.LoadInt32(&constructed) != 0 {
		t.Fatal("expected no Constructor to be called for an unregistered backend name")
	}
	want := `export: project "proj" configures backend "unknown-backend", but no export target implementation is registered yet; skipping`
	if !strings.Contains(stderr, want) {
		t.Fatalf("stderr = %q, want it to contain %q", stderr, want)
	}
}

// A project with no export: block at all must cause no lookup, no
// construction, and no report.
func TestNoExportBlockStartsAndReportsNothing(t *testing.T) {
	configDir := t.TempDir()
	t.Setenv("SERGEANT_CONFIG", configDir)
	writeProjectYAML(t, configDir, "proj.yaml", `
project: proj
repos:
  svc:
    path: /tmp/svc
`)

	var constructed int32
	backends := map[string]export.Constructor{
		"test-backend": func(cfg config.Export) (export.Target, error) {
			atomic.AddInt32(&constructed, 1)
			return &recordingTarget{}, nil
		},
	}

	st := openTestStore(t)
	stderr := captureStderr(t, func() {
		startExportRunners(st, backends)
		time.Sleep(50 * time.Millisecond)
	})

	if atomic.LoadInt32(&constructed) != 0 {
		t.Fatal("expected no Constructor to be called for a project with no export block")
	}
	if strings.Contains(stderr, "proj") {
		t.Fatalf("stderr = %q, want no mention of the project with no export block", stderr)
	}
}

// captureStderr redirects os.Stderr for the duration of fn and returns
// everything written to it. Serialized via a package-level mutex since
// os.Stderr is process-global state.
var stderrCaptureMu sync.Mutex

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	stderrCaptureMu.Lock()
	defer stderrCaptureMu.Unlock()

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("creating pipe: %v", err)
	}
	orig := os.Stderr
	os.Stderr = w

	done := make(chan string, 1)
	go func() {
		buf := make([]byte, 0, 4096)
		tmp := make([]byte, 4096)
		for {
			n, err := r.Read(tmp)
			if n > 0 {
				buf = append(buf, tmp[:n]...)
			}
			if err != nil {
				break
			}
		}
		done <- string(buf)
	}()

	fn()

	os.Stderr = orig
	w.Close()
	out := <-done
	r.Close()
	return out
}
