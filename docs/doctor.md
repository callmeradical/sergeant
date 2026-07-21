# sgt-doctor

`sgt-doctor` performs read-only diagnostics on a Sergeant developer
installation. It does not install tools, create configuration, repair links,
update repositories, alter fleet state, or expose credential values.

## Usage

```bash
sgt-doctor                         # all registered projects
sgt-doctor smith                   # one project
sgt-doctor --project smith         # equivalent explicit form
sgt-doctor --project smith --json  # machine-readable output
```

## Results

Every check has a stable identifier and one of three statuses:

- `PASS`: the capability is available and consistent.
- `WARN`: an optional capability is unavailable or state needs attention.
- `FAIL`: a required capability or persisted state is broken.

Exit codes are deterministic:

| Code | Meaning |
|---|---|
| `0` | Healthy: no warnings or failures |
| `1` | Degraded: one or more warnings and no failures |
| `2` | Broken: one or more failures |
| `64` | Invalid command-line arguments |

JSON output has this shape:

```json
{
  "status": "healthy",
  "summary": {"passes": 1, "warnings": 0, "failures": 0},
  "checks": [
    {"id": "tools.git", "status": "pass", "message": "git version 2.x"}
  ]
}
```

## Checks

Diagnostics cover:

- Required tools and versions: `yq`, Git, GitHub CLI, tmux, and Python 3.
- Optional integrations and versions: td, no-mistakes, graphify, treehouse,
  babydriver, and mise.
- Availability of at least one supported OpenCode, Claude Code, or Goose
  agent harness.
- When Goose is selected, dispatch and resume still depend on Goose persisting
  a resumable session record for the current worktree; harness availability
  alone is not sufficient for a waiting worker to resume.
- GitHub authentication identity. Tokens are neither requested nor printed.
- Global and project YAML syntax and required project/repository fields.
- Repository paths, Git metadata, configured URLs, origin remotes, and td data.
- Installed Sergeant command and OpenCode plugin symlink targets.
- Bundled skills and broken links in OpenCode and Claude skill directories.
- Writable configuration, installation, and fleet runtime directories.
- Fleet terminal results, orphaned workers, missing worktrees, dead tmux panes,
  unsynchronized state, and nonterminal state unchanged for over seven days.

Messages redact URL credentials, token/password/secret/API-key assignments, and
GitHub token patterns before human or JSON output is rendered.
