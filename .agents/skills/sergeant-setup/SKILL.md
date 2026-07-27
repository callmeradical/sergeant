---
name: sergeant-setup
description: Interactively and idempotently bootstrap a new Sergeant installation or diagnose and repair an existing one. Triggers on "set up Sergeant", "install Sergeant", "configure Sergeant", "repair Sergeant", or similar setup and onboarding requests.
---

# Sergeant Setup

Bootstrap or repair a Sergeant installation interactively and idempotently.
Orchestrate only supported Sergeant and bootstrap commands. Surface missing
capabilities as separate td issues; do not substitute undocumented workarounds.

## When to use

Load this skill when the user wants to:
- Install and configure Sergeant for the first time on a machine.
- Register a new project or add repositories to an existing one.
- Diagnose and repair a broken or incomplete Sergeant installation.
- Verify that an existing setup is working correctly.

Do not load it when the user wants documentation only; use `sergeant-help` instead.
Do not load it when the user is asking about a specific command; use `sergeant-help` instead.

## Safety constraints

This skill writes only to Sergeant-owned paths:

- `~/.config/sergeant/config.yaml` — global Sergeant config
- `~/.config/sergeant/<project>.yaml` — project YAML files

Never write to:

- `~/.config/opencode/`, `~/.opencode/`, or any `opencode.json` in any repository
- `~/.claude/`, `CLAUDE.md` in any repository, or any `.claude/` directory
- `~/.codex/`, `~/.config/codex/`, or any Codex configuration path
- `~/.goose/` or any Goose configuration path
- Any repository's `AGENTS.md`, `.github/`, or other agent configuration paths
- Any path outside `~/.config/sergeant/` unless the user explicitly names it

Do not automatically initialize td, Graphify, or Treehouse. Each requires an
explicit confirmation prompt before any command runs. If consent is declined,
leave state unchanged and report what was skipped.

## Checklist maintenance

Maintain a visible, numbered checklist in the terminal output. Before each step,
verify whether it is already complete and skip it without prompting if it is.
After each step completes or is skipped, write a `[ok]` or `[skipped]` status
line. When a phase fails, stop the current run with actionable output identifying
the last completed phase. On the next invocation the checklist starts over from
Phase 1 but skips every phase that already passes verification; this is how
resumability works — not by persisting state between runs, but by re-checking
each phase before acting on it.

## Phase 1: Detect prerequisites

Check each of the following. Classify each as `present`, `installable` (a
supported bootstrap command exists), or `unsupported` (file a td issue):

Required:
- `bash` 3.2 or newer
- `git`
- `gh` (GitHub CLI), authenticated for the user's repositories
- `tmux`
- `yq`
- `lsof`
- `td` (Marcus implementation: verify with `td version` and `td create --help`;
  must support `--description`, `--json`, and `--work-dir`)
- At least one interactive agent: `opencode`, `goose`, or `claude`

Optional (skip, do not fail, if absent):
- `mise` (for `mise run check` and `mise run install`)
- `treehouse` (for worktree pools)
- `graphify` (for project knowledge graphs)
- `no-mistakes` (for shipping validation)
- `node`/`npm` (for external skill installation)

For each `unsupported` prerequisite, show a draft td issue (title, description,
and acceptance criteria) and ask for explicit approval before creating it:

```
td issue for '<tool>':
  Title: Install <tool> <version> as a Sergeant prerequisite
  Description: <tool> is required but has no supported install command.
  Acceptance: <tool> resolves on PATH with version >= <required>.
Create this td issue? [y/N]
```

Create the issue only after the user types `y` or `yes`. If declined, report
the gap in the summary and continue without creating any tracking work.

Do not continue past Phase 1 until all required prerequisites are either present
or the user explicitly accepts the risk of proceeding without them.

For each `installable` prerequisite, show the installation command and ask for
explicit consent before running it:

```
<tool> is not found. Supported install: <command>
Run it? [y/N]
```

Run the command only after the user types `y` or `yes`. Do not run it on any
other response.

## Phase 2: Clone and install command links

If the Sergeant repository is not already cloned:

1. Ask where to place the clone:
   ```
   Where should Sergeant be cloned? [e.g. ~/Dev/sergeant]
   ```
   Wait for the user's answer. Do not proceed to step 2 until a destination is
   provided.

2. Show the exact command that will run and ask for consent:
   ```
   git clone https://github.com/callmeradical/sergeant.git <destination>
   Clone to <destination>? [y/N]
   ```
   Run the command only after the user types `y` or `yes`. Leave the filesystem
   unchanged on any other response.

If `mise` is available, first determine the actual install directory:

```bash
install_dir="${SGT_INSTALL_DIR:-$HOME/.local/bin}"
```

Show the resolved target and ask for consent before running anything:

```
Run `mise run install` to symlink commands into <install_dir>? [y/N]
```

Run `mise run install` only after the user confirms. If `mise` is unavailable or
consent is declined, instruct the user to symlink commands from `bin/` into a
directory on `PATH` manually and verify the result before continuing.

Verify that at least `sgt-list`, `sgt-context`, `sgt-dispatch`, and `sgt-watch`
resolve on `PATH` before proceeding. Report any missing commands and their
expected source path. Stop the current run if verification fails after the user
has followed the install instructions; the next run will re-check Phase 2.

## Phase 3: Global config

Check whether `~/.config/sergeant/config.yaml` exists.

