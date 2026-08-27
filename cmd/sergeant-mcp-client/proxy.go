package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync"
	"time"
)

// bufferLimit bounds how many undelivered stdin frames a proxy holds in
// memory while the shared server is unreachable. An overflow is a hard
// failure back to the harness (a synthesized JSON-RPC error for whichever
// request the overflow evicted), not silent data loss.
const bufferLimit = 64

// reconnectBackoff is the pause between a failed reconnect attempt and the
// next retry, so a genuinely stuck shared server does not spin the CPU.
const reconnectBackoff = 200 * time.Millisecond

// response is the minimal shape of an HTTP response this proxy relays back
// to the harness over stdout.
type response struct {
	status      int
	contentType string
	body        []byte
}

// proxy is the client half of the shared-mcp-server design: it discovers or
// starts one shared sergeant-mcp server process, then forwards stdio
// JSON-RPC frames to it over a Unix socket and relays responses back.
//
// A single sendLoop goroutine delivers buffered lines strictly in FIFO
// order; this proxy never runs two tool calls concurrently against the
// backend on behalf of one harness instance. That matches how these
// harnesses actually call MCP tools today (await one call before issuing the
// next) and makes the bounded-buffer-and-replay-in-order behavior simple to
// reason about and to test.
type proxy struct {
	stateDir string
	lockPath string

	mu       sync.Mutex
	sockPath string
	client   *http.Client
	buffer   []string
	closed   bool
	cond     *sync.Cond

	stdout io.Writer
	outMu  sync.Mutex

	// send and reconnect are overridden by tests to avoid real networking;
	// production code leaves them as the zero value and newProxy wires the
	// real implementations below.
	send      func(line string) (*response, error)
	reconnect func() bool
}

func newProxy(stateDir, lockPath, sockPath string) *proxy {
	p := &proxy{
		stateDir: stateDir,
		lockPath: lockPath,
		sockPath: sockPath,
	}
	p.cond = sync.NewCond(&p.mu)
	p.send = p.sendOverSocket
	p.reconnect = p.reconnectToSharedServer
	return p
}

// run reads newline-delimited JSON-RPC frames from stdin, enqueueing each
// one, until stdin closes (the harness is shutting this client down).
func (p *proxy) run(stdin io.Reader) {
	done := make(chan struct{})
	go func() { p.sendLoop(); close(done) }()

	reader := bufio.NewReaderSize(stdin, 1<<20)
	for {
		line, err := reader.ReadString('\n')
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			p.enqueue(trimmed)
		}
		if err != nil {
			break
		}
	}
	// stdin closed (the harness is shutting this client down): stop
	// accepting new work, but do not exit until every already-enqueued line
	// has actually been delivered -- otherwise a call sent right before
	// shutdown could be silently dropped instead of answered.
	p.closeForTest()
	<-done
}

// enqueue appends line to the pending buffer, evicting and hard-failing the
// oldest pending line if the bound is exceeded.
func (p *proxy) enqueue(line string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return
	}
	if len(p.buffer) >= bufferLimit {
		overflowed := p.buffer[0]
		p.buffer = p.buffer[1:]
		go p.respondOverflow(overflowed)
	}
	p.buffer = append(p.buffer, line)
	p.cond.Signal()
}

// closeForTest lets tests (and run, on stdin EOF) stop sendLoop deterministically.
func (p *proxy) closeForTest() {
	p.mu.Lock()
	p.closed = true
	p.cond.Broadcast()
	p.mu.Unlock()
}

// sendLoop delivers buffer[0] repeatedly -- reconnecting and retrying the
// same line on failure -- until it succeeds, then advances to the next
// line. It never drops a line short of the enqueue-time overflow eviction.
func (p *proxy) sendLoop() {
	for {
		p.mu.Lock()
		for len(p.buffer) == 0 && !p.closed {
			p.cond.Wait()
		}
		if len(p.buffer) == 0 && p.closed {
			p.mu.Unlock()
			return
		}
		line := p.buffer[0]
		p.mu.Unlock()

		resp, err := p.send(line)
		if err != nil {
			if !p.reconnect() {
				time.Sleep(reconnectBackoff)
			}
			continue
		}

		p.mu.Lock()
		// buffer[0] no longer being `line` means enqueue's overflow eviction
		// already hard-failed this exact still-in-flight line while send was
		// blocked. That caller already has its (synthesized error) response;
		// writing this late success too would answer the same id twice.
		stillOwed := len(p.buffer) > 0 && p.buffer[0] == line
		if stillOwed {
			p.buffer = p.buffer[1:]
		}
		p.mu.Unlock()
		if stillOwed {
			p.writeResponse(resp)
		}
	}
}

// writeResponse relays one backend response to stdout as zero or one
// newline-delimited JSON-RPC frames: a 202/empty body (notification ack) is
// silently swallowed, a JSON body is written as-is, and an SSE body has each
// of its data: events written as its own line.
func (p *proxy) writeResponse(resp *response) {
	if resp == nil {
		return
	}
	trimmedBody := bytes.TrimSpace(resp.body)
	if len(trimmedBody) == 0 {
		return
	}

	mediaType, _, _ := mime.ParseMediaType(resp.contentType)
	p.outMu.Lock()
	defer p.outMu.Unlock()
	if mediaType == "text/event-stream" {
		for _, data := range parseSSEData(resp.body) {
			fmt.Fprintf(p.stdout, "%s\n", data)
		}
		return
	}
	fmt.Fprintf(p.stdout, "%s\n", trimmedBody)
}

// respondOverflow hard-fails a request evicted by a full buffer: a request
// (has an id) gets a synthesized JSON-RPC error so the harness's own call
// resolves instead of hanging forever. A notification (no id) has no
// response slot in JSON-RPC to fail into, so it is dropped -- the same
// outcome a real one-way notification would have if it were simply late.
func (p *proxy) respondOverflow(line string) {
	id, ok := extractJSONRPCID(line)
	if !ok {
		return
	}
	p.outMu.Lock()
	defer p.outMu.Unlock()
	fmt.Fprintf(p.stdout,
		`{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"sergeant-mcp-client buffer overflow: shared server unreachable"}}`+"\n",
		string(id))
}
