# Skill: wiki

Maintain Sergeant's automatic activity captures and curated daily session digest.

## When to use

Load this skill when the user asks to ingest, backfill, regenerate, inspect, or
change wiki output. Do not load it for routine dispatch, notification, or cleanup;
those commands write automatic captures without coordinator action.

## Storage ownership

- `~/wiki/.captures/` contains automatic activity records written by Sergeant
  commands.
- `~/wiki/` contains curated pages governed by `~/wiki/SCHEMA.md`.
- `wiki-daily-digest` reads session history and captures, then writes curated
  session pages.

Do not copy raw prompts, response bodies, credentials, tokens, or secrets into
curated pages. Preserve task, repository, PR, merge, decision, and blocker facts
only when the wiki schema permits them.

## Automatic captures

The following commands own capture creation:

| Command | Captured event |
|---|---|
| `sgt-dispatch` | Fleet launch, task, project, branch, repositories, and brief metadata allowed by the capture schema |
| `sgt-notify` | Escalation or terminal outcome plus PR URL when present |
| `sgt-cleanup` | Worktree/fleet cleanup and final status |

If a capture is missing, reproduce the owning command in a fixture or fix its
capture adapter. Do not synthesize an automatic capture manually as a substitute.

## Daily digest

Use one command matching the requested range:

```bash
wiki-daily-digest --date YYYY-MM-DD
wiki-daily-digest --since YYYY-MM-DD
wiki-daily-digest --dry-run --date YYYY-MM-DD
```

Procedure:

1. Read `~/wiki/SCHEMA.md` before changing digest behavior or curated structure.
2. Run `--dry-run` first when regenerating an existing day or changing digest
   logic.
3. Inspect the proposed session page for secret material, duplicate entities,
   incorrect PR/task outcomes, and unresolved generation errors.
4. Run the non-dry command only after the preview satisfies the schema.
5. Verify `~/wiki/sessions/YYYY-MM-DD.md` exists and `~/wiki/index.md` links it.
6. Append or verify the schema-required ingest log entry.

The digest must synthesize outcomes, decisions, blockers, and next state; it must
not reproduce the conversation as a transcript.

## Scheduled execution

Treat scheduler installation or platform expansion as a separate task. One local
macOS example is `wiki-daily-digest --date yesterday` at 06:00 through
launchd. Verify the job definition, executable path, environment, last exit
status, and generated page before reporting scheduling complete.

## Failure behavior

| Condition | Required action |
|---|---|
| Schema missing or unreadable | Stop without writing curated pages. |
| Dry run contains secrets | Stop, record only the affected source class, and fix redaction before retry. |
| PR or td state cannot be resolved | Mark the outcome unresolved; do not infer completion. |
| Existing page would be overwritten with less information | Preserve the page and report the rejected update. |
| Index update fails | Keep the generated page, report its exact path, and leave the digest incomplete. |
