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
| Understand v2's architecture and design rationale | [Architecture overview](architecture.md) |
| Read the binding product requirements and settled decisions | [PRD: Sergeant v2](prd-sergeant-v2.md) |
| Diagnose API/server problems | [Troubleshooting](troubleshooting.md) |
| See a satellite capability's requirements | `prd-*.md` in this directory (each cites which PRD/decision it extends) |
| See a capability once it's implemented and specified | `../openspec/specs/*/spec.md` (the living specs) |

## Reference

- [Project YAML schema](schema.md) — still the canonical v2 schema
  reference (cited by `skills/load-project/SKILL.md`); its own prose still
  names some deleted v1 commands (`sgt-*`), a known, not-yet-fixed staleness
  gap distinct from the YAML shape itself, which is current.
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

## Not yet rewritten for v2

These describe v1 usage patterns (the removed `sgt-*` shell toolbelt,
tmux-based workers) and still serve the *purpose* v2 needs answered — first
install, what the product is, how to use it, which skills it vendors — but
have not been rewritten to describe v2. Rewriting them was explicitly
deferred as a separate scope decision by `openspec/changes/v2-native-skills-and-docs/`;
treat their content as stale until that happens:

- [What is Sergeant? (v1)](what-is-sergeant.md)
- [Getting started (v1)](getting-started.md)
- [Skills and their sources (v1)](skills.md)
- [Using Sergeant (v1)](using-sergeant.md)

## Historical

[`docs/archive/v1/`](archive/v1/) holds documentation for the removed v1
toolbelt kept for historical reference only: dated audits, ADRs, superseded
research, and PRDs for work that either shipped in v1 or was superseded by
v2's own PRDs (see `docs/prd-sergeant-v2.md`).

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
