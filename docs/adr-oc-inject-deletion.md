# ADR: Delete oc-inject prototype (August 2026)

**Status:** Decided — executed in PR #190 (GH #179)

## Context

`bin/oc-inject` has carried the comment `# DELETE when prototype question is answered.`
since it was first written. By August 2026 it had grown to 105 lines of polling logic
that watched `~/.local/share/opencode/inbox/`, used `inotifywait` or polling to detect
file changes, and injected messages via a companion JavaScript plugin
(`opencode/plugins/oc-inject.js`).

`mise install` already removed the symlink, but the file continued to ship in `bin/`
and was directly callable. The deprecation comment named "the prototype question"
but no issue number, PR, or decision record existed explaining what that question was
or what had superseded it.

## Decision

Delete `bin/oc-inject`, `opencode/plugins/oc-inject.js`, `docs/oc-inject.md`, and
`tests/oc-inject-test.sh`.

## Rationale

**oc-inject was superseded by durable fleet state.** The mechanism it implemented —
delivering a message to a running OpenCode session out-of-band — is now provided by:

1. **Durable transport** (`SERGEANT_NOTIFY_TRANSPORT=durable`, the default): records
   a wake marker file at `$TASK_DIR/notify`. The worker's notification loop polls for
   it and delivers the message with a durable ID-bearing nudge. No live injection
   needed; the message survives coordinator crashes and restarts.

2. **tmux transport** (`SERGEANT_NOTIFY_TRANSPORT=tmux`): uses raw `tmux send-keys`
   to inject directly into the coordinator pane. This path in `bin/sgt-notify` never
   depended on `oc-inject` or the JavaScript plugin — it used `tmux send-keys`
   directly.

Critically: `bin/sgt-notify` contains zero references to `oc-inject`. The plugin
mechanism was entirely separate and its only production consumers (if any) no longer
existed.

## Consequences

- `bin/oc-inject` and `opencode/plugins/oc-inject.js` are deleted. Any direct
  invocations of `oc-inject` will fail with "command not found".
- `mise install` now removes stale symlinks unconditionally (no longer checks the
  target path).
- `docs/oc-inject.md` is deleted. References in `docs/README.md`, `docs/troubleshooting.md`,
  and `skills/sergeant-help/SKILL.md` are removed.
- `tests/oc-inject-test.sh` is deleted. The `SERGEANT_NOTIFY_TRANSPORT=tmux` assertion
  it contained is already covered by `tests/sgt-notify-test.sh`.
- The audit finding `S-4` in `docs/audit-2026-07.md` is resolved by this deletion.
