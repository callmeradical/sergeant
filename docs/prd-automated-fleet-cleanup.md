# Product Requirements: Automated Fleet Cleanup

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, section 7 (quality and acceptance gates)

## Summary

Every dispatch creates an isolated worktree under sergeant's fleet
directory. Reclaiming that space today requires a human to remember to
call the existing manual cleanup action — nothing does this on its own.
Fleet directories for runs that finished (or died) days or weeks ago sit
on disk indefinitely until someone thinks to ask for them to be removed.
This PRD makes reclaiming old, terminal work automatic.

## Problem

A dispatch's worktree exists to serve that one run. Once a run reaches a
terminal outcome — passed, failed, cancelled, or interrupted — and enough
time has passed that nobody is actively still working from it, the
worktree has no further reason to occupy disk space. Today nothing
reclaims it automatically: the existing cleanup action is a manual,
on-demand call, and an operator who never happens to invoke it accumulates
fleet directories forever. This is pure operational drag with no
corresponding benefit — it is not a retention policy anyone chose, just an
absence of one.

## Proposal

Sergeant must periodically and automatically reclaim the fleet worktree of
any run that has been in a terminal state for longer than a fixed
retention window (seven days), with no human action required to trigger
it.

This reuses, rather than relaxes, the safety properties the existing
manual cleanup action already establishes: a run that is still `running`
is never touched, and a worktree containing uncommitted changes is never
removed automatically, regardless of how long it has sat there — automated
cleanup can reclaim disk space, but it must never be the reason committed-
nowhere-else agent output is lost. When a run's terminal status cannot be
determined with confidence, the safe default is to leave it alone and
reclaim it on a later pass, not to guess and delete.

## Out of scope

- **Deleting or retention-limiting database rows** (runs, phases,
  envelopes, intents, bullets). This PRD only reclaims the on-disk fleet
  worktree; the durable audit record stays exactly as durable as it is
  today. Database retention policy is R4.4's already-disclosed, still-open
  decision ("Product design must define redaction and retention before
  production release") — this PRD does not resolve it and does not expand
  its scope.
- **A configurable retention period.** Seven days is a fixed constant, not
  an operator-tunable setting, matching this project's existing preference
  for fixed constants over configuration knobs where a single sane default
  serves a single-user, local-first tool.
- **Reclaiming anything the existing manual action would also refuse to
  reclaim** (a running run, a dirty worktree). Automatic cleanup is
  strictly a scheduling change on top of the same safety rules, not a
  relaxation of them.
- **A UI or notification surface for what got cleaned.** The manual
  cleanup action's existing response shape (removed/skipped) is sufficient
  evidence; this PRD does not add a dashboard view of cleanup history.

## Open questions

None blocking.
