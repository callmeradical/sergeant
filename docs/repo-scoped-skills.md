# Repo-Scoped Worker Skills

Sergeant vendors the workflow skills required by generated worker briefs in
`.agents/skills/`. This is the canonical Agent Skills tree discovered directly
by Codex.

OpenCode discovers the same tree through `opencode.json`. Claude discovers it
through the repository-local links in `.claude/skills/`. Those links resolve
only to `.agents/skills/`; no install step writes to a user's global agent
configuration.

The required inventory is:

- `code-review`
- `diagnosing-bugs`
- `prototype`
- `resolving-merge-conflicts`
- `tdd`
- `to-spec`
- `to-tickets`
- `wayfinder`

`no-mistakes` remains an optional external integration and is not vendored.
See `.agents/skills/PROVENANCE.md` and
`.agents/skills/THIRD_PARTY_NOTICES.md` for source and license details.
