# Repo-Scoped Skill Provenance

The upstream skill directories in this canonical `.agents/skills` tree were
imported unchanged from the local `agents` installation recorded in
`~/.agents/.skill-lock.json`. The lock identifies
[mattpocock/skills](https://github.com/mattpocock/skills) as their source.
That source repository declares the MIT License and
`Copyright (c) 2026 Matt Pocock`.

Last synced: 2026-07-30 (added 7 skills; initial import 2026-07-21 covered 7).

| Skill | Upstream path | Locked folder hash |
|---|---|---|
| `code-review` | `skills/engineering/code-review/SKILL.md` | `474a27d46efb1eff9724a29ae1edc9cd8a75d911` |
| `codebase-design` | `skills/engineering/codebase-design/SKILL.md` | `7347168e8de2de105e2e55f07ecb33d25fd56f44` |
| `diagnosing-bugs` | `skills/engineering/diagnosing-bugs/SKILL.md` | `27bf00e3ccc53491e938e8b5602be39238ce68f3` |
| `domain-modeling` | `skills/engineering/domain-modeling/SKILL.md` | `959e63161ff78b4b1cd553b2c0e09e0c68418e5f` |
| `grill-with-docs` | `skills/engineering/grill-with-docs/SKILL.md` | `5fdcdeedf2d0c73b3ecb1da0a464dd885590f8d6` |
| `grilling` | `skills/productivity/grilling/SKILL.md` | `10b0db61f9b3869243db8a1a0ee84f862139b94e` |
| `implement` | `skills/engineering/implement/SKILL.md` | `f07d230f645fc9ac390cf13a450bbff12ad791a3` |
| `prototype` | `skills/engineering/prototype/SKILL.md` | `dd3d782b69ccb67493fbe76b84149399da3c9fee` |
| `research` | `skills/engineering/research/SKILL.md` | `972a34cd8128b7952b7eb279b06715862db906a7` |
| `resolving-merge-conflicts` | `skills/engineering/resolving-merge-conflicts/SKILL.md` | `6aa1ed0b40fac0ebea5c0cf6f2addf82c99b6323` |
| `tdd` | `skills/engineering/tdd/SKILL.md` | `0a727bd358b855cbcc1c35cfff21ef31f9ffb8de` |
| `to-spec` | `skills/engineering/to-spec/SKILL.md` | `bf698b96b5d8798d110d9872e32b9310728555b0` |
| `triage` | `skills/engineering/triage/SKILL.md` | `258364be8354f726bf4080077cd92d86d08c69eb` |
| `wayfinder` | `skills/engineering/wayfinder/SKILL.md` | `33ed747fb30668c0e7b61698af5268c25c0d75cb` |

The custom `to-tickets` skill is Sergeant project-authored material owned by
Lars Cromley and explicitly authorized for MIT redistribution:
`Copyright (c) 2026 Lars Cromley`.

The custom `sergeant-setup` skill is Sergeant project-authored material owned by
Lars Cromley and explicitly authorized for MIT redistribution:
`Copyright (c) 2026 Lars Cromley`.

The `no-mistakes` skill describes the no-mistakes shipping gate contract used
by coordinators and referenced in worker briefs. It is user-authored material
owned by Lars Cromley and explicitly authorized for MIT redistribution:
`Copyright (c) 2026 Lars Cromley`. Workers do not invoke no-mistakes
directly; the skill is vendored so workers can load and understand the
contract when the brief references it.

**Local modification:** the vendored copy removes `user-invocable: true` from
the frontmatter and rewrites the `description` field to prevent agents in
worker worktrees from auto-loading this skill as an invocation target. A
worker-restriction callout block is also prepended to the skill body. These
changes are Sergeant-local and are not upstreamed.
