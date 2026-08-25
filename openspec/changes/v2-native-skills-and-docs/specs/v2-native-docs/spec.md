# v2-native docs

## ADDED Requirements

### Requirement: Sergeant-owned skill files describe v2's actual dispatch surface, not v1's deleted commands

The five `skills/*/SKILL.md` files that carry a "V1 ONLY" banner today SHALL,
after this change, contain no reference to any deleted `bin/sgt-*` command
and SHALL instruct the v2 HTTP API and MCP tools that actually exist.

#### Scenario: skills/dispatch/SKILL.md contains no v1 command reference

- **WHEN** `skills/dispatch/SKILL.md` is searched for `sgt-dispatch`,
  `sgt-watch`, `sgt-respond`, or `treehouse`
- **THEN** none of those strings are found

#### Scenario: skills/dispatch/SKILL.md instructs the real v2 dispatch call

- **WHEN** `skills/dispatch/SKILL.md` is searched for `POST /api/dispatch`
  and `POST /api/run-resume`
- **THEN** both are found

#### Scenario: skills/cross-repo-work/SKILL.md contains no v1 command reference

- **WHEN** `skills/cross-repo-work/SKILL.md` is searched for `sgt-context`,
  `sgt-status`, or `sgt-dispatch`
- **THEN** none of those strings are found

#### Scenario: skills/load-project/SKILL.md contains no v1 command reference

- **WHEN** `skills/load-project/SKILL.md` is searched for `sgt-list`,
  `sgt-context`, `sgt-sync`, or `sgt-graphify`
- **THEN** none of those strings are found

#### Scenario: skills/wiki/SKILL.md keeps wiki-daily-digest but drops dead capture-owner references

- **WHEN** `skills/wiki/SKILL.md` is searched for `wiki-daily-digest`
- **THEN** it is found
- **WHEN** the same file is searched for `sgt-dispatch`, `sgt-notify`, or
  `sgt-cleanup`
- **THEN** none of those strings are found

#### Scenario: The "V1 ONLY" banner is removed from all five rewritten skill files

- **WHEN** any of `skills/dispatch/SKILL.md`, `skills/cross-repo-work/
  SKILL.md`, `skills/load-project/SKILL.md`, `skills/wiki/SKILL.md`, or
  `skills/sergeant-help/SKILL.md` is searched for `V1 ONLY`
- **THEN** the string is not found in any of them

### Requirement: A skill states explicitly, rather than inventing a command, where v2 has no equivalent capability

Where v1 offered a capability v2 genuinely lacks (writable task-tracker
integration, automatic worktree pooling, a structured response-message
channel), the rewritten skill SHALL say so in plain language instead of
substituting an invented v2 command name.

#### Scenario: to-tickets states the read-only export gap instead of inventing a v2 task-creation command

- **WHEN** `.agents/skills/to-tickets/SKILL.md` is searched for
  `sgt-td-create` or any `td create`/`td update`/`td close` shell command
- **THEN** none of those are found
- **WHEN** the same file is searched for `read-only export`
- **THEN** the string is found

### Requirement: Documentation touched by this change accurately reflects the v2 project schema and troubleshooting paths

`docs/troubleshooting.md` and `schema/project.yaml.example` SHALL describe
only mechanisms that exist on `v2`.

#### Scenario: schema/project.yaml.example contains no deleted-command reference

- **WHEN** `schema/project.yaml.example` is searched for `sgt-graphify`,
  `sgt-sync`, `sgt-dag-run`, or `sgt-watch`
- **THEN** none of those strings are found

#### Scenario: docs/troubleshooting.md drops the v1-only Bash 3.2 Docker section and fleet-file cleanup protocol

- **WHEN** `docs/troubleshooting.md` is searched for `tests/runtime-bash-
  test.sh`, `docker.io/library/bash:3.2`, or `sgt-cleanup`
- **THEN** none of those strings are found

### Requirement: instruction-policy-test.sh enforces the new content for every file this change touches, and its unrelated pre-existing failures are unaffected

`tests/instruction-policy-test.sh` SHALL pass its assertions for every file
this change rewrites, and SHALL continue failing its pre-existing,
unrelated `AGENTS.md` assertions exactly as before — neither fixed nor
made worse by this change.

#### Scenario: The test's assertions for this change's files match the rewritten content

- **WHEN** `bash tests/instruction-policy-test.sh` is run after this change
- **THEN** it reports zero failures for any assertion naming
  `skills/dispatch/SKILL.md`, `skills/cross-repo-work/SKILL.md`,
  `skills/load-project/SKILL.md`, `skills/wiki/SKILL.md`,
  `skills/sergeant-help/SKILL.md`, `.agents/skills/to-tickets/SKILL.md`,
  `docs/troubleshooting.md`, or `schema/project.yaml.example`

#### Scenario: The test's 15 pre-existing AGENTS.md failures are unchanged in count and content

- **WHEN** `bash tests/instruction-policy-test.sh`'s output is compared
  before and after this change
- **THEN** the same 15 `AGENTS.md`-related failure lines appear in both,
  and no failure lines appear in the "after" run that did not appear in
  the "before" run
