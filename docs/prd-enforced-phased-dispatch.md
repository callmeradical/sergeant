# Product Requirements: Enforced Phased Dispatch

Status: Draft, awaiting explicit human PRD approval

Pinned source baseline: `348c2335526c00d40f7ec0bb4ef23d0650ce3a4d`

## Summary

Sergeant must turn a change-producing dispatch into a controlled sequence of product definition, specification, and implementation. A change-producing dispatch must not reach OpenSpec authoring until a human approves its PRD, and must not reach implementation until a human approves its OpenSpec artifacts. Sergeant must preserve enough durable, privacy-safe evidence to prove what was approved, what was dispatched, and how interrupted work resumed.

This PRD defines the product contract for that lifecycle. It does not define the shell implementation or create OpenSpec artifacts.

## Users

- **Requester:** states the desired outcome and receives questions, review artifacts, and completion results.
- **Human approver:** accepts responsibility for allowing work to cross a PRD or specification gate by personally invoking the matching approval command. The requester and approver may be the same person.
- **Coordinator:** the primary Sergeant session that creates and supervises the lifecycle, presents gates to the human, and reconciles phase results.
- **Phase worker:** an isolated agent dispatched for exactly one authorized phase and repository scope.
- **Maintainer or auditor:** diagnoses interrupted work and verifies the relationship among requests, approvals, artifacts, fleets, commits, and PRs.

## Problem

Today, a sufficiently broad dispatch brief can mix product decisions, technical design, and implementation in one worker mission. That allows an agent to infer consequential requirements, produce a specification nobody explicitly accepted, or begin implementation while the source artifacts are still changing. Existing worker statuses describe execution health, but they do not prove that product and specification gates were satisfied.

The result is avoidable rework and weak accountability:

- humans may review implementation without knowing which requirements it claims to satisfy;
- agents may silently resolve product ambiguity;
- an approval may accidentally apply to bytes that changed afterward;
- retries may dispatch duplicate or out-of-order work;
- fleet cleanup may erase the only convenient account of how a request advanced; and
- logs may retain request or response bodies that contain private data.

## Product Principle

Planning artifacts are executable authority, not advisory context. Each downstream phase receives only an explicitly approved, content-addressed upstream revision. Agents can author and revise artifacts, but only a human can authorize a gate transition or a phase skip.

## Outcomes

1. Product decisions are explicit in a PRD before technical specification begins.
2. OpenSpec artifacts are explicitly accepted before implementation begins.
3. Every implementation worker can identify the exact approved PRD and specification revision that authorizes its work.
4. Approval remains valid only for the artifact bytes the human reviewed.
5. Interrupted coordinators and workers resume without bypassing a gate or duplicating a phase.
6. Fleet and lifecycle records provide a durable, correlated audit trail without storing artifact bodies, prompts, responses, credentials, or secrets.
7. Existing active fleets and existing worker supervision commands remain operable during rollout.

## Non-Goals

- Defining the content schema of every PRD or OpenSpec document beyond the gate requirements in this PRD.
- Replacing OpenSpec, Git, treehouse, worker review, no-mistakes, CI, or repository-native tests.
- Approving an implementation, merging a PR, or declaring delivery complete at specification approval.
- Automatically deciding product questions or evaluating whether a human made a good decision.
- Providing cryptographic human identity, organizational authorization, or non-repudiation beyond the local actor evidence available to Sergeant.
- Migrating or retroactively gating fleets created before this lifecycle is introduced.
- Implementing the lifecycle as part of the work that authors this PRD.

## Terminology

