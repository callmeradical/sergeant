#!/usr/bin/env bash
# _sgt-review-axes.sh — Canonical independent-review axis vocabulary.
#
# ONE definition drives both halves of the independent-review contract:
#   * the axes bin/sgt-dispatch instructs a worker to produce, and
#   * the axes bin/sgt-review-findings accepts for routing.
# Previously the two were written out separately and drifted: dispatch mandated a
# readiness review the router rejected outright, so workers hand-created cards
# instead of routing them (td-61a0c8).
#
# Source this file; do not execute it directly.
#
# Space-separated strings rather than arrays: Apple Bash 3.2 errors on
# "${empty[@]}" under `set -u`, and every sgt-* script runs with `set -u`.

[[ "${SGT_REVIEW_AXES_LOADED:-}" == "1" ]] && return 0
SGT_REVIEW_AXES_LOADED=1

# Axes every dispatched worker must produce and route.
SGT_REVIEW_AXES_REQUIRED="standards spec readiness"
# Axes demanded only when the dispatch context is UI-facing.
SGT_REVIEW_AXES_CONDITIONAL="accessibility"

# Every axis the router accepts, required first then conditional.
_sgt_review_axes() {
  printf '%s %s\n' "$SGT_REVIEW_AXES_REQUIRED" "$SGT_REVIEW_AXES_CONDITIONAL"
}

# ERE alternation over the full axis vocabulary, anchored for direct use in [[ =~ ]].
_sgt_review_axis_pattern() {
  local axis pattern=""
  # shellcheck disable=SC2046  # deliberate word splitting over the axis list
  for axis in $(_sgt_review_axes); do
    pattern="${pattern:+$pattern|}$axis"
  done
  printf '^(%s)$\n' "$pattern"
}

_sgt_review_axis_valid() {
  local candidate="$1" axis
  # shellcheck disable=SC2046  # deliberate word splitting over the axis list
  for axis in $(_sgt_review_axes); do
    [[ "$candidate" == "$axis" ]] && return 0
  done
  return 1
}

# Reviewer guidance for one axis, as the markdown bullet the dispatch-generated
# brief publishes. An axis without guidance is a contract gap, so this fails
# rather than silently emitting an unexplained axis.
_sgt_review_axis_guidance() {
  case "$1" in
    standards)
      printf '%s' '- **Standards axis:** Review the diff versus the pinned merge-base against active repo instructions, AGENTS, CONTRIBUTING, and coding standards. Add a concise Fowler smell heuristic (duplication, long functions/modules, large parameter lists, feature envy, data clumps, primitive obsession, shotgun surgery, and inappropriate intimacy). Separate hard documented-standard violations from judgement-call smells, and skip findings enforced by tooling.'
      ;;
    spec)
      printf '%s' '- **Spec axis:** Review against the originating td issue/spec/mission. Report missing or partial requirements, scope creep, and incorrectly implemented requirements. If no spec exists, report this axis as skipped/no spec.'
      ;;
    readiness)
      printf '%s' '- **Readiness axis:** Review the diff versus the pinned merge-base for mutation before validation, partial publication and rollback, identity and provenance, stale and legacy states, suppressed failures, race windows, and missing negative tests. Record evidence against the canonical intent.'
      ;;
    accessibility)
      printf '%s' '- **Accessibility axis:** Because this is UI-facing work, launch a separate independent accessibility review covering keyboard access, semantics, focus behavior, contrast, responsive behavior, and assistive-technology compatibility as applicable.'
      ;;
    *) return 1 ;;
  esac
}

# English count word for the axis-count heading, e.g. "three-axis review".
_sgt_review_axis_count_word() {
  case "$1" in
    1) printf 'one' ;;
    2) printf 'two' ;;
    3) printf 'three' ;;
    4) printf 'four' ;;
    5) printf 'five' ;;
    *) printf '%s' "$1" ;;
  esac
}
