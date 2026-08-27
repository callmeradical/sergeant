// Package mcplock implements the PID-recording lock file that lets multiple
// sergeant-mcp-client instances discover, or race to start, one shared
// sergeant-mcp server process. See openspec/changes/shared-mcp-server.
package mcplock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// ErrAlreadyRunning is returned by AcquireServerLock when a live process
// already holds the lock; the caller should exit 0 (a no-op server start),
// not treat this as a failure.
var ErrAlreadyRunning = errors.New("shared server already running")

// acquireRetries bounds the reclaim-then-race loop in AcquireServerLock. Each
// iteration either wins the lock, definitively loses it to a live PID, or
// (rarely) loses a race to reclaim a lock that a different contender just
// vacated -- a bounded retry resolves that without spinning forever.
const acquireRetries = 5

// StateDir returns the Sergeant state directory, defaulting to
// $HOME/.local/share/sergeant -- mirroring bin/_sgt-lib.sh's own
// FLEET_DIR/SERGEANT_FLEET default root, so the Go and bash sides agree on
// one state root without introducing a second config concept. Overridable via
// SERGEANT_STATE_DIR for test isolation.
func StateDir() string {
	if dir := os.Getenv("SERGEANT_STATE_DIR"); dir != "" {
		return dir
	}
	home := os.Getenv("HOME")
	if home == "" {
		if h, err := os.UserHomeDir(); err == nil {
			home = h
		}
	}
	return filepath.Join(home, ".local", "share", "sergeant")
}

// LockPath and SockPath are the well-known lock/socket paths within a state
// directory, per design.md.
func LockPath(stateDir string) string { return filepath.Join(stateDir, "mcp-server.lock") }
func SockPath(stateDir string) string { return filepath.Join(stateDir, "mcp-server.sock") }

// Record is the parsed contents of a lock file: "pid=<pid>\nsocket=<path>\n".
type Record struct {
	PID    int
	Socket string
}

// ReadRecord reads and parses the lock file at lockPath. It returns
// (nil, nil) when the file does not exist.
func ReadRecord(lockPath string) (*Record, error) {
	data, err := os.ReadFile(lockPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	rec := &Record{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch key {
		case "pid":
			pid, err := strconv.Atoi(value)
			if err != nil {
				return nil, fmt.Errorf("lock file %s: malformed pid %q: %w", lockPath, value, err)
			}
			rec.PID = pid
		case "socket":
			rec.Socket = value
		}
	}
	if rec.PID == 0 {
		return nil, fmt.Errorf("lock file %s: missing pid", lockPath)
	}
	return rec, nil
}

// PidAlive reports whether pid names a live process, via the standard Unix
// "is this PID alive" probe (signal 0 delivers nothing, only checks
// existence/permission).
func PidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, syscall.Signal(0))
	if err == nil {
		return true
	}
	// EPERM means the process exists but is owned by someone else -- still
	// alive, just not ours to signal.
	return errors.Is(err, syscall.EPERM)
}

// AcquireServerLock attempts to become the shared server that owns sockPath.
//
// It first checks whether an existing lock names a still-live PID; if so it
// returns ErrAlreadyRunning without writing anything. Otherwise (no lock, or
// the lock names a dead PID) it stages a record and publishes it with
// os.Link, which fails atomically if another contender's record already
// occupies the path -- exactly one of any set of racing callers observes a
// nil error. A caller that loses the race re-reads whatever record won: a
// live PID means ErrAlreadyRunning; a still-dead one (a rarer double race
// against a different vacating contender) is retried up to acquireRetries
// times before giving up with an error.
func AcquireServerLock(lockPath, sockPath string) error {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o700); err != nil {
		return fmt.Errorf("cannot create state dir for %s: %w", lockPath, err)
	}

	for attempt := 0; attempt < acquireRetries; attempt++ {
		if rec, err := ReadRecord(lockPath); err == nil && rec != nil {
			if PidAlive(rec.PID) {
				return ErrAlreadyRunning
			}
			// Stale: best-effort reclaim. If another contender wins the
			// race below, we detect that from the Link outcome, not from
			// this removal succeeding or failing.
			_ = os.Remove(lockPath)
		}

		stagingFile, err := os.CreateTemp(filepath.Dir(lockPath), filepath.Base(lockPath)+".tmp.*")
		if err != nil {
			return fmt.Errorf("cannot stage lock in %s: %w", filepath.Dir(lockPath), err)
		}
		staging := stagingFile.Name()
		data := fmt.Sprintf("pid=%d\nsocket=%s\n", os.Getpid(), sockPath)
		_, writeErr := stagingFile.WriteString(data)
		closeErr := stagingFile.Close()
		if writeErr != nil || closeErr != nil {
			_ = os.Remove(staging)
			return fmt.Errorf("cannot stage lock %s: write=%v close=%v", staging, writeErr, closeErr)
		}
		if err := os.Chmod(staging, 0o600); err != nil {
			_ = os.Remove(staging)
			return fmt.Errorf("cannot chmod staged lock %s: %w", staging, err)
		}

		linkErr := os.Link(staging, lockPath)
		_ = os.Remove(staging)

		if linkErr == nil {
			return nil
		}
		if !os.IsExist(linkErr) {
			return fmt.Errorf("cannot create lock %s: %w", lockPath, linkErr)
		}

		// Lost the race: read whoever won.
		if rec, err := ReadRecord(lockPath); err == nil && rec != nil && PidAlive(rec.PID) {
			return ErrAlreadyRunning
		}
		// The winner's record is itself already stale (a different, now-dead
		// contender). Loop and try to reclaim it.
	}

	return fmt.Errorf("could not acquire shared server lock after %d attempts: %s", acquireRetries, lockPath)
}
