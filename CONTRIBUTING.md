# Contributing to Sergeant

## Overview

Sergeant is a shell-script-first agent distro. The primary language is Bash;
the Go component (`cmd/sergeant-mcp/`) is the MCP server only. There is no
build step for the shell toolbelt — the scripts run directly from `bin/`.

---

## Prerequisites

| Tool | Required for | Install |
|---|---|---|
| Bash 3.2+ | all shell scripts | system or `brew install bash` |
| Git | everything | system |
| Go 1.21+ | `cmd/sergeant-mcp/` only | <https://go.dev/dl/> |
| Docker | drain test suite | <https://docs.docker.com/get-docker/> |
| `mise` | tasks (`install`, `check`, `build`, `test:docker:drain`) | `brew install mise` or <https://mise.jdx.dev> |
| `yq` | Sergeant runtime + dispatch tests | `brew install yq` |
| `gh` | GitHub CLI tests | `brew install gh` |

Everything else listed in [Requirements](README.md#requirements) is a runtime
dependency, not a build dependency. You can develop and run most tests without
OpenCode, Treehouse, or Graphify installed.

---

## Clone and set up

```bash
git clone https://github.com/callmeradical/sergeant.git
cd sergeant

# Symlink sgt-* commands into ~/.local/bin and install the pre-push hook
mise run install

# Verify required runtime dependencies
mise run check
```

`mise run install` does two things:
1. Creates symlinks for every `bin/sgt-*` and `bin/_sgt-*.sh` script in
   `~/.local/bin` (override with `SGT_INSTALL_DIR`).
2. Installs `scripts/hooks/pre-push` as `.git/hooks/pre-push` so the Docker
   drain suite runs before every push.

---

## Build the MCP server

The shell scripts need no build step. The Go MCP server (a shared backend
process, `sergeant-mcp`) and its per-instance client proxy
(`sergeant-mcp-client`, what `mcp.json` actually registers) are optional:

```bash
# Current OS/arch → bin/sergeant-mcp, bin/sergeant-mcp-client
mise run build

# Without mise
go build -o bin/sergeant-mcp ./cmd/sergeant-mcp/
go build -o bin/sergeant-mcp-client ./cmd/sergeant-mcp-client/

# All platforms → dist/{sergeant-mcp,sergeant-mcp-client}-{os}-{arch}
mise run build:all

# Verify
./bin/sergeant-mcp --version
./bin/sergeant-mcp-client --version
```

Both binaries must stay in `bin/` alongside the `sgt-*` scripts — the server
resolves script paths relative to itself, and the client looks for a sibling
`sergeant-mcp` binary to start when no shared server is already running.

---

## Run the tests

### Drain suite (Docker-isolated — required before every push)

The pre-push hook runs this automatically. To run it manually:

```bash
# Both passes: Debian system Bash + Alpine Bash 3.2
mise run test:docker:drain

# Skip in an emergency
git push --no-verify
```

The suite builds a local `sergeant-test` Docker image from `Dockerfile.test`,
mounts the repo read-only, and runs `tests/run-drain-tests.sh`. No host state
is touched.

### Individual test files

Most tests under `tests/` are pure Bash and can run directly:

```bash
bash tests/sgt-drain-test.sh
bash tests/sgt-wake-test.sh
bash tests/sgt-watch-snapshot-test.sh
# … etc.
```

Tests that require a real tmux server, OpenCode, or cross-filesystem setup
are listed in `AUDIT_ALLOWED_FAILURES` inside
`tests/global-state-isolation-test.sh` with a recorded reason.

### Global state isolation audit (Docker, optional)

Proves no test suite can write to real Sergeant state (`~/.config/sergeant/`):

```bash
docker build -q -f Dockerfile.test -t sergeant-test .
docker run --rm -v "$PWD:/repo:ro" -e "SGT_ISOLATION_DYNAMIC=1" sergeant-test \
  bash /repo/tests/global-state-isolation-test.sh
```

### Go tests

```bash
go test ./...
```

### CI

`.github/workflows/build.yml` runs `go build` + `go test ./...` on every PR
against Ubuntu and macOS. The Bash test suite is **not** in CI — run it locally
with `mise run test:docker:drain` before pushing.

---

## Code structure

```
bin/              Shell scripts — the Sergeant toolbelt
  sgt-*           Public commands (sgt-dispatch, sgt-watch, …)
  _sgt-*.sh       Shared library helpers sourced by the public scripts
  _sgt-*.py       Python helpers (response-lock, verify-owned-fd, …)
cmd/sergeant-mcp/ Go MCP server
  main.go         Registers all sgt-* scripts as MCP tools
docs/             Documentation
schema/           Project YAML schema + annotated example
scripts/hooks/    Git hooks installed by mise run install
skills/           Sergeant coordinator skills
tests/            Bash test suites (one file per feature area)
.agents/skills/   Worker skills (auto-discovered by agent harnesses)
```

---

## Style rules

### Shell scripts

- Target Bash 3.2 compatibility throughout (macOS ships 3.2). No `declare -A`,
  no `[[ =~ ]]` with inline patterns on the right-hand side, no `{1..n}`
  brace expansion in array contexts.
- Every function that reads or writes Sergeant state must accept
  `SERGEANT_DRAIN_DIR`, `SERGEANT_CONFIG`, and `SERGEANT_FLEET` overrides so
  tests can isolate to temp directories.
- New test files that touch drain or fleet state must export those three
  variables to temp dirs and clean up with a `trap … EXIT`.
- Run `shellcheck bin/your-script` before committing (informational SC1091
  notices from dynamic sources are expected and acceptable).

### Go

- `go build ./...` and `go test ./...` must pass.
- `CGO_ENABLED=0` for the MCP server binary (static, no libc dependency).

### Commits and PRs

- One logical change per commit; squash-merge on the PR.
- Commit message: `<type>(<scope>): <summary>` following the patterns already
  in `git log --oneline`.
- Every PR that changes observable behavior needs a test. New test files must
  pass the isolation audit (`global-state-isolation-test.sh`).
- Independent review is required before merge for any change to the dispatch,
  worker, cleanup, or response-lock paths.

---

## Release process

Releases use date-based tags: `0.DDMMYYYY` (`.N` suffix for patches).

```bash
# Tag from origin/main
git tag 0.DDMMYYYY origin/main
git push origin 0.DDMMYYYY --no-verify

# Create the GitHub release with changelog
gh release create 0.DDMMYYYY --title "0.DDMMYYYY" --notes "…"
```

`.github/workflows/release.yml` triggers on `0.*` tags and runs GoReleaser,
attaching pre-built `sergeant-mcp` binaries (`darwin/linux × amd64/arm64`) to
the release automatically.

The pre-push hook requires `--no-verify` for tag pushes because the hook runs
the full Docker drain suite, which takes ~2 minutes and is already verified on
the source commits.

---

## Getting help

- Open an issue for bugs or feature requests.
- Use `docs/troubleshooting.md` for common operational problems.
- The `sergeant-help` skill answers questions about Sergeant's own internals
  from within an agent session.