- **Lifecycle:** one durable progression from a captured request through terminal delivery or cancellation.
- **Phase:** a bounded kind of work with its own permitted outputs and workers.
- **Gate:** a durable waiting point that prevents entry into a downstream phase.
- **Phase state:** the coordinator-level lifecycle state. It is distinct from a worker's `in_progress`, `needs_input`, `blocked`, `orphaned`, `done`, or `failed` execution status.
- **Artifact revision:** a manifest of one or more repository-qualified paths, one canonical Git commit per represented repository, and SHA-256 content digests. Its revision digest is the sole entry's digest for a single-entry manifest or the aggregate manifest digest for a multi-entry manifest.
- **Approval:** a decision recorded by a human's personal invocation of an approval command, authorizing one exact artifact revision to cross one gate. Sergeant enforces an interactive ceremony and records the local operating-system identity, but does not claim to prove that the actor is biologically human.
- **Skip:** a human-approved declaration that a normally required artifact is unnecessary under the eligibility rules below. A skip crosses a gate but does not fabricate an artifact.
- **Superseding revision:** a new artifact revision created after an earlier revision was approved. It requires a new approval and invalidates dependent downstream authority.
- **Lifecycle generation:** a monotonically increasing number identifying each durable phase transition or renewed gate publication.
- **Owning repository:** the repository where the lifecycle's PRD, canonical lifecycle index, and primary audit references live.
- **Source-request reference:** one of exactly four fields that identifies source authority without reproducing it: repository identity, repository-relative artifact path, Git commit SHA, or content digest. No other source-request identifier is permitted in output or retained lifecycle data.
- **Change-producing dispatch:** any Sergeant dispatch authorized to add, modify, delete, generate, commit, publish, deploy, or otherwise alter repository content or runtime state. Every `sgt-dispatch` invocation is change-producing unless the caller explicitly selects enforced read-only mode. Documentation and mechanical maintenance are change-producing; eligible cases cross gates through the skip rules rather than bypassing the lifecycle.
- **Read-only dispatch:** an `sgt-dispatch --read-only` invocation whose brief and worker controls prohibit repository or runtime mutation, commits, pushes, and delivery. Investigation and review may use this mode. A mutation attempt stops the worker and requires a new change-producing lifecycle; ambiguity defaults to change-producing.

## Lifecycle Model

### Phases and gates

| State | Permitted activity | Exit condition |
|---|---|---|
| `request_captured` | Record lifecycle ID, owning repository, affected repositories, and permitted source-request references. | PRD authoring is dispatched, an eligible PRD skip proposal is published directly to `awaiting_prd_approval`, or the lifecycle is cancelled. |
| `prd_authoring` | A PRD worker may create or revise only the PRD and supporting review evidence, or may publish an eligible skip proposal instead of an artifact. | A complete PRD revision or eligible skip proposal is published to `awaiting_prd_approval`. |
| `awaiting_prd_approval` | Humans may review the published PRD revision or skip proposal; workers may answer questions or publish a superseding proposal. | `sgt-approve-prd` records approval of the displayed revision or skip; cancellation is also allowed. |
| `spec_authoring` | OpenSpec workers may create or revise only OpenSpec artifacts authorized by the approved PRD, or may publish an eligible skip proposal instead of artifacts. | A complete OpenSpec revision or eligible skip proposal is published to `awaiting_spec_approval`. |
| `awaiting_spec_approval` | Humans may review the published OpenSpec revision or skip proposal; workers may answer questions or publish a superseding proposal. | `sgt-approve-spec` records approval of the displayed revision or skip; cancellation is also allowed. |
| `ready_for_implementation` | Resolve repository decomposition, dependency order, and implementation assignments from the approved artifacts. After reapproval, reconcile existing workers before creating any replacements. | Implementation workers are successfully dispatched, or matching paused workers are resumed. |
| `implementing` | Workers implement, test, review, validate, and deliver only the approved scope. Existing worker status semantics continue to apply. | All delivery gates pass, the lifecycle is cancelled, or an unrecoverable failure is recorded. |
| `cancelling` | Prevent new dispatches, request termination of live workers, and account for each worker as stopped or orphaned. | Every worker is proven non-live, then enter `cancelled`; otherwise remain nonterminal and publish a recoverable blocked condition. |
| `done` | Preserve final references and outcome. No further dispatch is permitted. | Terminal. |
| `cancelled` | Preserve reason, actor, last valid artifacts, and worker disposition. No further dispatch is permitted. | Terminal after `sgt-cancel` completes. |
| `failed` | Preserve exact unrecoverable reason and recovery evidence. No further dispatch is permitted; continued work requires a new correlated lifecycle. | Terminal. |

