# Tasks — v2-native skills and docs

One repository, `sergeant-v2`, so one task.

## Task 1 — rewrite the eight files and their test assertions together

Repository: `sergeant-v2`. Depends on: nothing.

Read first: every file this change touches, as it exists today (design.md
quotes the exact lines that change); `AGENTS.md`'s D1, D2, D4, D5, D6, D7,
O2, O3 for the concepts being substituted in; `internal/ui/server.go`'s
route registration (`mux.HandleFunc` calls) for the exact current API
surface; `internal/mcp/server.go`'s `Tools()` for the exact current MCP
tool names. Before writing, capture the pre-change baseline:

```bash
bash tests/instruction-policy-test.sh 2>&1 | grep '^FAIL:' > /tmp/baseline-failures.txt
```

(expected: exactly 15 lines, all naming `AGENTS.md`)

Then, per design.md's file-by-file transformation table:

- Rewrite `skills/dispatch/SKILL.md`, `skills/cross-repo-work/SKILL.md`,
  `skills/load-project/SKILL.md`, `skills/wiki/SKILL.md`,
  `skills/sergeant-help/SKILL.md` — remove the "V1 ONLY" banner from each,
  replace every v1 command reference per design.md's tables.
- Rewrite `.agents/skills/to-tickets/SKILL.md` — replace v1 references;
  state the read-only-export gap explicitly for task creation/mutation.
- Rewrite `docs/troubleshooting.md` — remove the sections design.md names
  as having no v2 relevance; rewrite the rest with v2 answers.
- Rewrite `schema/project.yaml.example` — remove the three stale-command
  comments; describe the same fields in v2 terms.
- Update `tests/instruction-policy-test.sh`'s `require_text`/`reject_text`
  lines for these eight files to match, per design.md's exact add/remove
  list — adjust exact wording on either side (the test's assertion or the
  file's phrasing) so they agree; design.md's listed strings are the
  intent, not necessarily the final byte-for-byte match.

Verification:

```bash
bash tests/instruction-policy-test.sh 2>&1 | grep '^FAIL:' > /tmp/after-failures.txt
diff /tmp/baseline-failures.txt /tmp/after-failures.txt
```

Exit status of the `diff` must be 0 (identical) — the 15 pre-existing
`AGENTS.md` failures are the only ones present, unchanged, before and after.
Any difference is a regression (something this change was supposed to fix
still failing) or a scope leak (something outside this change's eight files
newly failing).

Then confirm no code was accidentally touched:

```bash
go build ./... && go test ./internal/... -count=1 -skip '^(TestBuildProjectGraphAppliesExcludePatterns|TestBuildProjectGraphMergesEveryParticipatingRepo|TestIncludeGroupsExcludesNonMatchingRepos|TestBuildNeverLeavesOutputInAPartialState|TestPublishFailureRestoresPriorGraph|TestBuildNeverSpawnsSgtGraphify|TestQueryAgainstABuiltGraphReturnsAnAnswer|TestExplainAndAffectedAreDistinctFromQuery|TestMCPGraphQueryAgainstABuiltGraphReturnsAnswer|TestBuildGraphEndpointBuildsAndPublishes)$'
```

Both commands' exit status decide the outcome — this task is not done if
either fails, or if `git diff --stat` shows any file outside the nine named
above (eight content files plus the test).

Scenario coverage from `specs/v2-native-docs/spec.md` needing direct
checks (not just "the test passes" as a proxy): every scenario in that spec
is itself expressed as a grep/search over file content, so running the
literal commands each scenario names (as the test's `require_text`/
`reject_text` lines already do) is the direct check — there is no separate
"real mechanism" to exercise beyond the file content itself, unlike a
runtime behavior scenario.
