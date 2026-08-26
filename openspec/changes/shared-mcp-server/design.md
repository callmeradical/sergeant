# Design — Shared MCP Server Process

## Ownership

One repository, `sergeant` (v1). `cmd/sergeant-mcp/main.go` (becomes the
shared backend), new `cmd/sergeant-mcp-client/main.go` (thin proxy),
`mcp.json`, `bin/sgt-recover`, `bin/sgt-dispatch`.

## Server: `cmd/sergeant-mcp` becomes a Unix-socket Streamable HTTP backend

`main()` keeps building the exact same `*server.MCPServer` and the exact
same `tools` registration loop it has today (`main.go:344-375`) — no tool
behavior changes. What changes is the transport at the very end:

```go
lockPath := filepath.Join(sergeantStateDir(), "mcp-server.lock")
sockPath := filepath.Join(sergeantStateDir(), "mcp-server.sock")

if err := acquireServerLock(lockPath, sockPath); err != nil {
    // another live server already holds it; nothing to do (see client design)
    fmt.Fprintf(os.Stderr, "sergeant-mcp: shared server already running: %v\n", err)
    os.Exit(0)
}
defer os.Remove(sockPath)

os.Remove(sockPath) // clear a stale socket file from a prior unclean exit
listener, err := net.Listen("unix", sockPath)
if err != nil { ... }
os.Chmod(sockPath, 0600) // owner-only, matching this codebase's owned-file convention

execSemaphore := make(chan struct{}, runtime.NumCPU())
// runScript acquires/releases execSemaphore around cmd.Run() (see below)

httpServer := server.NewStreamableHTTPServer(s,
    server.WithStreamableHTTPServer(&http.Server{Handler: ...}),
)
httpServer.Serve(listener) // net/http's Serve over a Unix listener
```

`sergeantStateDir()` is a new small helper returning
`$HOME/.local/share/sergeant` (mirroring `bin/_sgt-lib.sh`'s own
`FLEET_DIR`/`SERGEANT_FLEET` default root, so the Go and bash sides agree
on one state root without introducing a second config concept).

`acquireServerLock` writes `pid=<pid>\nsocket=<sockPath>\n` to a `.tmp.<pid>`
file then `os.Rename`s it into place (the same staged-write-then-atomic-
rename shape `_sgt_replace_owned_file` already uses in the bash side,
`bin/_sgt-lib.sh:1165`) — but only after first checking whether an existing
lock names a still-live PID (via `syscall.Kill(pid, 0)`, the standard Unix
"is this PID alive" probe with no signal actually delivered) and, if so,
returning an error instead of overwriting it. A startup race between two
processes both finding no live lock is resolved the same way `_sgt-drain.sh`
resolves its own lock race today: `os.Link` (hardlink, atomic,
fails if the target exists) rather than `os.Rename` (which would silently
clobber a lock another process just won), so exactly one of the two racing
writers succeeds in creating the real lock path; the loser detects the
now-live PID and exits as a no-op server start (its would-be socket is
never bound).

## Execution concurrency bound

`runScript` (`main.go:78`) gains a bounded acquire/release around the
existing `cmd.Run()` call:

```go
execSemaphore <- struct{}{}
defer func() { <-execSemaphore }()
```

This bounds concurrent script execution to `runtime.NumCPU()` regardless of
how many clients are connected — the PRD's settled decision that
connection count itself needs no cap, only execution concurrency does.

## Client: new `cmd/sergeant-mcp-client`

This is what `mcp.json` now names as `"command"`. On startup:

1. Read the lock file. If it names a PID that responds live to
   `syscall.Kill(pid, 0)`, connect to the recorded socket.
2. If not (absent, stale, or the socket connect fails), exec the server
   binary (`sergeant-mcp --serve`) as a detached background process, poll
   briefly for the socket to appear, then connect. (This reuses
   `acquireServerLock`'s own race resolution — a second client racing to
   start at the same moment simply fails its own lock-hardlink attempt and
   falls back to connecting to whichever one won.)
