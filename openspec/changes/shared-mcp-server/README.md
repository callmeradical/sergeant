Multiple interactive-agent instances on one machine share one running
`sergeant-mcp` server process instead of each spawning a private one (31
observed on one machine, all redundant — the server holds no meaningful
per-process state) — via a thin per-instance client that discovers or
starts the shared backend over a Unix socket, with `sgt-recover` and
`sgt-dispatch` gaining explicit flags so per-invocation policy no longer
depends on inherited environment.