The only normal forward sequence is:

```text
request_captured
  -> prd_authoring
  -> awaiting_prd_approval
  -> spec_authoring
  -> awaiting_spec_approval
  -> ready_for_implementation
  -> implementing
  -> done
```

A phase skip proposal enters the same `awaiting_*_approval` state as an artifact revision. Approval of that proposal advances to the next phase; the skip does not remove the gate. `cancelled` is reachable from any nonterminal state only through `sgt-cancel`. `failed` is reserved for unrecoverable lifecycle corruption or loss, not ordinary worker failure or a recoverable wait.

### Enforcement rules

- Each phase worker receives a brief limited to its current phase, approved inputs, permitted outputs, and repository scope.
- No PRD worker may create OpenSpec artifacts or implementation changes.
- No specification worker may modify the approved PRD or create implementation changes.
- No implementation worktree, worker process, or implementation assignment may be started before both gates have durable approval or eligible skip records.
- A worker's successful turn, commit, PR, or `done` status cannot advance the lifecycle by itself.
- Cross-repository implementation decomposition occurs only after specification approval, so all implementation workers receive the same approved authority.
- A transition must durably commit its new generation and audit event before downstream workers start.

## Human Approval Commands

### `sgt-approve-prd`

```text
sgt-approve-prd <lifecycle-id>
sgt-approve-prd <lifecycle-id> --skip --reason <reason>
```

The command must:

1. first return the existing approval without mutation when the same revision was already approved; otherwise require the lifecycle to be in `awaiting_prd_approval`;
2. show the repository identity, repository-relative PRD path, Git commit, SHA-256 digest, and downstream effect, or show the proposed skip category and reason; it must never display a source request or dispatch brief body, including a redacted body;
3. require an explicit confirmation from an interactive terminal, with no `--yes`, piped-stdin, environment-variable, or worker-brief bypass;
4. record the local actor identifier, timestamp, lifecycle generation, and approved revision or skip;
5. append a privacy-safe lifecycle decision event referencing the same evidence; and
6. transition atomically and idempotently to `spec_authoring`.

### `sgt-approve-spec`

```text
sgt-approve-spec <lifecycle-id>
sgt-approve-spec <lifecycle-id> --skip --reason <reason>
```

The command has the same interaction and audit requirements as `sgt-approve-prd`, but presents the complete OpenSpec artifact manifest and the approved PRD revision that authorized it. It transitions atomically and idempotently to `ready_for_implementation`.

### Shared approval behavior

- The command operates on the canonical artifact manifest already published by the phase worker; callers cannot substitute paths or digests at approval time.
- Approval displays use repository identity, repository-relative artifact path, commit SHA, and content digest as the only source-request references. Privacy-safe downstream effect, skip category and reason, and local operating-system actor evidence are also permitted. Approval commands never display or persist source request or dispatch brief bodies, redacted or otherwise.
- For an artifact approval, the human must type `approve <phase> <full-sha256-digest>` exactly as displayed. A skip proposal has a SHA-256 digest binding its category, exact reason, lifecycle, generation, and scope; `--reason` must exactly match the published reason, and the human must type `skip <phase> <full-proposal-sha256-digest>` exactly. Any mismatch or other input leaves state unchanged.
- Repeating an approval command for the already approved revision succeeds without another transition and reports the existing event. A different revision requires a new gate generation and confirmation.
- A refusal or interrupted prompt leaves the lifecycle and all artifacts unchanged.
- The local actor identifier is the operating-system username and numeric user ID that own the approval process. Sergeant displays and records both while clearly stating that they are evidence, not strong identity proof.
- Agents and workers are contractually prohibited from invoking either approval command. The coordinator may present the command and its output, but the human approver must personally invoke it. The interactive ceremony prevents unattended advancement; preventing a human from delegating terminal control is outside Sergeant's enforcement boundary.

