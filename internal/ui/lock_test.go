package ui

import (
	"os"
	"path/filepath"
	"testing"
)

// Scenario: a second process cannot acquire the UI lock while the first
// holds it, and can once the first releases it.
func TestAcquireUILockRefusesASecondHolderUntilReleased(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sergeant-ui.lock")
	t.Setenv("SERGEANT_UI_LOCK", path)

	first, err := acquireUILock()
	if err != nil {
		t.Fatalf("first acquireUILock: %v", err)
	}

	if _, err := acquireUILock(); err == nil {
		t.Fatal("second acquireUILock succeeded while the first still holds the lock; want an error")
	}

	if err := first.Close(); err != nil {
		t.Fatalf("closing first lock: %v", err)
	}

	second, err := acquireUILock()
	if err != nil {
		t.Fatalf("acquireUILock after release: %v", err)
	}
	_ = second.Close()
}

// Scenario: acquiring the lock creates its parent directory if absent, so a
// fresh install with no ~/.local/share/sergeant-v2/ yet still starts.
func TestAcquireUILockCreatesItsParentDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "dir", "sergeant-ui.lock")
	t.Setenv("SERGEANT_UI_LOCK", path)

	f, err := acquireUILock()
	if err != nil {
		t.Fatalf("acquireUILock: %v", err)
	}
	defer f.Close()

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("lock file does not exist at %s: %v", path, err)
	}
}

// Scenario: releasing the lock (closing the file) lets a subsequent
// acquire succeed even from what looks like the same process — proves the
// lock is tied to the open file descriptor, not to a PID recorded in the
// file, so it cannot go stale the way a PID file can (e.g. after a PID
// gets reused by an unrelated process).
func TestReleasingTheLockIsWhatUnblocksReacquisitionNotProcessIdentity(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sergeant-ui.lock")
	t.Setenv("SERGEANT_UI_LOCK", path)

	f1, err := acquireUILock()
	if err != nil {
		t.Fatalf("acquireUILock: %v", err)
	}
	_ = f1.Close()

	f2, err := acquireUILock()
	if err != nil {
		t.Fatalf("acquireUILock after close: %v", err)
	}
	defer f2.Close()

	f3, err := acquireUILock()
	if err == nil {
		f3.Close()
		t.Fatal("acquireUILock succeeded while f2 still holds the lock; want an error")
	}
}
