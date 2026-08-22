package naming

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"sync/atomic"
	"time"
)

// runIDCounter guarantees uniqueness within one process. crypto/rand alone makes
// a collision unlikely; a counter makes it impossible for the case that actually
// occurs, which is one server handling two dispatches in the same second.
var runIDCounter uint32

// RunID is a run's identity. It names the run row, the git branch
// (sergeant/<id>) and the worktree directory, so it must be unique and must hold
// nothing that needs quoting in a shell, a path or a git refname.
//
// The form is sgt-<unix seconds>-<hex>. The epoch is kept because it lets an
// operator read roughly when a run started straight off the id. The suffix is
// what the previous format lacked: fmt.Sprintf("sgt-%d", time.Now().Unix()) gave
// two dispatches in the same second the same id, so the second collided on the
// runs primary key and looked deduplicated when nothing had deduplicated it.
// Deliberate deduplication is the caller's request_id; an id only has to be
// unique.
//
// A run id is not a speech label. Use Slug for anything an operator has to read
// aloud.
func RunID() string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Randomness is a defence against two processes sharing a second, not the
		// source of uniqueness within one. Falling back to the nanosecond clock
		// keeps dispatch working rather than failing on an unavailable entropy
		// pool, and the counter below still separates same-process calls.
		binary.BigEndian.PutUint32(b[:], uint32(time.Now().UnixNano()))
	}
	seq := atomic.AddUint32(&runIDCounter, 1)
	return fmt.Sprintf("sgt-%d-%s%x", time.Now().Unix(), hex.EncodeToString(b[:]), seq)
}
