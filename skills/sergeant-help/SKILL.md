# Skill: sergeant-help

Answer Sergeant installation, setup, usage, skills, and troubleshooting questions
from repository-owned documentation.

## When to use

Load this skill when the user asks what Sergeant is, how to install/configure/use
it, where skills come from, how to run a command/workflow, or how to diagnose a
Sergeant error.

Do not load it as a substitute for `load-project`, `cross-repo-work`, `dispatch`,
or `wiki` after the user has requested execution of those procedures.

## Documentation map

| Question | Primary document |
|---|---|
| Product and deployment model | `docs/what-is-sergeant.md` |
| Installation and first project | `docs/getting-started.md` |
| External and bundled skill sources | `docs/skills.md` |
| Direct/dispatch workflows and commands | `docs/using-sergeant.md` |
| Errors, stale workers, auth, gates, cleanup | `docs/troubleshooting.md` |
| Project YAML fields | `docs/schema.md` |
| OpenCode message injection | `docs/oc-inject.md` |
| Agent execution policy | `AGENTS.md` |

## Query procedure

1. Classify the question against the documentation map.
2. Read the primary document before searching broadly.
3. For terms not resolved there, search repository documentation and Sergeant
   skills:

   ```bash
   rg -n -i --glob '*.md' -- '<term>' README.md docs skills
   ```

4. When the configured Sergeant graph exists and the question is architectural,
   run `graphify query "<question>"` and use cited source locations.
5. For flag or argument questions, run `--help` only when the command supports
   it. Otherwise inspect its emitted usage/error contract and command tests.
6. Answer with the exact command, required preconditions, expected evidence, and
   links to repository-relative documentation paths.
7. If sources disagree, use this precedence:
   - command behavior, tests, and supported `--help` output for released syntax;
   - `AGENTS.md` for always-on execution/safety policy;
   - trigger-loaded skill for its procedure;
   - `docs/schema.md` for project fields;
   - user documentation for walkthroughs.
8. State when a behavior is undocumented or contradictory. Do not invent a
   command, flag, state transition, or safety guarantee.

## Help response format

```text
Answer: <direct answer>
Command: <exact command, when applicable>
Requires: <preconditions>
Verify: <observable success evidence>
Docs: <repository-relative links>
```

Omit fields that do not apply. Keep destructive operations out of examples unless
the documentation requires confirmation and the user explicitly requested them.

## Failure behavior

| Condition | Required action |
|---|---|
| Primary document missing | Report its expected path and stop before guessing. |
| Command differs from docs | Report the mismatch and trust tested released behavior or supported `--help`; create or suggest a documentation task. |
| Question requires project ownership | Load `load-project` and run `sgt-context`. |
| Question requires implementation or fleet mutation | Hand off to the owning procedural skill; help remains read-only. |
