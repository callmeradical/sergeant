# AXI Agent-Ergonomics Research Spike

**Date:** 2026-07-24  
**Decision:** Prefer a hybrid: add native, bounded machine-readable projections to
Sergeant, then expose them through a thin `sgt-axi` compatibility/discovery wrapper.
Do not rewrite lifecycle mutations or replace Sergeant's evidence model.

## Scope and evidence

This read-only spike evaluates Sergeant at local commit
`a6af6854056c77a7a1ed73e61b74cd7fead52e30` against:

- the AXI website and its ten-principle model ([axi.md, "The 10
  principles"](https://axi.md/#the-10-principles));
- the official AXI repository pinned at
  [`d5aa171`](https://github.com/kunchenguid/axi/tree/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f),
  particularly the normative
  [`SKILL.md`](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L16-L247),
  generated-principle source
  [`principles.yaml`](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/principles.yaml#L1-L41),
  browser results
  [`report.md`](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-browser/published-results/report.md#L1-L27),
  and GitHub study
  [`STUDY.md`](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-github/published-results/STUDY.md#L1-L97);
- Sergeant's source, docs, tests, and observed command output in this repository.

Recommendations and expected effects are explicitly labelled; they are not claims
that the AXI benchmark proved the same result for Sergeant.

## Decision summary

Sergeant already has strong agent-safety semantics: registry-resolved ownership,
canonical intent revisions, isolated worktrees, persistent worker state,
generation-bound responses, coordinator-owned validation, and fail-closed cleanup
(`AGENTS.md:1-18,74-113`; `docs/using-sergeant.md:53-76,116-191`). Its main AXI gap
is presentation: bounded one-shot discovery, compact schemas, aggregate readiness,
stable errors, and state-valid next commands are inconsistent or absent
(`bin/sgt-watch:14-45,141-159`; `bin/sgt-validate:22-67`;
`bin/sgt-cleanup:315-468`).

The highest-value change is therefore not TOON by itself. It is a native,
read-only snapshot/preflight layer that computes authoritative state once and
returns a bounded schema. A thin wrapper can then provide TOON, content-first home
views, and compatibility while native mutation commands retain their current
proof checks. This ordering follows AXI's own statement that avoiding a follow-up
call can matter more than shortening one response
([AXI skill lines 58-82](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L58-L82)).

## The ten AXI principles

| # | Principle | Decision-relevant summary | Sergeant posture |
|---:|---|---|---|
| 1 | Token-efficient output | Put compact structured data on stdout; AXI recommends TOON and conversion only at the output boundary ([AXI skill lines 16-26](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L16-L26)). | **Partial.** Most output is concise text, but `sgt-watch --list` is unbounded and historical (`bin/sgt-watch:14-45`). No common machine schema exists across lifecycle commands. |
| 2 | Minimal default schemas | Lists should normally expose only the identifier, title, status, and at most one additional decision field; details belong in a view and optional `--fields` ([AXI skill lines 28-36](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L28-L36)). | **Mixed.** `sgt-td-list` uses five compact columns (`bin/sgt-td-list:148-163`), while fleet discovery emits four lines per retained task plus six counts (`bin/sgt-watch:21-43`). |
| 3 | Content truncation | Preview long content, report total size, and provide `--full`; do not silently omit it ([AXI skill lines 38-56](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L38-L56)). | **Gap.** Watch truncates a brief to 60 characters without a size or escape hatch, but emits complete message, diagnostic, and result bodies (`bin/sgt-watch:23-24,168-192`). |
| 4 | Pre-computed aggregates | Include cheap totals and derived status summaries that prevent a follow-up call ([AXI skill lines 58-82](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L58-L82)). | **Partial.** Fleet and td lists compute counts (`bin/sgt-watch:25-43`; `bin/sgt-td-list:128-171`), but validation and cleanup reveal blockers one at a time (`bin/sgt-validate:22-67`; `bin/sgt-cleanup:360-468`). |
| 5 | Definitive empty states | A successful empty result must say zero with context ([AXI skill lines 84-93](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L84-L93)). | **Mostly compliant.** Project, task, and fleet discovery print explicit no-result text (`bin/sgt-list:37-40`; `bin/sgt-td-list:168-171`; `bin/sgt-watch:14-18`). Missing blocker summaries cannot yet say `blockers: 0`. |
| 6 | Structured errors and exit codes | Mutations should be safely idempotent; errors should be structured, non-interactive, actionable, and distinguish usage errors; unknown input must fail loudly ([AXI skill lines 95-145](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L95-L145)). | **Safety strong, structure weak.** Unknown dispatch options fail (`bin/sgt-dispatch:57-80`) and repeated cleanup can no-op (`bin/sgt-cleanup:34-39`), but errors are prose on stderr with status 1 and `sgt-respond` prompts when stdin is a terminal (`bin/sgt-respond:14-35`). |
| 7 | Ambient context | Install directory-scoped, compact session context only through explicit setup; support multiple harnesses and offer an on-demand generated skill ([AXI skill lines 147-200](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L147-L200)). | **Partial foundation.** `sgt-context` is designed for session orientation (`bin/sgt-context:1-7`) and Sergeant ships skills (`docs/skills.md:1-31`), but there is no explicit compact SessionStart setup and current policy requires multiple discovery commands (`AGENTS.md:74-85`). |
| 8 | Content first | No-argument invocation should show live actionable state rather than a manual ([AXI skill lines 202-216](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L202-L216)). | **Gap at suite level.** Individual commands generally require a project/task and print usage when absent (`bin/sgt-context:15-18`; `bin/sgt-watch:147-150`); there is no `sgt` home view. `sgt-list` itself is content-first (`bin/sgt-list:17-35`). |
| 9 | Contextual disclosure | Add a few complete, state-valid next commands; preserve disambiguating context, parameterize unknown values, and omit suggestions when output is self-contained ([AXI skill lines 218-231](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L218-L231)). | **Inconsistent.** Dispatch prints observe/watch commands (`bin/sgt-dispatch:848-856`), and some errors suggest context (`bin/sgt-dispatch:137-138`), but watch, status, td list, validation, and cleanup do not expose a common state-derived `help[]`. |
| 10 | Consistent help | Identify the executable and purpose in the home view; every subcommand should have concise `--help`, flags/defaults, required arguments, and examples ([AXI skill lines 233-247](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L233-L247)). | **Gap.** Usage is mostly source-header text or argument errors; `--help` is not a universal parsed flag (`bin/sgt-status:1-14`; `bin/sgt-dispatch:7-24,57-80`; `bin/sgt-cleanup:10-22`). |

## Command-by-command map

| Surface | Current compliance and useful behavior | Material gap | Recommended seam |
|---|---|---|---|
| `sgt-context` | Emits authoritative project description, configured path, repository role/status, inherited instructions, groups, and graph availability (`bin/sgt-context:21-143`). This is content-rich and directory-independent. | Markdown prose has no selectable schema or next-action block; instructions can dominate a repeated ambient view. It requires a named project (`bin/sgt-context:15-18`). | Add `--summary --format text|json` with project, repo count, `{name,path,role,git_state}`, graph state, and `help[]`; preserve full context as the default command initially. |
| `sgt-status` | Gives branch, porcelain dirtiness, and upstream divergence for every configured repository (`bin/sgt-status:17-60`). | No aggregate clean/dirty/missing counts, no explicit `ahead: 0/behind: 0`, no machine format, and no suggested remediation. | Add `--summary --format text|json`; return totals and 3-4 fields per repo, with detail/full porcelain opt-in. |
| `sgt-dispatch` | Validates project, options, td ownership, exact coordinator pane, interactive harness, intent, and worktree setup before publishing fleet state (`bin/sgt-dispatch:34-173,217-316,519-708`). It rejects unknown options (`bin/sgt-dispatch:57-80`) and prints task, fleet, tmux, and watch handles after success (`bin/sgt-dispatch:848-856`). | Output mixes progress with result data; no stable success/error envelope or universal help. Dry-run is useful but not a full readiness/preflight object (`bin/sgt-dispatch:11-24,366-405`). | Keep mutation native. Add `--check/--plan --format json` and a final structured receipt. A wrapper may render TOON but must not recreate dispatch logic. |
| `sgt-watch` | Synchronizes worktree/fleet state, detects invalid/dead pane ownership, copies terminal evidence, and renders stage/status/result/diagnostic (`bin/sgt-watch:48-139,159-242`). | `--sync` exits silently after mutation; ordinary watch is indefinite; `--list` scans all retained tasks without active/recent limits; messages are unbounded (`bin/sgt-watch:14-45,141-159,168-192`). Current checkout does not support a bounded `--once` despite coordinator guidance requiring bounded checks when managed background execution is unavailable (`AGENTS.md:86-94`). | Highest priority: native `sgt-watch --snapshot <task> [--repo]`, `--active`, `--recent N`, totals, body size/path hints, health/progress evidence, and state-valid `help[]`. |
| `sgt-respond` | Reads the decision into a mode-0600 temporary file, validates task/repo, owner/worktree/intent/generation, atomically publishes, and binds worker resume (`bin/sgt-respond:16-50,61-202,227-375`). | Interactive stdin emits a prompt; errors are first-failure prose and do not classify stale generation, ownership mismatch, or retryability (`bin/sgt-respond:14-35`). | Preserve stdin and every proof. Add `--check`, stable error codes, and a receipt containing response ID/generation, delivery state, and exact acknowledgement command. Never print the body. |
| `sgt-validate` | Requires matching canonical intent, reviewed current HEAD, clean tree, exact coordinator/worker pane identities, and an isolated snapshot before validation (`bin/sgt-validate:22-67,176-261`). | First-failure guards force repeated attempts to discover independent blockers; no read-only preflight or stable blocker taxonomy. | Native `sgt-validate --check <task> <repo>` returning all checks and `blockers[n]`; execution reruns guards and treats preflight as non-authoritative. |
| `sgt-cleanup` | Rejects path/symlink aliases, no-ops if already removed, verifies terminal reconciliation, response convergence, process/worktree ownership, dirtiness, and replay evidence before removal (`bin/sgt-cleanup:22-43,315-468,504-653`). | Destructive scope and all blockers are not previewable together; first-failure output encourages retry loops. | Native `sgt-cleanup --check/--plan <task> [repo]`; list blockers and exact resources, but provide no capability token and no `--force`. Execution must recheck. |
| Fleet discovery | `sgt-watch --list` gives task identity, shortened brief, start time, and per-state repo totals; empty fleet is explicit (`bin/sgt-watch:14-45`). | It labels all retained history "Active tasks," has no total, filters, limit, truncation metadata, or detail command. The observed output was 84,978 bytes/1,846 lines on 2026-07-24. | Make active/recent bounded content the default home projection; expose `count`, `shown`, state totals, and `--all/--full`. Retain exact fleet evidence on disk. |
| Task discovery | `sgt-td-list` supports status/priority/repo filters and JSON, computes per-repo and total counts, and gives an explicit empty state (`bin/sgt-td-list:7-14,33-64,79-171`). | Human output has five fields rather than AXI's typical 3-4; JSON returns the underlying broad td objects rather than a minimal contract; unknown arguments are forwarded instead of rejected locally (`bin/sgt-td-list:42-50,83-120`). | Add minimal default JSON/TOON projection, explicit `--fields`, strict known-flag validation, and `help[]` for view/start/context. |
| Project discovery | `sgt-list` is content-first and emits registered names/descriptions (`bin/sgt-list:17-35`). | No count, executable identity, contextual next command, machine format, or definitive success-zero state; an empty registry exits 1 (`bin/sgt-list:37-40`). | Use it as the `sgt`/`sgt-axi` home base: executable, purpose, project count, current uniquely resolved project if any, and parameterized context/status commands. |

## Measured baseline

These are reproducible point measurements from the current checkout on
2026-07-24. Bytes include the final newline. Approximate tokens use
`ceil(bytes/4)` only as a screening estimate, not a model tokenizer. Wall time is
one warm local invocation and should be replaced by repeated median/p95 runs in
the benchmark harness.

| Command | Output bytes | Lines | Approx. tokens | Wall time |
|---|---:|---:|---:|---:|
| `sgt-context sergeant` | 790 | 20 | 198 | 77 ms |
| `sgt-status sergeant` | 166 | 5 | 42 | 42 ms |
| `sgt-td-list sergeant` | 4,575 | 55 | 1,144 | 399 ms |
| `sgt-list` | 679 | 6 | 170 | not sampled |
| `sgt-watch --list` | 84,978 | 1,846 | 21,245 | 2,268 ms |

The byte growth mechanism is directly visible in the implementation: fleet list
iterates every directory and emits a four-line record, with no limit or state
filter (`bin/sgt-watch:21-44`). The numbers are environment snapshots, not claims
about every Sergeant installation.

Agent-level turns, exact tokenizer counts, task success, and recovery success have
not previously been instrumented for Sergeant; inventing values would make the
decision less reliable. Phase 0 therefore treats the following as mandatory
baseline outputs before implementation rather than silently assuming current
performance:

| Metric | Baseline method | Required comparison |
|---|---|---|
| Tokens | Capture exact harness input/output tokens for every trajectory; retain command bytes above as the independently reproducible lower-level measure. | Report median/p95 by journey and condition; do not substitute `bytes/4` in the adoption decision. |
| Turns | Count agent tool invocations and Sergeant commands from prompt to correct terminal answer/action. The documented orientation path already names three commands: context, task queue, and mode selection (`AGENTS.md:74-85`). | Compare identical prompts and fixed fleet fixtures, at least five repeats per condition. |
| Wall time | Monotonic prompt-to-answer timing plus per-command timing; retain the point samples above for smoke comparison. | Report median/p95; separate agent time from command time. |
| Success rate | Binary rubric for correct state classification and allowed next action; separately score task completion. | AXI-like change must be non-inferior to native baseline with 95% confidence or pass all deterministic cases. |
| Recovery rate | Inject stale generation, dead pane, interrupted response publication, dirty worktree, and partial cleanup; score convergence to the same authorized state without lost evidence. The relevant recovery boundaries are implemented in `bin/sgt-watch:80-139`, `bin/sgt-respond:227-375`, and `bin/sgt-cleanup:315-653`. | No recovery-rate regression and zero unauthorized transitions, provenance loss, or body disclosure. |

## Prioritized opportunities

| Rank | Opportunity | Impact | Effort | Risk | Acceptance target |
|---:|---|---|---|---|---|
| 1 | Native bounded fleet/task snapshot and active/recent discovery | Very high | Medium | Low | `sgt-watch --snapshot` completes once; default fleet discovery is under 8 KiB and reports total/shown counts; correct-next-action rate is at least baseline with no status misclassification. |
| 2 | Native validation and cleanup preflights | High | Medium | Low | One call returns every blocker and `blockers: 0`; execution reruns all guards; no new destructive bypass exists. |
| 3 | Stable structured errors plus state-valid `help[]` | High | Medium | Medium | Usage, stale state, ownership mismatch, waiting, partial publication, dirty tree, and missing dependency are distinguishable without parsing prose; unknown flags exit 2. |
| 4 | Minimal receipts for dispatch/respond | High | Medium | Medium | Success output exposes canonical task/repo/intent/generation/next-command handles while bodies remain private; progress moves to stderr. |
| 5 | Strict, minimal task/project discovery | Medium | Low/medium | Low | Default list schema is 3-4 fields, `--fields` expands it, empty state is explicit, and unrecognized flags fail locally. |
| 6 | Opt-in ambient home plus generated skill | Medium | Medium | Medium | Setup is explicit/idempotent, unique registry resolution is required, per-session context is capped, and static skill/help drift is checked. AXI requires these properties ([AXI skill lines 147-200](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L147-L200)). |
| 7 | TOON rendering and `sgt-axi` compatibility facade | Medium | Low after schemas exist | Low/medium | TOON is generated only at the output boundary; native JSON remains the contract; measured tokens improve without changing lifecycle outcomes. |
| 8 | Shared native output refactor across every command | Potentially high | High | High | Defer until schemas and consumers are measured; current Bash 3.2 runtime constraint is explicit (`mise.toml:1-2,75-165`). |

## What not to adopt

1. **Do not replace compound provenance with an opaque AXI session ID.** Response
   and cleanup safety depend on configured repository ownership, worktree pointer,
   branch, intent revision, pane/process identity, lease, ID, and generation
   (`bin/sgt-respond:61-202`; `bin/sgt-cleanup:138-305`). A short handle may project
   those facts but cannot become their authority.
2. **Do not combine actions across approval/evidence boundaries.** AXI browser
   gains partly come from combined operations ([axi.md, trajectory
   findings](https://axi.md/#findings)), but Sergeant must keep decision delivery,
   application, acknowledgement, review, validation, and cleanup as separately
   proven transitions (`docs/using-sergeant.md:116-191`).
3. **Do not interpret idempotency as overwrite or force.** Cleanup's existing
   already-removed no-op is safe (`bin/sgt-cleanup:34-39`); replacing intent,
   response generation, owner evidence, or preserved work is not. No proposal
   should add `--force`.
4. **Do not let ambient context mutate or infer ownership from the directory.**
   Project ownership must come from `sgt-context` registry resolution
   (`AGENTS.md:1-3,74-85`). An ambiguous home view must show candidates and stop.
5. **Do not truncate authoritative evidence.** Bound display previews, but retain
   full intent, response, blocker, review, validation, and cleanup evidence. AXI's
   truncation principle itself requires a full escape hatch and total-size signal
   ([AXI skill lines 38-56](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L38-L56)).
6. **Do not expose response/intent bodies in TOON, errors, hooks, argv, td, or wiki
   summaries.** `sgt-respond` deliberately uses private stdin/file transport
   (`bin/sgt-respond:16-35`); ergonomic projections should contain only safe
   metadata and protected paths.
7. **Do not copy AXI's stdout-error rule blindly.** AXI reserves stdout for
   structured agent-consumed errors and stderr for diagnostics
   ([AXI skill lines 106-145](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/.agents/skills/axi/SKILL.md#L106-L145)).
   Sergeant should first inventory shell consumers and offer an explicit format;
   changing channels globally could break safety automation.
8. **Do not treat AXI's benchmark results as Sergeant effect sizes.** The browser
   benchmark used 490 runs and one model, and notes schema/cold-start limitations
   ([browser report lines 5-27](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-browser/published-results/report.md#L5-L27));
   the GitHub study used 425 read/API-oriented runs and an LLM judge
   ([GitHub study lines 3-21,81-97](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-github/published-results/STUDY.md#L3-L21)).
   Sergeant needs lifecycle and recovery tasks with safety-violation scoring.

## Incremental implementation and benchmark plan

### Phase 0: Freeze baselines and schemas

Build a read-only harness around six journeys: orientation; clean/dirty status;
dispatch plan/success receipt; healthy/stalled/waiting/blocked fleet discovery;
response delivery/recovery; validation and cleanup rejection/success. Pin fleet
fixtures and command commit. Record raw stdout/stderr separately and retain exact
trajectories.

For each journey and condition, collect:

- exact input/output tokens from the agent harness, plus command stdout/stderr
  bytes;
- agent tool turns and Sergeant command invocations;
- wall time (median and p95 across at least five repeats);
- task success and **correct next action** on the first attempt;
- recovery success after stale generation, dead pane, interrupted publication,
  dirty worktree, and partial cleanup;
- false-health, unauthorized-transition, provenance-loss, and secret-exposure
  counts, all of which must remain zero.

The AXI studies use success, cost/tokens, duration, and turns and repeat each
condition/task five times
([browser report lines 5-21](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-browser/published-results/report.md#L5-L21);
[GitHub study lines 23-31,81-87](https://github.com/kunchenguid/axi/blob/d5aa171665bb784d0f1b05150aaeb0f3e1b52b2f/bench-github/published-results/STUDY.md#L23-L31)).
Sergeant adds recovery and safety rates because its domain includes destructive
and provenance-sensitive transitions (`bin/sgt-cleanup:315-653`).

### Phase 1: Native read-only projections

Implement test-first `sgt-watch --snapshot`, bounded `--active/--recent`,
`sgt-validate --check`, and `sgt-cleanup --check`. Reuse pure guard functions so
preflight and execution inspect the same facts. Initial targets:

- fleet discovery under 8 KiB by default versus the observed 84,978 bytes;
- one command turn to classify each task and enumerate all blockers;
- 100% correct next action on deterministic fixtures;
- zero state mutation from snapshot/check commands;
- zero regression in existing shell tests.

### Phase 2: Error and receipt contracts

Add opt-in JSON with stable `error.code`, `retryable`, IDs, state, and `help[]`;
add compact receipts to dispatch/respond. Test stale, wrong-owner, wrong-pane,
partial-publication, and already-converged cases. Target at least a 30% reduction
in recovery turns with unchanged recovery success and zero safety violations.

### Phase 3: Thin `sgt-axi` facade and ambient setup

Render the native schemas as TOON/content-first views, add executable identity and
concise help, and offer explicit hook/skill setup. Do not call filesystem internals
directly from the wrapper. Compare native JSON, compact native text, and TOON using
the same tasks; keep TOON only if exact tokenizer counts improve at equal success.
Cap ambient context at 2 KiB initially and require unique registry resolution.

### Phase 4: Decide migration scope

Only after benchmark evidence, inventory consumers of exact text and decide which
native defaults can change. Promote a format when it meets all of these gates:

- success and recovery rates are no worse than baseline;
- safety/provenance/privacy violations remain zero;
- median agent tokens or command-output bytes improve by at least 25%;
- median turns improve by at least one on multi-step journeys;
- median/p95 wall time do not regress by more than 10%;
- Bash 3.2 and repository-native tests remain green (`mise.toml:1-2,75-165`).

## Wrapper versus native refactor

| Option | Advantages | Problems | Verdict |
|---|---|---|---|
| Standalone `sgt-axi` wrapper only | Fast experimentation; no immediate text compatibility break; TOON/home/help can evolve independently. | A wrapper that parses current prose or reads fleet files would duplicate lifecycle interpretation and can drift from native guards (`bin/sgt-watch:80-139`; `bin/sgt-cleanup:315-468`). | **Reject as the final architecture.** Accept only as a renderer over native schemas. |
| Native output refactor only | One source of truth; every caller gets structured state. | Large compatibility surface, mixed progress/data channels, Bash portability cost, and high risk if all mutations change together (`bin/sgt-dispatch:34-173`; `mise.toml:1-2`). | **Do not start here.** Incremental native additions are preferable to a global rewrite. |
| Hybrid | Native commands own state, guards, snapshots, preflights, and receipts; a thin wrapper owns TOON, content-first home, contextual discovery, and migration compatibility. | Requires schema discipline and drift tests between native JSON and wrapper rendering. | **Preferred.** It improves ergonomics without creating a second authority or forcing an unsafe flag-day migration. |

## Final recommendation

Adopt AXI's semantic principles, not its presentation choices indiscriminately.
Start with native bounded snapshots and all-blocker preflights, then stable errors
and receipts. Build `sgt-axi` only as a thin renderer/discovery layer over those
native contracts. Preserve every existing intent, owner, generation, pane,
validation, and cleanup proof; keep protected bodies out of agent-visible output;
and require Sergeant-specific benchmark evidence before changing defaults.
