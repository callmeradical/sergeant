# Product Requirements: Graphify `exclude_patterns` Is Honored

Status: Draft, awaiting explicit human PRD approval

Extends: `docs/prd-sergeant-v2.md`, decision D9

## Summary

D9's `graphify:` project configuration declares `output`, `include_groups`,
and `exclude_patterns`. `include_groups` works. `exclude_patterns` is
accepted in configuration and silently does nothing — a project owner can
declare it, save it, see no error, and get a graph that still contains
everything they meant to exclude.

## Problem

A project's code graph is meant to represent the code worth navigating by.
Generated files, vendored/third-party code, and other noise a project owner
has explicitly named should not appear in it — that is the entire purpose
of a file-pattern exclude list. Today that declared intent is discarded: the
graph sergeant builds and publishes contains every file from every
participating repository regardless of what `exclude_patterns` says,
because nothing reads it. A project owner has no way to keep noise out of
their graph short of restructuring which repositories/groups participate at
all (the coarser `include_groups` filter), which is not the granularity the
field promises.

## Requirements

1. A file matching a configured exclude pattern must not appear in the
   published graph, regardless of which participating repository it came
   from.
2. Anything in the graph that exists only to describe an excluded file's
   relationships (an edge or grouping that has nothing left to connect once
   the excluded file is gone) must not appear either — an excluded file
   must disappear cleanly, not leave orphaned references behind.
3. Exclude patterns must support matching a whole directory and its
   contents (e.g. "everything under this path"), not only exact file names
   — this is table stakes for the kind of noise this field exists to filter
   (vendored dependencies, generated output directories).
4. A project with no exclude patterns configured must see no change in its
   published graph. This is a correctness requirement on the fix itself,
   not just a description of the default.
5. This filtering must not depend on or require any change to the
   third-party graph-building tool sergeant orchestrates (D9) — it applies
   to what that tool already produces.

## Non-goals

- **Reconciling or unifying `include_groups` and `exclude_patterns`.** They
  remain two independent filters — one by repository grouping, one by file
  path — and this PRD does not change that relationship.
- **Excluding by anything other than file path** (node type, language,
  confidence, etc.). This field filters by path, matching what it is named.
- **Any change to the externally maintained graph-building tool itself.**

## Open questions

None blocking.