### Cancellation command

```text
sgt-cancel <lifecycle-id> --reason <reason>
```

Cancellation requires the same interactive-terminal and local-actor evidence as approval. The command displays the current phase and all nonterminal workers, then requires the human to type `cancel <lifecycle-id>` exactly. It atomically prevents new dispatches, records a privacy-safe lifecycle decision event, and enters `cancelling`; it then requests termination through existing supervision and records each worker as stopped or orphaned. It enters `cancelled` only after proving no worker is live. A worker that cannot yet be terminated or classified leaves the lifecycle in `cancelling` with a recoverable blocked condition and exact diagnostics. Repeating the command resumes or reports the same cancellation without creating another transition. Cleanup becomes eligible only after `cancelled` is reached.

## Artifact Immutability

- A phase publishes a canonical artifact manifest before entering its approval gate.
- Each manifest entry contains a repository identity, repository-relative path, Git commit SHA, and SHA-256 digest. Every entry for one repository in an artifact revision uses the same canonical commit. A canonical multi-file or multi-repository manifest also receives one aggregate SHA-256 digest over the ordered entries.
- Approval binds to the manifest and artifact bytes, not merely to a branch, path, PR, mutable ref, or latest commit.
- Before recording an artifact approval, Sergeant creates the same immutable Git ref name, `refs/sergeant/artifacts/<lifecycle>/<phase>/<digest>`, independently in every represented repository, pointing to that repository's canonical recorded commit. The approval transition fails without mutation unless all required refs make every approved artifact byte recoverable and the bytes match the manifest digests.
- Artifact refs are retained indefinitely by default, including after superseding revisions, terminal lifecycle states, and fleet cleanup. Sergeant must never move an existing artifact ref to another commit or delete it automatically.
- Deleting an artifact ref requires an explicit interactive human command that displays its repository, lifecycle, phase, digest, commit, and dependency status; records local actor and timestamp evidence in the append-only lifecycle audit; and requires exact typed confirmation. The command must refuse deletion while any lifecycle uses the artifact as active authority or any downstream artifact, worker, or delivery still depends on it. Append-only approval and lifecycle records remain auditable references but do not by themselves prevent deletion. A successful deletion preserves a tombstone containing the repository, ref name, commit, digest, actor, timestamp, and reason, but no artifact, request, or brief body.
- Any byte change, file addition, file removal, rename, manifest change, or commit substitution creates a superseding revision. It cannot inherit approval.
- Before every downstream dispatch and resume, Sergeant verifies the approved manifest. A mismatch returns the lifecycle to the corresponding approval gate with a new generation and blocks downstream work.
- If a PRD is superseded after specification work begins, its specification approval is invalidated and the lifecycle returns to `awaiting_prd_approval`. If a PRD or specification is superseded after implementation begins, Sergeant blocks new dispatches, moves active workers to `blocked`, and returns the lifecycle to the earliest invalid `awaiting_*_approval` state. After all invalidated gates are reapproved, `ready_for_implementation` reconciles and resumes workers whose approved authority still matches; nonmatching workers remain blocked until they are recorded as abandoned and replaced.
- Approval records and prior manifests are append-only. Superseded records remain auditable and are marked inactive rather than overwritten.

## Skip Rules

Skipping is exceptional and always requires the matching human approval command with `--skip` and a non-empty reason. A coordinator or worker may propose a skip but cannot authorize it.

### PRD skip eligibility

A PRD may be skipped only when the request is exactly one of:

- a revert of an identified commit or release, with no additional behavior;
- urgent containment that disables or rolls back identified behavior without designing replacement behavior; or
- mechanical maintenance limited to formatting, spelling, comments, generated-file refresh, or dependency metadata with no runtime, interface, security, privacy, data, operational, or user-experience effect.

Unapproved supporting material is not by itself an approved PRD and does not qualify a product change for a skip. A pre-existing approved PRD is reused as an immutable artifact revision rather than skipped.

