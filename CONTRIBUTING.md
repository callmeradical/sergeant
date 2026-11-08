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

The shell scripts need no build step. The Go MCP server is optional:

```bash
# Current OS/arch → bin/sergeant-mcp
mise run build

# Without mise
go build -o bin/sergeant-mcp ./cmd/sergeant-mcp/

# All platforms → dist/sergeant-mcp-{os}-{arch}
mise run build:all

# Verify
./bin/sergeant-mcp --version
```

The binary must stay in `bin/` alongside the `sgt-*` scripts — it resolves
script paths relative to itself at runtime.

---

## Run the tests

### Drain suite (Docker-isolated — required before every push)

The pre-push hook runs this automatically. To run it manually:

```bash
# Both passes: Debian system Bash + Bash 3.2
mise run test:docker:drain

# Skip in an emergency
git push --no-verify
```

The suite builds two local Docker images, mounts the repo read-only, and runs
`tests/run-drain-tests.sh` in each. No host state is touched.

| Image | Dockerfile | Pass |
|---|---|---|
| `sergeant-test` | `Dockerfile.test` | Debian bookworm-slim, system Bash 5.x |
| `sergeant-test-bash32` | `Dockerfile.bash32` | digest-pinned Bash 3.2 plus git, tmux, yq and python3 |

`mise run test:docker:notification` runs the notification handshake suite the
same way.

### Suite skip policy

`tests/run-drain-tests.sh` and `tests/run-notification-tests.sh` share
`tests/lib/suite-policy.sh`, which enforces three rules:

- **`git`, `tmux`, `yq` and `python3` are prerequisites.** A missing tool fails
  the run in preflight; it never downgrades a case to a skip.
- **A skip needs an allowlisted reason code.** The only one today is
  `bash32-pass-not-selected`, for the container that deliberately runs the
  system-Bash pass only (`BASH32=""`). Any other skip counts as a failure.
- **A run that executed no case is never a success**, however many cases it
  skipped.

Before this policy the Bash 3.2 notification pass reported "0 passed, 0 failed,
9 skipped" as a green tick on the pre-push gate, because the bare `bash:3.2`
image had none of those four tools (td-5ab019).

Set `BASH32` to a real Bash 3.2 to run the Bash 3.2 pass on the host
(`BASH32=/bin/bash` on macOS), or `BASH32=""` to run the system-Bash pass only.
An unset `BASH32` defaults to `/usr/local/bin/bash32` and fails the run if
nothing is there — a wrong path used to skip the whole pass silently.

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
