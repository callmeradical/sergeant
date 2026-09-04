# Sergeant Documentation

Sergeant is a single-user, local-first software factory: a Go-native engine
(`sergeant-v2`) that dispatches agent work into isolated git worktrees,
tracks it as durable Project → Intent → Bullet state, and exposes an
embedded dashboard. It replaced an earlier bash/tmux tool ("v1"), whose code
has been removed from this branch — see `docs/architecture.md`'s intro for
the full v1/v2 distinction.

## Start here (v2, current)

| Goal | Document |
|---|---|
| Install Sergeant and configure a first project or Copilot CLI | [Installation and first project](installation.md) |
| Understand v2's architecture and design rationale | [Architecture overview](architecture.md) |
| Read the binding product requirements and settled decisions | [PRD: Sergeant v2](prd-sergeant-v2.md) |
| Diagnose API/server problems | [Troubleshooting](troubleshooting.md) |
| See a satellite capability's requirements | `prd-*.md` in this directory (each cites which PRD/decision it extends) |
| See a capability once it's implemented and specified | `../openspec/specs/*/spec.md` (the living specs) |

## Reference

- [Project YAML schema](schema.md) — the canonical v2 schema reference
  (cited by `skills/load-project/SKILL.md`).
- [Repo-scoped worker skills](repo-scoped-skills.md) — current, matches the
  live `.agents/skills/` tree.
- [Annotated project example](../schema/project.yaml.example)
- [Repository agent policy](../AGENTS.md)
- [Sergeant command skills](../skills/)
- [OpenSpec planning](../openspec/) — `changes/` for in-flight/pending
  capability specs, `changes/archive/` for implemented-and-folded ones,
  `specs/` for the living, current-behavior specs.
- [Archived PRDs](prd/archive/) — PRDs whose OpenSpec change has been
  fully implemented and archived.

## Historical and planned documentation

The v1 docs that used to serve installation, usage, and skill-source
questions (`what-is-sergeant.md`, `getting-started.md`, `skills.md`,
`using-sergeant.md`) described the removed `sgt-*` shell toolbelt and tmux
workers, so they remain under `docs/archive/v1/` for historical reference.
The current v2 installation and first-project procedure is
[installation.md](installation.md).

## Historical

[`docs/archive/v1/`](archive/v1/) holds documentation for the removed v1
toolbelt kept for historical reference only: dated audits, ADRs, superseded
research, PRDs for work that either shipped in v1 or was superseded by v2's
own PRDs (see `docs/prd-sergeant-v2.md`), and the four v1-only usage docs
named above.

## Documentation authority

- `AGENTS.md` owns always-on agent execution and safety policy.
- `skills/*/SKILL.md` and `.agents/skills/*/SKILL.md` own trigger-specific procedures.
- `docs/schema.md` owns project configuration fields and path resolution.
- `docs/prd-sergeant-v2.md` owns binding v2 product requirements and settled decisions.
- `openspec/specs/*/spec.md` own current, binding capability behavior once implemented.
- This documentation set owns user installation and operating instructions.
- Command `--help` output wins when the command implements it. Otherwise use the
  command's emitted usage/error contract and its tests; file a task when prose
  disagrees with released behavior.

Documentation examples must not contain real credentials, private repository
names, prompt bodies, response bodies, or secret-bearing environment values.
