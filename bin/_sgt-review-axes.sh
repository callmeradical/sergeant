#!/usr/bin/env bash
# _sgt-review-axes.sh — Canonical independent-review axis and severity vocabulary.
#
# ONE definition drives both halves of the independent-review contract:
#   * the axes and severities bin/sgt-dispatch instructs a worker to produce, and
#   * the axes and severities bin/sgt-review-findings accepts for routing.
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

# ── Severity vocabulary ───────────────────────────────────────────────────────
#
# Owner decision on td-61a0c8 (Option A): the canonical set is error|warning|info
# and `informational` is no longer a first-class severity. The decision turned on
# which severities halt a worker, not on spelling, so the reviewer spellings that
# reviewers actually emit are accepted and normalized instead of failing a whole
# axis on a vocabulary mismatch. Only the `error` family publishes a blocking
# gate: "high" is treated as must-fix so a genuinely blocking finding cannot ship
# as debt. Narrowing the canonical set satisfies td-efe124; documenting it in the
# usage text and the generated contract satisfies td-c09980.

# Canonical severities, most severe first. Each maps to exactly one td priority.
SGT_REVIEW_SEVERITIES="error warning info"

# Every accepted reviewer spelling as `<accepted>=<canonical>`. Canonical values
# map to themselves; every other spelling is an alias. Adding a spelling here is
# the only change needed to accept it end to end.
SGT_REVIEW_SEVERITY_ALIASES="error=error blocker=error critical=error high=error warning=warning major=warning medium=warning info=info minor=info low=info informational=info"

# Canonical severity for an accepted spelling; fails for anything unaccepted.
_sgt_review_severity_canonical() {
  local candidate="$1" pair
  # shellcheck disable=SC2046  # deliberate word splitting over the alias list
  for pair in $SGT_REVIEW_SEVERITY_ALIASES; do
    if [[ "$candidate" == "${pair%%=*}" ]]; then
      printf '%s' "${pair#*=}"
      return 0
    fi
  done
  return 1
}

# Every accepted spelling, canonical values and aliases alike.
_sgt_review_severity_accepted() {
  local pair accepted=""
  # shellcheck disable=SC2046  # deliberate word splitting over the alias list
  for pair in $SGT_REVIEW_SEVERITY_ALIASES; do
    accepted="${accepted:+$accepted }${pair%%=*}"
  done
  printf '%s\n' "$accepted"
}

_sgt_review_severity_priority() {
  local canonical
  canonical="$(_sgt_review_severity_canonical "$1")" || return 1
  case "$canonical" in
    error) printf 'P1' ;;
    warning) printf 'P2' ;;
    info) printf 'P3' ;;
    *) return 1 ;;
  esac
}

# True when a severity must publish a blocking review gate rather than route as
# reviewable debt.
_sgt_review_severity_blocking() {
  [[ "$(_sgt_review_severity_canonical "$1" 2>/dev/null)" == "error" ]]
}

# Human-readable alias table for the usage text and the generated contract, so
# both are rendered from this definition and cannot drift from the router.
_sgt_review_severity_alias_table() {
  local canonical pair spellings table=""
  # shellcheck disable=SC2046  # deliberate word splitting over the vocabularies
  for canonical in $SGT_REVIEW_SEVERITIES; do
    spellings=""
    # shellcheck disable=SC2046  # deliberate word splitting over the alias list
    for pair in $SGT_REVIEW_SEVERITY_ALIASES; do
      [[ "${pair#*=}" == "$canonical" && "${pair%%=*}" != "$canonical" ]] || continue
      spellings="${spellings:+$spellings, }${pair%%=*}"
    done
    table="${table:+$table; }$canonical ($(_sgt_review_severity_priority "$canonical")"
    if _sgt_review_severity_blocking "$canonical"; then
      table="$table, blocking"
    fi
    table="$table)"
    [[ -z "$spellings" ]] || table="$table also accepts $spellings"
  done
  printf '%s\n' "$table"
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
