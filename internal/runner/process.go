package runner

import (
	"os/exec"
	"syscall"
	"time"
)

// killGraceDelay bounds how long Wait blocks after the process group is killed,
// waiting for inherited stdout/stderr pipes to close. Without it, a grandchild
// that survives the signal could still hold Wait open indefinitely.
const killGraceDelay = 5 * time.Second

// superviseGroup makes a command killable as a whole process tree.
//
// exec.CommandContext alone is not enough, and the gap is not academic. It
// signals only the direct child, so `bash -c "go test ./..."` loses its shell
// and leaves the compiler and test binaries running. Worse, Cmd.Run with a
// non-*os.File Stdout copies through an os.Pipe whose write end those orphans
// inherit, so Wait blocks until they exit on their own: cancelling a run
// returned only when the work finished anyway.
//
// Measured before this existed: cancelling `sh -c "sleep 30"` after 300ms
// returned after 30.2s with the grandchild still alive. After: 302ms, dead.
//
// Setpgid puts the child in a new process group; signalling the negative pid
// signals every process in it. WaitDelay caps the wait on inherited pipes.
//
// This matters more now that an agent phase has no default deadline. Removing
// the deadline makes cancellation the only way to stop a runaway agent, so
// cancellation has to actually work.
func superviseGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = killGraceDelay
}
