# Repo-Scoped Worker Skills

Sergeant vendors the workflow skills required by generated worker briefs in
`.agents/skills/`. This is the canonical Agent Skills tree discovered directly
by Codex.

OpenCode discovers the same tree through `opencode.json`. Claude discovers it
through the repository-local links in `.claude/skills/`. Those links resolve
only to `.agents/skills/`; no install step writes to a user's global agent
configuration.

The worker-brief inventory is:

- `code-review` — Standards and Spec review axes
- `codebase-design` — module interface and deep-module design
- `diagnosing-bugs` — hard bug and performance regression diagnosis
- `domain-modeling` — domain vocabulary and ubiquitous language
- `grill-with-docs` — requirements interview with ADR and glossary output
- `grilling` — requirements and plan stress-testing
- `implement` — feature or fix implementation driving tdd and review
- `no-mistakes` — shipping gate contract; vendored for worker context, not invocation
- `prototype` — throwaway design experiments with human-in-the-loop feedback
- `research` — primary-source investigation with captured findings
- `resolving-merge-conflicts` — intent-preserving conflict resolution
- `tdd` — red-green-refactor implementation loop
- `to-spec` — conversation-to-spec publication
- `to-tickets` — spec/conversation to dependency-aware tracer-bullet issues
- `triage` — issue and external PR triage state machine
- `wayfinder` — large-chunk work planning as a shared decision map

Two additional Sergeant-authored skills are also vendored here but are not
required by generated worker briefs:

- `sergeant-setup` — interactive, idempotent Sergeant bootstrap and repair

(`to-tickets` and `no-mistakes` above are also Sergeant-authored.)

Note on `no-mistakes`: workers are instructed never to invoke no-mistakes
directly. The skill is vendored so workers can load and understand the
coordinator-owned shipping gate contract when the brief references it.

See `.agents/skills/PROVENANCE.md` and
`.agents/skills/THIRD_PARTY_NOTICES.md` for source and license details.
