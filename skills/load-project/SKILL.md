# Skill: load-project

Resolve Sergeant project ownership, configuration, and paths before work begins.

## When to use

Load this skill when a project is named, registered, edited, synced, or graphed,
or when repository ownership is not already established by `sgt-context` output.

## Load project context

1. If the project name is unknown, run `sgt-list` or `bin/sgt-list` and require
   an exact registered name.
2. Run `sgt-context <project>` or `bin/sgt-context <project>`.
3. From the output, record:
   - owning repository or repositories for the requested outcome;
   - resolved absolute paths and clone state;
   - group membership and repository roles;
   - inherited instructions in defaults, group, repository order;
   - configured Graphify output and included groups.
4. Read a raw project YAML only when a required field is absent from the context
   output.
5. If a required repository is missing, run `sgt-sync <project>` only after the
   requested work requires that repository. Stop if cloning or pull fails.

Completion evidence is the `sgt-context` block showing every owning repository as
cloned plus the instructions and paths that will govern execution.

## Project registration and edits

Use this procedure when the user asks to add or change a project:

1. Read `docs/schema.md` and the existing YAML when editing.
2. Write `~/.config/sergeant/<project>.yaml`; do not put credentials, tokens, or
   secret values in project YAML.
3. Use absolute repository paths or paths relative to the global `dev_root`.
4. Configure one project-level `graphify.output` outside source repositories when
   project Graphify is required.
5. Run `sgt-list` and require the project to appear exactly once.
6. Run `sgt-context <project>` and require every edited field needed by agents to
   appear in resolved output.
7. Run `sgt-sync <project>` only when repositories must be cloned or refreshed.
8. If validation fails, restore the prior YAML or leave the new file uncommitted
   and report the exact command error.

The schema source of truth remains `docs/schema.md`; do not duplicate its field
reference in agent instructions.

## Project Graphify

Use this procedure for project architecture questions or explicit graph updates:

1. Read the Graphify path from `sgt-context <project>`.
2. If no `graphify.output` is configured, stop and request or add the project-level
   path before running Graphify.
3. Run `sgt-graphify <project>` or `bin/sgt-graphify <project>`.
4. Require `<graphify.output>/graph.json` and `GRAPH_REPORT.md` to exist after a
   successful run.
5. Use `graphify query` for focused questions; read `GRAPH_REPORT.md` for broad
   architecture, community, and god-node context.
6. Do not publish generated graph output inside an owning source repository.

## Failure behavior

| Condition | Required action |
|---|---|
| Project is unregistered | Stop and ask whether to register it. |
| Required repo has no URL | Stop with the repo name and missing field. |
| Required executable is missing | Report the executable and platform-neutral installation requirement; do not invent a fallback parser. |
| Context and YAML disagree | Treat `sgt-context` failure as blocking and preserve the YAML for diagnosis. |
| Graph output is stale | Run `sgt-graphify` only when architecture work requires a refresh or the user requests one. |