- **Missing**: ask the user for a `dev_root` path, then show a preview and ask
  for confirmation before writing anything:
  ```yaml
  dev_root: <path>
  ```
  ```
  Write ~/.config/sergeant/config.yaml? [y/N]
  ```
  Write the file only after the user confirms. Leave the filesystem unchanged on
  any other response.
- **Present and valid**: verify `dev_root` is set and report `[ok]`.
- **Present and invalid YAML**: validate with `yq e '.' ~/.config/sergeant/config.yaml`
  before showing the file. Report the parse error and stop; do not overwrite
  without a timestamped backup, a diff preview, and explicit confirmation.

## Phase 4: Project YAML interview

If the project YAML file already exists and the user wants to modify it, skip
this phase and go directly to Phase 5 (Repair existing YAML) instead.

Run the interview for new projects only. Ask these questions in order; stop
and wait for each answer before proceeding:

1. **Project name** — becomes the YAML filename stem (e.g., `myproject` →
   `~/.config/sergeant/myproject.yaml`). Must match `[a-z0-9_-]+`.
2. **Repository list** — for each repository:
   - Name (unique within this project)
   - Path on disk (relative to `dev_root` or absolute)
   - Clone URL (for `sgt-sync`)
   - Role (free text: what this repo does)
   - Group membership (optional; name or leave blank)
3. **Groups** — for each named group, a description and any shared
   `agent_instructions`.
4. **Default agent instructions** — applied to every repository.
5. **Project-level `identity`** (GitHub CLI username; optional).
6. **Graphify output path** (optional; omit the field when not wanted).

After all answers are collected, show a preview of the complete YAML before
writing anything:

```
Preview of ~/.config/sergeant/<name>.yaml:
---
<yaml content>
---
Write this file? [y/N]
```

Write the file only after the user confirms. If the file already exists, create
a backup at `~/.config/sergeant/<name>.yaml.bak.<timestamp>` before writing.

## Phase 5: Repair existing YAML

When a project YAML already exists and the user wants to modify it:

1. Validate the existing file with `yq e '.' ~/.config/sergeant/<name>.yaml`.
   If it fails, report the parse error and stop; do not proceed.
2. Compute and display a minimal diff between the current content and the
   proposed changes.
3. Ask for confirmation before any write or backup:
   ```
   Apply these changes? [y/N]
   ```
4. Only after the user confirms: create a timestamped backup at
   `~/.config/sergeant/<name>.yaml.bak.<timestamp>`, then write the new content.

Do not create the backup before confirmation. Do not apply changes if the user
declines. The backup is mandatory when writing; do not skip it even if asked.

## Phase 6: Sync and verification

After the YAML is written, run verification commands in order and report the
result of each:

```bash
sgt-list
sgt-context <project>
sgt-status <project>
sgt-sync <project>
```

Stop and report the first failure with its full output. Do not continue to the
next command until the previous one succeeds.

## Phase 7: Task tracking initialization

For each repository in the project, check whether td is initialized:

```bash
td status --json --work-dir <repo-path>
```

- **Initialized**: report `[ok]` and continue.
- **Not initialized**: show the command and ask for consent before running it:
  ```
  Initialize td in <repo>? [y/N]
  td init --work-dir <repo-path>
  ```
  Run `td init` only after the user confirms. If consent is declined, report
  the gap in the Phase 9 summary as `[skipped]` and continue.

Do not initialize td in any repository that was not registered in the current
project YAML.

## Phase 8: Optional Treehouse initialization

If `treehouse` is present on `PATH`, offer the option:

```
Initialize Treehouse worktree pools for <project>? [y/N]
```

Run `sgt-treehouse-init <project>` only if the user confirms. Skip silently if
the user declines or if `treehouse` is not installed. Do not mark setup
incomplete because Treehouse was skipped.

## Phase 9: Optional Graphify

If `graphify` is present on `PATH` and the project YAML contains a
`graphify.output` field, offer:

```
Run sgt-graphify <project> now? [y/N]
```

Run it only on confirmation. Skip silently on decline. Require both `graph.json`
and `GRAPH_REPORT.md` at the configured output path after a successful run.

## Phase 10: Verify completion checklist

After all phases complete, print a completion summary showing each item as
`[ok]`, `[skipped]`, or `[issue: <td-id>]`:

```
Sergeant setup complete for <project>:
  [ok]      Prerequisites
  [ok]      Commands installed
  [ok]      Global config
  [ok]      Project YAML: <project>
  [ok]      Sync and context verification
  [ok]      Task tracking (td initialized in all repos)
  [skipped] Treehouse (not installed)
  [issue: td-xxx] Graphify (no-mistakes prerequisite missing; see td-xxx)
```

## Idempotency

Re-running this skill after a successful setup must produce the same final
state. Each phase skips steps that already pass verification. No phase destroys
existing working configuration to reach the same end state.

## Failure behavior

| Condition | Required action |
|---|---|
| Required prerequisite missing and not installable | File or suggest a td issue; do not continue past Phase 1 |
| Prerequisite install declined | Report what was skipped; ask whether to continue |
| Consent declined for any write | Leave state unchanged; report what was skipped |
| YAML parse error on existing file | Report the error and stop; do not overwrite |
| Unsupported setup capability needed | File or suggest a td issue; do not invent a workaround |
| `sgt-sync` or `sgt-context` fails | Report full output and stop the current run; the next run re-checks Phase 6 |
| Partial setup on exit | Report last completed step; next run resumes from that point |
