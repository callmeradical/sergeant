package mcplock

import (
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
)

func TestStateDirDefaultsUnderHome(t *testing.T) {
	t.Setenv("SERGEANT_STATE_DIR", "")
	home := t.TempDir()
	t.Setenv("HOME", home)
	got := StateDir()
	want := filepath.Join(home, ".local", "share", "sergeant")
	if got != want {
		t.Fatalf("StateDir() = %q, want %q", got, want)
	}
}

func TestStateDirHonorsOverride(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SERGEANT_STATE_DIR", dir)
	if got := StateDir(); got != dir {
		t.Fatalf("StateDir() = %q, want %q", got, dir)
	}
}

func TestReadRecordAbsentIsNilNil(t *testing.T) {
	dir := t.TempDir()
	rec, err := ReadRecord(filepath.Join(dir, "mcp-server.lock"))
	if err != nil {
		t.Fatalf("ReadRecord() error = %v, want nil", err)
	}
	if rec != nil {
		t.Fatalf("ReadRecord() = %+v, want nil", rec)
	}
}

func TestReadRecordMissingPidIsError(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	if err := os.WriteFile(lockPath, []byte("socket=/tmp/whatever.sock\n"), 0o600); err != nil {
		t.Fatalf("seed lock file: %v", err)
	}
	rec, err := ReadRecord(lockPath)
	if err == nil {
		t.Fatalf("ReadRecord() = %+v, want an error for a lock file with no pid field", rec)
	}
}

func TestReadRecordMalformedPidIsError(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	if err := os.WriteFile(lockPath, []byte("pid=not-a-number\nsocket=/tmp/whatever.sock\n"), 0o600); err != nil {
		t.Fatalf("seed lock file: %v", err)
	}
	rec, err := ReadRecord(lockPath)
	if err == nil {
		t.Fatalf("ReadRecord() = %+v, want an error for a non-numeric pid field", rec)
	}
}

func TestAcquireServerLockFirstCallerWins(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	sockPath := filepath.Join(dir, "mcp-server.sock")

	if err := AcquireServerLock(lockPath, sockPath); err != nil {
		t.Fatalf("AcquireServerLock() error = %v, want nil", err)
	}

	rec, err := ReadRecord(lockPath)
	if err != nil {
		t.Fatalf("ReadRecord() error = %v", err)
	}
	if rec == nil {
		t.Fatal("ReadRecord() = nil, want a record")
	}
	if rec.PID != os.Getpid() {
		t.Errorf("rec.PID = %d, want %d", rec.PID, os.Getpid())
	}
	if rec.Socket != sockPath {
		t.Errorf("rec.Socket = %q, want %q", rec.Socket, sockPath)
	}
}

func TestAcquireServerLockRefusesWhileLive(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	sockPath := filepath.Join(dir, "mcp-server.sock")

	if err := AcquireServerLock(lockPath, sockPath); err != nil {
		t.Fatalf("first AcquireServerLock() error = %v, want nil", err)
	}
	err := AcquireServerLock(lockPath, sockPath+".other")
	if err == nil {
		t.Fatal("second AcquireServerLock() = nil, want ErrAlreadyRunning")
	}
	if err != ErrAlreadyRunning {
		t.Fatalf("second AcquireServerLock() error = %v, want ErrAlreadyRunning", err)
	}
}

func TestAcquireServerLockReclaimsStaleDeadPID(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	sockPath := filepath.Join(dir, "mcp-server.sock")

	// A PID that is essentially guaranteed not to be live: PID 1 belongs to
	// init/launchd and syscall.Kill(1, 0) from an unprivileged test process
	// returns EPERM (treated as "alive, owned by someone else") rather than
	// ESRCH -- so use a PID far outside any plausible live range instead.
	deadPID := 999999
	stale := "pid=" + strconv.Itoa(deadPID) + "\nsocket=" + sockPath + ".stale\n"
	if err := os.WriteFile(lockPath, []byte(stale), 0o600); err != nil {
		t.Fatalf("seed stale lock: %v", err)
	}

	if err := AcquireServerLock(lockPath, sockPath); err != nil {
		t.Fatalf("AcquireServerLock() error = %v, want nil (should reclaim stale lock)", err)
	}
	rec, err := ReadRecord(lockPath)
	if err != nil {
		t.Fatalf("ReadRecord() error = %v", err)
	}
	if rec.PID != os.Getpid() {
		t.Errorf("rec.PID = %d, want %d (own pid after reclaim)", rec.PID, os.Getpid())
	}
}

func TestAcquireServerLockConcurrentRaceHasExactlyOneWinner(t *testing.T) {
	dir := t.TempDir()
	lockPath := filepath.Join(dir, "mcp-server.lock")
	sockPath := filepath.Join(dir, "mcp-server.sock")

	const contenders = 8
	var wg sync.WaitGroup
	results := make([]error, contenders)
	for i := 0; i < contenders; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			results[i] = AcquireServerLock(lockPath, sockPath)
		}(i)
	}
	wg.Wait()

	wins, losses := 0, 0
	for _, err := range results {
		switch {
		case err == nil:
			wins++
		case err == ErrAlreadyRunning:
			losses++
		default:
			t.Fatalf("unexpected AcquireServerLock() error: %v", err)
		}
	}
	if wins != 1 {
		t.Fatalf("wins = %d, want exactly 1 (losses = %d)", wins, losses)
	}
	if losses != contenders-1 {
		t.Fatalf("losses = %d, want %d", losses, contenders-1)
	}
}

func TestPidAliveSelf(t *testing.T) {
	if !PidAlive(os.Getpid()) {
		t.Fatal("PidAlive(os.Getpid()) = false, want true")
	}
}

func TestPidAliveImplausiblePID(t *testing.T) {
	if PidAlive(999999) {
		t.Fatal("PidAlive(999999) = true, want false")
	}
}
