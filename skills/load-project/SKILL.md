---
name: load-project
description: Use when a Sergeant project is named, registered, edited, synced, or graphed; resolves repository ownership, configuration, paths, and inherited instructions.
---

# Skill: load-project

Resolve Sergeant project ownership, configuration, and paths before work begins.

## When to use

Load this skill when a project is named, registered, edited, or graphed, or when
repository ownership is not already established by project-details output.

## Load project context

1. If the project name is unknown, run `GET /api/projects` or list
   `~/.config/sergeant/*.yaml` and require an exact registered name.
2. Run `GET /api/project-details?name=<project>`, or read the project YAML
   directly via `internal/config.LoadProject`.
3. From the output, record:
   - owning repository or repositories for the requested outcome;
   - resolved absolute paths;
   - group membership and repository roles;
   - inherited instructions in defaults, group, repository order;
   - configured Graphify output and included groups.
4. Read a raw project YAML only when a required field is absent from the
   project-details output.
5. If a required repository's path does not exist, stop and report the exact
   path from the project YAML. v2 does not clone repositories on an operator's
   behalf — a missing or non-git path is refused, not fetched.

Completion evidence is the project-details response showing every owning
repository's resolved path plus the instructions that will govern execution.

## Project registration and edits

Use this procedure when the user asks to add or change a project:

1. Read `docs/schema.md` and the existing YAML when editing.
2. Write `~/.config/sergeant/<project>.yaml`; do not put credentials, tokens, or
   secret values in project YAML.
3. Use absolute repository paths or paths relative to the global `dev_root`.
4. Configure one project-level `graphify.output` outside source repositories when
   project Graphify is required.
5. Run `GET /api/projects` and require the project to appear exactly once.
6. Run `GET /api/project-details?name=<project>` and require every edited field
   needed by agents to appear in resolved output.
7. If a repository path in the edited YAML does not exist on disk, report it and
   stop — v2 does not clone or refresh repositories automatically.
8. If validation fails, restore the prior YAML or leave the new file uncommitted
   and report the exact error.

The schema source of truth remains `docs/schema.md`; do not duplicate its field
reference in agent instructions.

## Project Graphify

Use this procedure for project architecture questions or explicit graph updates:

1. Read the Graphify path from `GET /api/project-details?name=<project>`.
2. If no `graphify.output` is configured, stop and request or add the project-level
   path before building the graph.
3. `POST /api/build-graph` with `{"project": "<project>"}` (`internal/graphify.BuildProjectGraph`,
   decision D9).
4. Require `<graphify.output>/graph.json` and `GRAPH_REPORT.md` to exist after a
   successful build.
5. Use the `sergeant_graph_query`, `sergeant_graph_explain`, and
   `sergeant_graph_affected` MCP tools for focused questions; read `GRAPH_REPORT.md`
   for broad architecture, community, and god-node context.
6. Do not publish generated graph output inside an owning source repository.

## Failure behavior

| Condition | Required action |
|---|---|
| Project is unregistered | Stop and ask whether to register it. |
| Required repo has no URL | Stop with the repo name and missing field. |
| Required repo path does not exist | Report the exact path and stop; do not clone or invent a fallback. |
| Project-details and YAML disagree | Treat the project-details failure as blocking and preserve the YAML for diagnosis. |
| Graph output is stale | Rebuild via `POST /api/build-graph` only when architecture work requires a refresh or the user requests one. |
