# Skills and Their Sources

Sergeant loads skills only when their trigger applies. Skills are executable agent
instructions; review their source before installing or updating them.

## Skill locations

| Location | Purpose |
|---|---|
| `skills/` in this repository | Sergeant-owned project, cross-repo, dispatch, wiki, and help procedures |
| `~/.agents/skills/` | Agent Skills standard installation shared by compatible harnesses |
| `~/.agents/.skill-lock.json` | Installed skill provenance, source URL, path, hashes, and timestamps |
| `~/.claude/skills/` | Claude Code skills or links to shared Agent Skills |
| `~/.config/opencode/skills/` | OpenCode-specific local skills |

Do not infer provenance from a folder name. Check `.skill-lock.json`, a package
lock, plugin metadata, or the source repository.

## Primary engineering skill source

Most engineering skills used in this installation come from Matt Pocock's
[Skills for Real Engineers](https://github.com/mattpocock/skills). The local
`~/.agents/.skill-lock.json` records `mattpocock/skills` as the source for
code-review, codebase-design, diagnosing-bugs, domain-modeling, grilling,
grill-with-docs, implement, prototype, research, resolving-merge-conflicts, TDD,
to-spec, triage, and wayfinder.

Official skills.sh installation:

```bash
npx skills@latest add mattpocock/skills
```

Select the skills and agent harnesses you use. Include
`setup-matt-pocock-skills`, then run that setup skill once in each repository to
configure issue tracker, labels, and documentation locations.

Official Claude Code plugin installation:

```bash
claude plugin marketplace add mattpocock/skills
claude plugin install mattpocock-skills@mattpocock
```

The skills.sh route copies editable skills into Agent Skills locations. The
Claude plugin route installs a managed read-only bundle. Do not edit plugin-owned
files and expect updates to preserve those edits.

Verify installed provenance:

```bash
jq '.skills | to_entries[] | {name: .key, source: .value.source, path: .value.skillPath}' \
  ~/.agents/.skill-lock.json
```

## Sergeant-owned skills

These ship with this repository and are governed by its tests and review:

| Skill | Trigger |
|---|---|
| `load-project` | A project is named, registered, edited, synced, or graphed |
| `cross-repo-work` | More than one repository owns the requested outcome |
| `dispatch` | Workers/fleets must be dispatched, monitored, answered, reconciled, or cleaned |
| `wiki` | Wiki ingestion, backfill, digest, or capture behavior is requested |
| `sergeant-help` | Installation, setup, usage, skills, or troubleshooting help is requested |

## Other local skills

This installation also contains local or tool-owned skills, including Graphify,
no-mistakes, swamp, and Sergeant's custom `to-tickets`. Their source and update
mechanism may differ from Matt Pocock's bundle. Inspect their package metadata,
repository, or skill file before distributing them to another user.

## Choosing a skill

Matt Pocock's source repository classifies skills by who invokes them.

**User-invoked orchestrators** are selected explicitly by the user and may drive
model-invoked disciplines:

| Work | Skill |
|---|---|
| Requirements interview plus project docs | `grill-with-docs` |
| Issue state-machine triage | `triage` |
| Publish the current conversation as a spec | `to-spec` |
| Build approved tickets/specification | `implement` (drives `tdd` and review) |
| Plan a program larger than one session | `wayfinder` |

**Model-invoked disciplines** are loaded automatically when the task matches:

| Work | Skill |
|---|---|
| Hard bug or performance regression | `diagnosing-bugs` |
| Red-green-refactor implementation loop | `tdd` |
| Code or spec review | `code-review` |
| Merge/rebase conflict | `resolving-merge-conflicts` |
| Architecture/interface design | `codebase-design` |
| Domain terminology or ADR | `domain-modeling` |
| Throwaway design experiment | `prototype` |
| Research from primary sources | `research` |
| Reusable requirements interview loop | `grilling` |

## Skill instruction quality

Every directive in a Sergeant-owned skill must contain a trigger, action,
prohibition, observable evidence, or stop condition. Do not add slogans such as
"be thorough," "write clean code," or "use best practices." Replace them with
commands, failure behavior, acceptance criteria, ownership, or review evidence.

Before adopting an external skill:

1. Read its complete `SKILL.md` and referenced scripts.
2. Confirm its source and update mechanism.
3. Check filesystem, shell, network, Git, and credential actions.
4. Verify it does not conflict with repository `AGENTS.md` or safety policy.
5. Pin or lock the source where the installer supports it.
6. Test it in a disposable repository or worktree before broad installation.

## Updating skills

For skills.sh-managed skills, rerun the official installer and inspect the diff
and updated lock file before accepting changes:

```bash
npx skills@latest add mattpocock/skills
```

For Claude plugins, use the Claude plugin manager. For Sergeant-owned skills,
update this repository through a reviewed PR and run
`bash tests/instruction-policy-test.sh` plus the full Sergeant test suite.
