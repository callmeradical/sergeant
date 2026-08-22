# dispatch Specification

## Purpose
TBD - created by archiving change dispatch-produces-a-durable-record. Update Purpose after archive.

## Requirements

### Requirement: A dispatch persists the intent it serves

A dispatch SHALL record the intent behind the work and one bullet per target
repository before any worktree or branch exists. Decision D4 places intents and
bullets in sergeant's own store; decision D8 makes the intent the dashboard's
primary noun. Neither is satisfiable while a dispatch records only a run.

#### Scenario: An accepted dispatch writes its intent

- **WHEN** a dispatch is accepted for a project with a non-empty brief
- **THEN** the store holds an intent whose statement is that brief, whose project
  is that project, and whose status is `in_progress`

Fails today: `handleDispatch` never calls `CreateIntent`, so
`ListIntentsForProject` returns an empty slice after a successful dispatch.

#### Scenario: One bullet per target repository, in merge order

- **WHEN** a dispatch names three target repositories
- **THEN** the store holds three bullets for that intent, one per repository, with
  positions 1, 2 and 3 and no duplicate position

Fails today: `handleDispatch` never calls `CreateBullet`, so
`ListBulletsForIntent` returns an empty slice.

#### Scenario: A bullet names exactly one repository

- **WHEN** a bullet is created for a dispatch
- **THEN** its repo field holds exactly one repository name

A bullet spanning two repositories is a modelling error, not a large bullet.

#### Scenario: A rejected dispatch leaves nothing behind

- **WHEN** a dispatch is rejected because its OpenSpec change cannot be resolved
- **THEN** no intent and no bullet exist for that brief

Guards decision O3's ordering: the planning record precedes the durable record, so
a rejected dispatch must leave no orphaned domain rows.

### Requirement: A dispatch is idempotent under a caller-supplied key

A dispatch SHALL accept an optional caller-supplied `request_id` and SHALL treat a
repeat of a known key as a retry of the original request rather than a new one.
Decision D10 adopts this from AHP's `runAutomation`, which is idempotent by
`requestId` and returns the existing run on repeat.

#### Scenario: A repeated key returns the original run

- **WHEN** two dispatches carry the same non-empty `request_id`
- **THEN** the second returns the run id created by the first, and the store holds
  exactly one run for that key

Fails today: run identity comes from `time.Now().Unix()`, so the second call
creates a second run.

#### Scenario: A repeated key within the same second still deduplicates

- **WHEN** two dispatches carry the same `request_id` inside one second
- **THEN** the store holds exactly one run

Second-granularity ids currently collide by accident. Accidental collision is a
different failure from deliberate deduplication and is not the wanted behaviour.

#### Scenario: A repeated key creates no side effects

- **WHEN** a repeat of a known `request_id` is served
- **THEN** no second worktree, branch or agent process is created

The purpose of the key is suppressing side effects, not returning a tidy response.

#### Scenario: An omitted key remains valid

- **WHEN** a dispatch omits `request_id`
- **THEN** it is accepted and creates a new run

The key stays optional so existing callers and the MCP contract keep working, and
so two absent keys never deduplicate against each other.