### Specification skip eligibility

A specification may be skipped only when:

- the PRD was validly skipped and the work remains within the same eligible category; or
- an approved PRD completely prescribes a single-repository, mechanical change with no API or CLI contract change, schema or data migration, security or privacy impact, infrastructure topology change, concurrency behavior, or cross-repository dependency.

An existing approved OpenSpec revision is reused rather than skipped.

### Skip constraints

- Uncertainty about eligibility means the phase is required.
- A skip applies to one phase, lifecycle, scope, and generation. It cannot be inherited by a superseding request or expanded implementation scope.
- Skip records contain category, reason, actor, timestamp, permitted source-request references when applicable, and lifecycle generation, but no request or response body.
- Any later scope expansion invalidates applicable skips and returns the lifecycle to the earliest required gate.
- Emergency containment may proceed with eligible skips, but replacement behavior starts a new normally gated lifecycle.

## Fleet and Lifecycle Audit Requirements

### Fleet record

The fleet state is the operational source of truth while a lifecycle is active. It must durably retain:

- lifecycle ID and schema version;
- project, owning repository, affected repositories, and permitted source-request references;
- current phase state and monotonic generation;
- artifact manifests and aggregate digests;
- approval and skip events, including actor, timestamp, and reason when applicable;
- phase worker IDs, worktree references, execution statuses, dependency order, and terminal results;
- recovery events, orphan diagnostics, invalidations, cancellations, and failures; and
- final PR and commit references when delivery succeeds.

Lifecycle events are append-only. Current-state summaries may be regenerated from them and may be updated atomically, but must not replace the event history.

### Lifecycle index

- The owning repository retains one durable, human-readable canonical structured-field index for the lifecycle.
- The index may format only these enumerated fields: lifecycle ID and schema version; project; owning and affected repositories; current phase and generation; permitted source-request references; artifact manifests and digests; approval or skip actor, timestamp, category, and reason; privacy-safe downstream effect; phase worker IDs, execution statuses, dependency order, and terminal results; structured recovery, invalidation, cancellation, and failure state; and final PR and commit references.
- The index correlates PRD authoring, specification authoring, and each repository's implementation assignments without replacing their phase records.
- The index must not contain free-form or request-derived narrative, paraphrases, intent summaries, source request bodies, or dispatch brief bodies, including redacted bodies. Any source authority is represented only by the permitted source-request references.
- PRD and specification phase records remain awaiting approval at their gates; an artifact commit alone cannot close a gate. The matching approval command records the human gate evidence before advancing. A rejected or interrupted gate remains awaiting approval, while a superseding revision returns the phase to active work and requires renewed review.
- Implementation assignments must not start before `ready_for_implementation`.
- Fleet cleanup preserves the complete privacy-safe lifecycle event ledger and terminal downstream effect through the existing Sergeant capture mechanism before ephemeral worktrees or live fleet state are removed. Sergeant retains this capture indefinitely and never deletes it automatically; a user may delete it manually under their own retention policy.

Fleet events are the machine-operational record; the lifecycle index is their durable human-readable structured-field view. A mismatch blocks phase advancement and requires recovery rather than silently choosing one record.

## Recovery Semantics

