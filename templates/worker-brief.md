# Sergeant Brief

**Task ID:** {{TASK_ID}}
**Project:** {{PROJECT}}
**Repo:** {{REPO_NAME}}
**Branch:** {{BRANCH}}
**Worktree:** {{WORKTREE_PATH}}
**Fleet state:** {{REPO_TASK_DIR}}/
{{TD_TASK_LINE}}

---

## Mission

{{BRIEF}}

This agent is responsible for the **{{REPO_NAME}}** repo only.
{{ROLE_LINE}}

{{DEPS_SECTION}}
{{TD_SECTION}}

## Active instructions

{{MERGED_INSTRUCTIONS}}

---

## Deliver

Follow these gates in order. Preserve the evidence in the PR description or a linked review artifact.

### 1. Pin scope and source of truth

Before implementation, fetch refs and pin the fixed point, normally the merge-base with the current origin/main. Record the base SHA, commit list and diff scope; if that base is unavailable, record the explicit alternative.

Identify the originating spec from the full td task context, this Sergeant mission, and any referenced issue, PRD, spec, or ADR. If no originating spec exists, record that explicitly.

.sergeant-intent.md is the canonical source for implementation decisions, independent reviews, PR description, and the one final no-mistakes --intent. Intent revision: {{INTENT_REVISION}}. Successor and recovery work must inherit this exact revision. Do not silently regenerate it; only an audited human decision creates a new intent revision.

### 2. Route the work

Triage context and readiness before choosing an implementation loop: read the full td issue/spec/comments and linked material, check for redundant or prior work, identify the work category, and record whether it is ready.

- **Huge or foggy:** Surface a wayfinding/spec/ticketing blocker with the missing decisions. Surface `wayfinder`, `to-spec`, and Sergeant's custom `to-tickets` as escalation or planning paths. Do not silently execute them as implementation or invent the route.
- **Hard bug or performance regression:** When available, load and use the canonical `diagnosing-bugs` skill. First establish one fast deterministic red-capable command. Reproduce and minimise, rank falsifiable hypotheses, instrument one variable at a time, then turn the minimal reproduction into a regression test before fixing it.
- **Uncertain state, design, or UI:** When available, load and use the canonical `prototype` skill. Create a clearly throwaway prototype, surface it for human-in-the-loop feedback, and never promote prototype code directly. Discard it and implement the approved direction through the normal TDD path.
- **Approved feature or fix:** When available, load and use the canonical `tdd` skill before implementation. Implement tracer-bullet vertical slices with TDD.
- **Merge or rebase conflict:** When available, load and use the canonical `resolving-merge-conflicts` skill. Trace both intents to their issues/specs, preserve both where possible, and never abort automatically. Escalate when intent cannot be reconciled.

If a canonical skill cannot be loaded, follow the embedded rules in this brief for that phase.

### 3. Implement approved work with TDD

Establish public behavioral seams before writing tests. Use seams already specified by td/spec; if a consequential seam is genuinely undecided, surface needs_input rather than guessing.

For safety-sensitive or stateful work, implementation is blocked unless the canonical intent has concrete State Transitions, Failure Windows, and Negative Test Matrix sections supplied through the explicit readiness path. Publish needs_input when any is missing. The named standard-isolated lighter path applies only when the objective does not trigger Sergeant's safety/stateful classifier.

For each non-trivial behavior, work red before green: one vertical slice, test, and minimum implementation at a time. Run the failing focused test for the right reason, add only enough implementation to pass, then refactor after green. Reject tautological tests, internal mocking, and horizontal slicing such as writing all tests before all implementation. Scrutinize refactoring during review. Do not speculate ahead.

### 4. Escalate and resume

Your worker runs as a persistent interactive agent session in its recorded tmux pane. Non-interactive agent modes are prohibited: do not launch `opencode run`, `goose run`, Claude print mode, `--auto`, `--prompt`, or an equivalent one-shot agent. Sergeant delivers only a fixed ID-bearing notification through interactive terminal input; prompt, response, and secret bodies remain in durable files and never appear in process arguments.

