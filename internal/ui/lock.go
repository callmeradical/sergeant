package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// uiLockPath is the file whose exclusive lock ensures at most one sergeant
// ui process runs at a time. Start's own doc comment says
// ReconcileOrphanedRuns "must never be called again" once a coordinator has
// started; that is sound only if there is exactly one coordinator. A second
// instance opening the same store would reconcile a live run out from under
// it — silently, with no error, and (once it died on the port-bind conflict
// that followed) with no surviving trace (progress.html Review 034).
//
// SERGEANT_UI_LOCK overrides the path so tests never contend with, or wait
// behind, a real running instance's lock.
func uiLockPath() string {
	if p := os.Getenv("SERGEANT_UI_LOCK"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "sergeant-v2", "sergeant-ui.lock")
}

// acquireUILock takes a non-blocking exclusive lock on uiLockPath, refusing
// immediately rather than queuing behind an already-running instance — a
// second sergeant ui process waiting to start is exactly as unsound as one
// that started, since it would still eventually reconcile a live run.
//
// The returned file must be kept open (not closed) for the caller's
// lifetime. The lock releases automatically on process exit, including a
// crash: it is an OS-level flock, not application state a crash could leave
// stale and requiring cleanup.
func acquireUILock() (*os.File, error) {
	path := uiLockPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("creating lock directory for %s: %w", path, err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening lock file %s: %w", path, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("another sergeant ui process is already running (lock held on %s)", path)
	}
	return f, nil
}