- All transitions, approvals, skips, artifact publications, and response consumptions are idempotent and keyed by lifecycle generation.
- On coordinator restart, Sergeant reconstructs current state from durable fleet events, verifies it against the lifecycle index and artifact manifests, and resumes the existing phase. It must not create a replacement lifecycle or duplicate workers automatically.
- Existing `in_progress`, `needs_input`, `blocked`, `orphaned`, `done`, and `failed` worker semantics remain valid within a phase. A recoverable worker failure does not become lifecycle `failed`.
- An orphaned phase worker resumes through the existing response and session recovery path. If no resumable session exists, Sergeant may dispatch a replacement for the same phase only after recording the abandoned worker and proving that no live worker still owns the phase.
- A waiting worker remains alive until its response is durably consumed under the existing response-generation proof rules. Lifecycle transitions cannot treat a waiting status as completion.
- If an approval was durably recorded but downstream dispatch did not start, recovery verifies the approval and continues exactly once.
- If downstream dispatch started but its transition event is incomplete, recovery records the discovered workers, reconciles them to the intended generation, and either adopts the exact matching dispatch or blocks for human repair. It never starts speculative duplicates.
- Missing artifacts or digest mismatch leave or return the lifecycle to the corresponding `awaiting_*_approval` state and publish a recoverable blocked execution condition with exact evidence. Non-monotonic generations, contradictory approvals, or disagreement between fleet events and the lifecycle index leave the current lifecycle phase unchanged and publish the same blocked condition pending repair. `blocked` is not a lifecycle phase. Unrecoverable loss is required before lifecycle `failed` is valid.
- Cleanup refuses active, awaiting-approval, `cancelling`, blocked, or orphaned work unless the lifecycle first reaches a terminal state.

## Privacy and Security Constraints

- Fleet lifecycle metadata, lifecycle events, notifications, and terminal captures must never store PRD or OpenSpec bodies, dispatch brief bodies, prompts, model responses, `.sergeant-response` plaintext, credentials, tokens, environment dumps, or secrets.
- Across command output, fleet metadata, lifecycle events, notifications, terminal captures, and the lifecycle index, source authority is represented only by repository identity, repository-relative artifact path, Git commit SHA, and content digest. Downstream effect, skip category and reason, and local operating-system actor evidence are permitted non-source evidence.
- Project is permitted as privacy-safe operational grouping metadata. Mutable branch names are not retained in lifecycle records or the lifecycle index and are not source-request references.
- Skip and cancellation reasons must be concise and must not quote sensitive request content.
- Artifact content remains in its repository under that repository's access controls. Sergeant records references and digests only.
- Temporary confirmation and response plaintext is removed after durable consumption according to existing response transport guarantees.
- Notifications contain only lifecycle ID, repository identity, phase, and state.
- Files containing lifecycle metadata use least-privilege local permissions consistent with existing fleet state.
- Command output must redact credential-bearing URLs and known secret-like values before display or persistence.

## Compatibility and Rollout

- Fleets created before phased lifecycle metadata is introduced remain legacy fleets. `sgt-watch`, `sgt-respond`, `sgt-notify`, and `sgt-cleanup` continue to operate on them with their existing behavior.
- New `sgt-dispatch` invocations use the phased lifecycle by default. Existing project, brief, repository, branch, dependency, and supported execution-backend inputs remain accepted; the behavioral change is that implementation waits behind gates. Explicit `--read-only` dispatches use enforced read-only mode instead.
- Standalone status, context loading, graph generation, and fleet supervision commands do not dispatch workers and therefore do not enter this lifecycle. A dispatch that will modify or commit generated graph output is change-producing.
- Existing worker status strings and `.sergeant-status`, `.sergeant-message`, `.sergeant-result`, response ID, response acknowledgement, and gate-generation contracts remain unchanged within each phase.
- No project YAML migration is required to adopt the lifecycle.
- Unsupported or malformed lifecycle versions fail closed for phase advancement while remaining inspectable and cleanly diagnosable.
- Rollout documentation must state how users identify legacy versus phased fleets and how they recover either form.

## Measurable Acceptance Criteria

