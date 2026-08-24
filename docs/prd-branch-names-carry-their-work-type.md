# Product Requirements: Branch Names Carry Their Work Type

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, decision O2

## Summary

O2 already specifies that a dispatch's branch should be named `<type>/<change-id>`,
preserving the conventional-commit prefix (`feat/`, `fix/`, ...) this project's
own commit messages already use. This was never implemented: every dispatched
branch today is named `sergeant/<run-id>`, carrying no information about what
kind of change it is and not even naming the change it belongs to. This PRD
closes that gap.

## Problem

Today, a dispatched branch's name is a bare identifier — it says nothing about
whether the work is a new feature, a bug fix, a refactor, or something else,
and nothing about which OpenSpec change it serves. An operator (or, later, any
reporting built on top of this data — e.g. "what kind of work got shipped this
week, by which agent") has no honest signal to read this from. The only place
this information exists at all today is inside individual commit messages,
authored inconsistently by whichever agent happened to write them, not
recorded as a structured fact anywhere sergeant itself tracks.

This also leaves O2's own "convenience" audit leg (the branch name) unbuilt:
today it names neither the change nor the type, so an operator scanning
branches to spot-check work has nothing to go on beyond a run id.

## Requirements

1. A dispatch must state what type of work it is, from a fixed, named set
   matching this project's own conventional-commit vocabulary (`feat`, `fix`,
   `refactor`, `docs`, `chore`, `test`). This must be an explicit statement,
   not a guess inferred from the brief text or the diff after the fact —
   guessing what kind of change something is is exactly the kind of silent
   inference this project's other decisions (D2) already refuse to make
   without a human or an explicit input behind it.
2. A dispatch that does not state a recognized type is refused before any
   work begins, the same way a dispatch with an unresolvable OpenSpec change
   is refused today — a wrong or defaulted type is worse than no type, since
   a default silently becomes false data instead of visibly missing data.
3. The dispatched branch's name must reflect both the stated type and the
   OpenSpec change it serves, per O2's `<type>/<change-id>` convention —
   replacing today's type-less, change-less branch name.
4. This is a durable, structured fact about the work, not merely cosmetic
   branch-naming — it must be recorded somewhere queryable, so it can answer
   "what kind of work happened" without parsing branch names or commit
   messages after the fact.

## Non-goals

- **An analytics/reporting page presenting this data.** This PRD only makes
  the work-type an honest, recorded fact; a view built on top of it (by
  agent, by type, over time) is separate, later scope.
- **Reclassifying or renaming historical branches/runs.** This changes what
  gets recorded going forward; it does not touch or reinterpret history.
- **Enforcing the type vocabulary in commit messages.** Agents already tend
  to write conventional-commit-style messages on their own; this PRD does
  not add new enforcement there, only for the dispatch-level classification.
- **A type taxonomy beyond the fixed six** (no sub-categories, no free-text
  type, no per-project customization of the vocabulary).

## Open questions

None blocking.
