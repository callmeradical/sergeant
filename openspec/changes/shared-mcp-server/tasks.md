# Tasks — Shared MCP Server Process

One repository, `sergeant` (v1). Two tasks: the server/client split is one
coherent unit; the two flag additions are small and independently
verifiable, but land in the same change since the server/client split is
not actually safe to ship without them (see design.md's "Problem").

## Task 1 — split `cmd/sergeant-mcp` into a shared server and a thin client

Depends on: nothing. Read this change's `design.md` in full first, then
read `cmd/sergeant-mcp/main.go` in full (it is one file, ~385 lines),
`bin/_sgt-lib.sh:1165` (`_sgt_replace_owned_file`, the atomic-write
precedent), and `bin/_sgt-drain.sh`'s lock-acquisition
(`_sgt_drain_lock_acquire_fd`) for the hardlink-based race-resolution
precedent this design's `acquireServerLock` mirrors.

- Add `sergeantStateDir()` and `acquireServerLock(lockPath, sockPath
  string) error` to `cmd/sergeant-mcp`, per design.md.
- Change `main()` to serve over a Unix socket via
  `server.NewStreamableHTTPServer` instead of `server.ServeStdio`, gated
  behind acquiring the server lock; exit 0 (not an error) if another live
  server already holds it.
- Add the bounded execution semaphore around `runScript`'s `cmd.Run()`
  call, sized to `runtime.NumCPU()`.
- Create `cmd/sergeant-mcp-client/main.go`: discovery-or-start-then-proxy
  per design.md, including the buffer-and-replay-on-reconnect behavior.
- Update `mcp.json`'s `"command"` to `./bin/sergeant-mcp-client`.
- Update this repository's build step (wherever `bin/sergeant-mcp` is
  currently built — check `AGENTS.md`/existing build scripts) to also
  build `bin/sergeant-mcp-client`.
- Do not change tool behavior, the `tools` slice's descriptions (beyond
  Task 2's two flag additions), or add authentication beyond the
  Unix socket's owner-only file permissions.

Verification: `go build ./... && go vet ./...`, plus new Go tests
exercising: two clients connecting to one server process end-to-end
(spawn the real server binary in a test temp dir, connect two client
instances, confirm both get identical tool results); the lock-file race
(two goroutines calling `acquireServerLock` concurrently against the same
path — exactly one succeeds, the other detects the live PID); one client
disconnecting does not affect a second client's in-flight or subsequent
calls; a call buffered while the server is down is delivered once
reconnected (kill the server mid-call in the test, confirm the client
retries and the caller still gets a result); a burst of concurrent calls
exceeding the execution semaphore's size all eventually complete and no
more than the configured number run `cmd.Run()` simultaneously (assert via
a fake script that records concurrent-invocation count to a file).
Mutation-test the execution semaphore specifically: remove the
acquire/release, confirm the concurrency-limit test now fails, restore.

## Task 2 — explicit flags for the two confirmed per-instance environment variables

Depends on: nothing (independent of Task 1's server/client split, but
required before Task 1 ships since a shared server makes the existing gap
live for every connected instance, not just a theoretical risk).

Read `bin/sgt-session-resume:40-115` (the existing `--model` flag and its
full `flag > env > fleet > unpinned` precedence chain) and
`bin/sgt-recover:319-380` (the `#29` fix's existing `env > fleet > unpinned`
resolution, which this task extends by inserting a flag tier ahead of it)
before writing anything. Also read `bin/sgt-dispatch:370-420` (the existing
flag-parsing loop shape) and `bin/sgt-dispatch:690-692` (today's
`SERGEANT_TMUX_SESSION` resolution).

- Add `--model <tuple>` to `bin/sgt-recover`'s argument parsing (currently
  none — `sgt-recover` takes only `<task-id> <repo>`), and change its
  model-resolution block (added by the `#29` fix) to check the new flag
  first, ahead of `SERGEANT_MODEL`.
- Add `--tmux-session <name>` to `bin/sgt-dispatch`'s argument parsing,
  and change its `SGT_TMUX_SESSION` resolution to check the new flag
  first, ahead of `SERGEANT_TMUX_SESSION`.
- Update `cmd/sergeant-mcp/main.go`'s `argsDesc` for the `sgt-recover` and
  `sgt-dispatch` tool definitions to document the new flags.
- Do not add a new MCP tool parameter, change `runScript`'s signature, or
  touch any other script's flags.

Verification: this repository's shell test suite. Tests must cover every
scenario in `specs/mcp-server/spec.md` that this task closes: `sgt-recover
--model <tuple>` takes precedence over `SERGEANT_MODEL` env (set both to
different valid tuples in the test, assert the flag's value is what gets
used/persisted); `sgt-dispatch --tmux-session <name>` takes precedence
over `SERGEANT_TMUX_SESSION` env, the same way; and a regression check
that omitting the new flag preserves today's exact `env > fleet >
unpinned` (`sgt-recover`) / `env > "sgt" default` (`sgt-dispatch`)
behavior unchanged. Mutation-test the precedence ordering itself (swap
which tier wins, confirm the new test catches it, restore).