1. Given a new change-producing dispatch, no OpenSpec worker or worktree exists before a successful `sgt-approve-prd` event for the published PRD revision or eligible PRD skip proposal.
2. Given an approved PRD revision or skip, no implementation worker, worktree, or implementation assignment starts before a successful `sgt-approve-spec` event for the complete OpenSpec revision or eligible specification skip proposal.
3. Given an artifact approval prompt, only the exact `approve <phase> <full-sha256-digest>` confirmation advances state. Noninteractive invocation, piped confirmation, a missing or abbreviated digest, and a worker-brief attempt to bypass confirmation are rejected; the resulting event records the displayed operating-system username and numeric user ID.
4. Given the same approval command repeated for the same revision, exactly one transition and one authoritative approval event exist.
5. Given any approved artifact byte or manifest change, the prior approval becomes inactive, downstream dispatch is blocked, and a new human approval is required.
6. Given a qualifying skip, only an exact `--reason` match and `skip <phase> <full-proposal-sha256-digest>` confirmation advances state and records category, reason, actor, timestamp, scope, and generation; a mismatch, nonqualifying skip, or ambiguous skip is rejected.
7. Given scope expansion after a skip, Sergeant returns to the earliest newly required gate before additional work is dispatched.
8. Every implementation brief names the lifecycle ID and exact approved PRD and specification commits and SHA-256 digests, or the applicable approved skips.
9. Every phase transition is correlated across fleet state and the lifecycle index by lifecycle ID, phase, generation, artifact digest or skip, and timestamp.
10. Scanning fleet metadata, lifecycle events, notifications, and terminal captures finds no artifact bodies, brief bodies, prompts, responses, credentials, tokens, or secrets from phase fixtures.
11. Killing the coordinator before and after each durable transition boundary resumes the same lifecycle in the correct phase without a gate bypass or duplicate phase worker.
12. Orphaning a worker preserves diagnostics and permits exactly one adoption, resume, or recorded replacement path.
13. Artifact loss, digest mismatch, contradictory records, and unknown lifecycle versions fail closed with actionable recovery evidence.
14. Legacy fleet fixtures continue to pass existing watch, respond, notify, and cleanup regression suites without lifecycle migration.
15. Existing supported `sgt-dispatch` invocation forms remain parse-compatible and create a visible phased lifecycle for change-producing work.
16. Cleanup rejects every nonterminal lifecycle state and preserves the complete privacy-safe event ledger plus the terminal downstream effect before deleting ephemeral state.
17. Repository-native focused and full test suites, independent standards review, independent spec review, and required shipping checks pass before the lifecycle implementation is delivered.
18. Given any nonterminal phase, `sgt-cancel` requires exact interactive confirmation, prevents new dispatch, and records one idempotent lifecycle cancellation event. It remains in nonterminal `cancelling` while any worker is live or unaccounted for and permits cleanup only after reaching `cancelled`.
19. Every `sgt-dispatch` defaults to a phased lifecycle. `--read-only` rejects mutation, and an ambiguous brief cannot use read-only mode to bypass gates.
20. PRD and specification phase records remain awaiting approval at their gates, advance only through matching approval evidence, and return to active work when a superseding revision invalidates that evidence.
21. Every command output and retained lifecycle record uses repository identity, repository-relative path, commit SHA, and content digest as its only source-request references. It may also contain project as privacy-safe operational grouping metadata, privacy-safe downstream effect, skip category and reason, and local operating-system actor evidence. Fixtures containing branch names, other source identifiers, source request bodies, and dispatch brief bodies produce none of that data in output or retained metadata, including redacted body text.
22. Given a multi-repository artifact revision, every manifest entry names its repository, all entries for one repository use one canonical commit, and the aggregate digest binds the ordered repository-qualified entries.
23. Every artifact approval creates `refs/sergeant/artifacts/<lifecycle>/<phase>/<digest>` independently in each represented repository at its canonical commit before advancing, where `<digest>` is the artifact revision digest. Superseding, completing, and cleaning a lifecycle leave every ref unchanged; deletion requires audited interactive human confirmation and is rejected while any lifecycle uses the artifact as active authority or downstream work still depends on it.
24. Every lifecycle index renders only its enumerated structured fields. Fixtures containing request-derived narrative, paraphrases, intent summaries, source request bodies, and dispatch brief bodies produce none of that content in the index, including redacted body text.

## Delivery Boundary

Approval of this PRD authorizes only the OpenSpec phase for the lifecycle implementation. It does not authorize runtime implementation. OpenSpec work must use the approved commit and SHA-256 digest of this document, resolve implementation design, repository decomposition, and dependency order without changing these product decisions, and then await a separate `sgt-approve-spec` decision.