For every Sergeant notification, read `.sergeant-notification` and copy the exact supervisor-scoped token from the nudge (`notification_id|target_nonce`) to the named file under `.sergeant-notification-acks/`. Do not act until that supervisor sends acceptance and the named file under `.sergeant-notification-accepts/` contains the same token. Then follow the instruction exactly once and write the token to the named file under `.sergeant-notification-complete/`. Repeated nudges with the same token are retries, not new work.

If an agent exits before a terminal or waiting state, the supervisor records `orphaned` with durable diagnostics and td recovery pointers. Resume orphaned work through `sgt-respond`; do not overwrite or discard its recovery state.

When Sergeant notifies you of a response, read `.sergeant-response`, `.sergeant-response-id`, and `.sergeant-response-generation`; apply the approved decision once and restore `.sergeant-status` to `in_progress`, a terminal state, or a later gate generation. Write `.sergeant-response-applied` with exactly one `response_id`, `gate_generation`, and matching `status`, then run `sgt-ack-response {{TASK_ID}} {{REPO_NAME}} "$(cat .sergeant-response-id)"` from this exact worker pane. Do not clear, replay, or acknowledge a response by hand; the command validates pane ownership and proof, publishes retryable archive and acknowledgement state, and clears plaintext transport only after that state converges.

Completion requires both .sergeant-status=done and a non-empty .sergeant-result; a PR or successful turn alone is not terminal completion.

Supported nonterminal statuses are `in_progress`, `needs_input`, `blocked`, and `waiting`; terminal statuses are `done` and `failed: <reason>`.

Do not use sleep or polling loops for deferred work such as CI checks, dependency completion, or time-based delays. Use the `waiting` status with a structured wake condition instead: write `.sergeant-wake-condition` with a supported `kind` and the required fields, set `.sergeant-status=waiting`, then exit the session cleanly. The Sergeant scheduler (`sgt-wake`) evaluates the condition and resumes the session automatically when it is met.

Supported wake condition kinds and their required fields:

```
kind=not_before        not_before=<unix_timestamp>
kind=github_check      run_id=<id> check_name=<name>
kind=fleet_dependency  task_id=<id> repo=<repo>
kind=td_dependency     td_task_id=<id>
kind=deployment        app=<name> env=<name>
kind=human_response    (sets needs_input; requires manual sgt-respond)
```

Optional fields on any kind: `deadline=<unix_timestamp>` (terminal failure if exceeded), `max_attempts=<int>` (becomes needs_input if exceeded), and `backoff_base=<seconds>` (base retry backoff before jitter). Required field on all conditions: `generation=<int>`. Do not persist arbitrary shell commands, prompt bodies, response text, tokens, or secrets in `.sergeant-wake-condition`; only the above allowlisted field names and alphanumeric-safe values are accepted.

For `needs_input` or `blocked`, write `.sergeant-message` with concise context, evidence, the exact question or blocker, a recommendation, and 2-4 options when useful. Call `sgt-notify {{TASK_ID}} "needs_input [{{REPO_NAME}}]: <summary>"` or the equivalent `blocked` message. The worker remains alive and waits for a response; do not exit or mark the task failed.

When `.sergeant-response` appears, follow the post-application proof and `sgt-ack-response` protocol above. Valid proof is `in_progress` after applying the decision, `done` with a non-empty result, `failed: <nonblank reason>`, or a later `needs_input`/`blocked` gate generation. Unexpected exit or invalid proof retains active transport, while successful acknowledgement archives replay evidence before clearing it. Clear `.sergeant-message`, log the decision to td when tracked, and continue only when a consequential question is answered.

Maintain `.sergeant-gate-generation` as a monotonic integer for waiting gates. Before every new `needs_input` or `blocked` publication, increment the generation and persist it before writing the waiting status and message. A repeated blocker message is still a new gate only when the generation advances.

### 5. Validate

Run focused tests and typechecking/lint regularly. Run the repository's full required suite once at the end.

Before the final shipping boundary, launch and route the readiness axis defined in step 7, and record its evidence against the canonical intent.

Commit the reviewed branch before publishing readiness. Validation requires a clean worktree at that committed HEAD; do not create readiness evidence from an uncommitted diff.

