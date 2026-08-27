package main

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer guards a bytes.Buffer so tests can read it (via String/Len)
// concurrently with the proxy's own outMu-guarded writes -- the proxy writes
// via io.Writer (Write), and a plain bytes.Buffer read from the test
// goroutine while that happens is a real data race, distinct from anything
// proxy.go itself does under its own lock.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *syncBuffer) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Len()
}

// waitFor polls cond every 5ms until it is true or the deadline passes,
// returning whether it became true in time.
func waitFor(t *testing.T, deadline time.Duration, cond func() bool) bool {
	t.Helper()
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if cond() {
			return true
		}
		time.Sleep(5 * time.Millisecond)
	}
	return cond()
}

func TestProxyDeliversLinesInOrder(t *testing.T) {
	var mu sync.Mutex
	var delivered []string

	var out syncBuffer
	p := newProxy("", "", "")
	p.stdout = &out
	p.send = func(line string) (*response, error) {
		mu.Lock()
		delivered = append(delivered, line)
		mu.Unlock()
		return &response{status: 200, contentType: "application/json", body: []byte(fmt.Sprintf(`{"echo":%q}`, line))}, nil
	}

	go p.sendLoop()
	defer p.closeForTest()

	for i := 0; i < 5; i++ {
		p.enqueue(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"x"}`, i))
	}

	ok := waitFor(t, 2*time.Second, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(delivered) == 5
	})
	if !ok {
		t.Fatalf("timed out waiting for delivery, got %v", delivered)
	}
	for i, line := range delivered {
		want := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"x"}`, i)
		if line != want {
			t.Errorf("delivered[%d] = %q, want %q (order not preserved)", i, line, want)
		}
	}
}

func TestProxyRetriesAfterSendFailureUntilReconnect(t *testing.T) {
	var mu sync.Mutex
	attempts := 0
	reconnected := false

	var out syncBuffer
	p := newProxy("", "", "")
	p.stdout = &out
	p.send = func(line string) (*response, error) {
		mu.Lock()
		defer mu.Unlock()
		attempts++
		if !reconnected {
			return nil, errors.New("connection refused")
		}
		return &response{status: 200, contentType: "application/json", body: []byte(`{"ok":true}`)}, nil
	}
	p.reconnect = func() bool {
		mu.Lock()
		defer mu.Unlock()
		reconnected = true
		return true
	}

	go p.sendLoop()
	defer p.closeForTest()

	p.enqueue(`{"jsonrpc":"2.0","id":1,"method":"x"}`)

	ok := waitFor(t, 2*time.Second, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return reconnected && attempts >= 2
	})
	if !ok {
		t.Fatalf("call was not retried after reconnect (attempts=%d, reconnected=%v)", attempts, reconnected)
	}
	if !waitFor(t, time.Second, func() bool { return out.Len() > 0 }) {
		t.Fatal("no response was ever written to stdout after the retried call succeeded")
	}
	if got := strings.TrimSpace(out.String()); got != `{"ok":true}` {
		t.Fatalf("stdout = %q, want %q", got, `{"ok":true}`)
	}
}

func TestProxyOverflowRespondsWithErrorForRequestsWithID(t *testing.T) {
	var out syncBuffer
	p := newProxy("", "", "")
	p.stdout = &out
	blocked := make(chan struct{})
	p.send = func(line string) (*response, error) {
		<-blocked // never returns until the test releases it
		return &response{status: 200}, nil
	}

	go p.sendLoop()
	defer func() { close(blocked); p.closeForTest() }()

	// Fill the buffer well past its bound; sendLoop is stuck on the first
	// line, so every one of these accumulates.
	for i := 0; i < bufferLimit+5; i++ {
		p.enqueue(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"x"}`, i))
	}

	ok := waitFor(t, 2*time.Second, func() bool {
		return strings.Contains(out.String(), `"id":0`)
	})
	if !ok {
		t.Fatalf("expected an overflow error response for the evicted id=0 request, got: %s", out.String())
	}
	if !strings.Contains(out.String(), `"error"`) {
		t.Fatalf("overflow response missing a JSON-RPC error field: %s", out.String())
	}
}

// TestProxyOverflowDoesNotAlsoDeliverALateSuccessForTheSameID reproduces a
// race the readiness review caught: sendLoop reads buffer[0] into a local
// `line`, releases the lock, and only sends -- it does not remove `line`
// from the buffer until send() returns. If enqueue's overflow eviction
// evicts and hard-fails that exact still-in-flight line in the meantime, and
// the blocked send() later succeeds anyway, sendLoop must not also write
// that late success response: the caller already got the synthesized
// overflow error for that id and must not see a second, contradictory
// response for the same id.
func TestProxyOverflowDoesNotAlsoDeliverALateSuccessForTheSameID(t *testing.T) {
	var out syncBuffer
	p := newProxy("", "", "")
	p.stdout = &out

	inFlight := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once

	p.send = func(line string) (*response, error) {
		if strings.Contains(line, `"id":0,`) {
			once.Do(func() { close(inFlight) })
			<-release
			return &response{
				status:      200,
				contentType: "application/json",
				body:        []byte(`{"jsonrpc":"2.0","id":0,"result":{"late":true}}`),
			}, nil
		}
		return &response{status: 200, contentType: "application/json", body: []byte(`{"ok":true}`)}, nil
	}

	go p.sendLoop()
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
		p.closeForTest()
	}()

	p.enqueue(`{"jsonrpc":"2.0","id":0,"method":"x"}`)
	select {
	case <-inFlight:
	case <-time.After(2 * time.Second):
		t.Fatal("send for id=0 never started")
	}

	// id=0's send is now blocked mid-flight, and it is still buffer[0].
	// Overflow the buffer so enqueue evicts and hard-fails exactly that line.
	for i := 1; i <= bufferLimit; i++ {
		p.enqueue(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":"x"}`, i))
	}

	if !waitFor(t, 2*time.Second, func() bool { return strings.Contains(out.String(), `"id":0,"error"`) }) {
		t.Fatalf("expected the overflow error response for id=0, got: %s", out.String())
	}

	// Now let the in-flight send for id=0 finally succeed.
	close(release)

	// Give sendLoop time to (incorrectly, if the bug is present) also write
	// a second, late response for id=0.
	time.Sleep(300 * time.Millisecond)

	if count := strings.Count(out.String(), `"id":0,`); count != 1 {
		t.Fatalf("id=0 appears in %d responses, want exactly 1 (a late success must not follow the overflow error for the same id): %s",
			count, out.String())
	}
}

func TestProxyOverflowDropsNotificationsSilently(t *testing.T) {
	var out syncBuffer
	p := newProxy("", "", "")
	p.stdout = &out
	blocked := make(chan struct{})
	p.send = func(line string) (*response, error) {
		<-blocked
		return &response{status: 200}, nil
	}

	go p.sendLoop()
	defer func() { close(blocked); p.closeForTest() }()

	for i := 0; i < bufferLimit+5; i++ {
		p.enqueue(`{"jsonrpc":"2.0","method":"notifications/progress"}`)
	}

	time.Sleep(100 * time.Millisecond)
	if out.Len() != 0 {
		t.Fatalf("overflowed notifications should produce no output, got: %s", out.String())
	}
}