3. Once connected, proxy every stdin JSON-RPC frame this harness instance
   sends to the Unix socket, and every response back to stdout — the
   harness on the other end of `stdio` sees no difference from talking to
   today's full server directly.
4. If the socket connection breaks after step 3, buffer subsequent
   incoming stdin frames in memory (bounded, e.g. 64 requests — an
   overflow is a hard failure back to the harness, not silent data loss),
   repeat steps 1-2 to reconnect, then flush the buffer against the new
   connection in original order before resuming normal proxying.

## `mcp.json`

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
  "mcpServers": {
    "sergeant": {
      "type": "stdio",
      "command": "./bin/sergeant-mcp-client"
    }
  }
}
```

`"type"` stays `"stdio"` — every harness's own MCP client keeps working
exactly as it does today, since the shared backend is an implementation
detail behind the new client binary, not something every harness's MCP
client library needs to natively understand a new transport type for.
The visible client-side change is `"command"` naming a different,
new binary, not a silent behavior change under the same binary name.

## Closing the two confirmed environment gaps

**`bin/sgt-recover`**: add a `--model <tuple>` flag (same argument-parsing
shape as `bin/sgt-session-resume`'s existing `--model`, `bin/sgt-session-
resume:54-56`), inserted into the precedence chain this change's own
`#29` fix already established (`bin/sgt-recover:343` area):

```
flag > SERGEANT_MODEL env > durable fleet record > unpinned
```

(today it is `env > fleet record > unpinned`; the flag becomes the new
first tier, exactly mirroring `sgt-session-resume`'s `MODEL_OVERRIDE`).

**`bin/sgt-dispatch`**: add a `--tmux-session <name>` flag, parsed
alongside the existing `--model`/`--branch`-style flags
(`bin/sgt-dispatch:372` area), and change the existing resolution at
`bin/sgt-dispatch:691`:

```
SGT_TMUX_SESSION="${TMUX_SESSION_OVERRIDE:-${SERGEANT_TMUX_SESSION:-sgt}}"
```

**`cmd/sergeant-mcp/main.go`**: update the `argsDesc` strings for the
`sgt-recover` and `sgt-dispatch` tool definitions to document the new
flags, the same way `--model` is already documented for
`sgt-dispatch`/`sgt-session-resume` (`main.go:132`, `main.go:332`).

No new MCP tool parameter, no change to `runScript`'s signature, and no
special-casing in the server for these two variables — they become
ordinary CLI flags an MCP caller passes through the existing free-text
`args` string, exactly like every other flag these tools already support.

## Rejected alternatives

**Every harness's `mcp.json` speaking Streamable HTTP directly
(`"type": "http"`).** Rejected: this would require confirming every
target harness's own MCP client actually supports an HTTP-shaped server
config, which is not verified for every harness this plugin targets. The
stdio-proxy-to-Unix-socket design keeps `"type": "stdio"` for every
harness unchanged, so no harness-side transport-support assumption is
required.

**TCP loopback instead of a Unix domain socket.** Rejected in favor of a
Unix socket: this codebase's existing trust model is filesystem-permission
based (owned files, `0600`, `_sgt_read_owned_file`-style checks)
everywhere else, not network-loopback-based. A Unix socket with owner-only
permissions is a more consistent fit than adding a second, network-shaped
trust boundary (DNS-rebinding protection, port allocation) purely for a
single-machine, single-user scenario.

**A generic new MCP tool parameter (e.g. `env_overrides`) for passing
arbitrary per-call environment.** Rejected: only two variables were
confirmed by direct audit to actually need this; a generic escape hatch
would reintroduce exactly the kind of implicit, easy-to-misuse channel
this change exists to close. Adding an explicit flag per confirmed case
keeps the fix scoped to what was actually found.