Never run no-mistakes from this agent process. After implementation, repository-native validation, and independent reviews complete with zero blockers, write `.sergeant-validation-ready` with exactly one `intent_revision={{INTENT_REVISION}}`, the current `head_sha=$(git rev-parse HEAD)`, and `standards_review=passed`, `spec_review=passed`, and `readiness_review=passed`. Then notify Sergeant that coordinator-owned validation may begin.

The coordinator invokes `sgt-validate {{TASK_ID}} {{REPO_NAME}}`, which runs no-mistakes interactively in a split pane of this window with the canonical intent and without `--yes`. The validation run is read-only; actionable findings become separate td work.

### 6. Route no-mistakes findings

The Sergeant coordinator owns every no-mistakes gate and finding. Do not approve a validation gate, route a finding, or remediate validation output from this worker pane. Actionable findings become separate deduplicated td work and remediation never runs no-mistakes. Resume this worker only through an explicit Sergeant response tied to that owning work.

### 7. Independent {{REVIEW_AXIS_LABEL}}-axis review

Before completion, load and use the canonical `code-review` skill when available for its review technique, then launch separate parallel subagents for these axes so their contexts cannot contaminate each other. The axis list below is authoritative: run every axis named here even when that skill describes fewer. Keep their output in separate sections. Do not blend or rerank the axes. If the skill cannot be loaded, use the embedded review rules below.

{{REVIEW_AXIS_MARKDOWN}}
Require each reviewer to return a structured JSON finding artifact with only: `findings`, and per finding `id`, `severity`, `disposition`, `summary`, `evidence`, `paths`, `acceptance_criteria`, and `recommendation`. Set `severity` to one of the canonical values `{{REVIEW_SEVERITIES}}`; the router also accepts and normalizes these reviewer spellings: {{REVIEW_SEVERITY_ALIAS_TABLE}}. Only the `error` family publishes a blocking gate, so reserve it for must-fix findings; `warning` and `info` route as reviewable debt. Route each axis separately with `sgt-review-findings {{PROJECT}} {{REPO_NAME}} --axis <{{REVIEW_AXES_PIPE}}>`, passing the artifact, axis/source, branch/head, parent td mission, fleet task ID, and worktree. The router deduplicates actionable findings into owning-repository td tasks, publishes blocking state and notification, and prints task IDs and recommended remediation. Cosmetic and false-positive dispositions create no cards. Never pass review bodies, prompts, secrets, or credentials into the artifact, td, or fleet metadata. Treat malformed output or routing failure as blocked; do not continue or leave findings only in worker.log.

### 8. Remediate and repeat

Remediate every blocking repository-native test or independent-review finding, rerun affected tests, then rerun all required independent review axes. Repeat until blocking findings are zero on each axis. Do not remediate no-mistakes findings in this validation run; their owning td work requires a separate dispatch.

### 9. Complete delivery and td lifecycle

The branch was committed before readiness. Open the PR via `gh pr create`. If this work has a td task, log decisions throughout, handoff before td review, and run td review only after implementation and review evidence is ready.

Do not write `done` merely because a PR exists. Success requires: the branch is committed; the PR is open; focused and full validation are complete; required CI is green; there are no unresolved non-outdated review threads; dependency order is satisfied; and independent review is complete with zero blocking findings.

While waiting for CI, reviews, or dependencies that fit a supported wake condition, publish `.sergeant-status=waiting` with `.sergeant-wake-condition` instead of sleeping or polling in-process. Use `needs_input` for human decisions, `blocked` for durable external blockers without a supported wake adapter, and `failed: <exact reason>` only for unrecoverable terminal failure. Only after every success gate passes:

1. Write the PR URL: `echo "https://github.com/..." > .sergeant-result`
2. Write `echo "done" > .sergeant-status`
3. Notify: `sgt-notify {{TASK_ID}} "done: PR https://github.com/..."`

For failure, notify with `sgt-notify {{TASK_ID}} "failed: <exact blocker>"`.

The primary sergeant session is watching via `sgt-watch {{TASK_ID}} --background`.
