#!/usr/bin/env bash

_sgt_intent_revision() {
  local intent_file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$intent_file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$intent_file" | awk '{print $1}'
  else
    printf 'ERROR: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

_sgt_intent_revision_matches() {
  local task_dir="$1" repo_state="$2" worktree="$3"
  local fleet_intent="$task_dir/.sergeant-intent.md"
  local repo_intent="$repo_state/.sergeant-intent.md"
  local worktree_intent="$worktree/.sergeant-intent.md"
  local fleet_revision="$task_dir/intent_revision"
  local repo_revision="$repo_state/intent_revision"
  local expected_revision

  [[ -f "$fleet_intent" && -f "$repo_intent" && -f "$worktree_intent" ]] || return 1
  [[ -f "$fleet_revision" && -f "$repo_revision" ]] || return 1
  cmp -s "$fleet_intent" "$repo_intent" && cmp -s "$fleet_intent" "$worktree_intent" || return 1
  expected_revision="$(cat "$fleet_revision")"
  [[ -n "$expected_revision" && "$expected_revision" == "$(cat "$repo_revision")" ]] || return 1
  [[ "$expected_revision" == "$(_sgt_intent_revision "$fleet_intent")" ]]
}

_sgt_intent_path_has_symlink() {
  local input_file="$1" current component
  local -a components
  if [[ "$input_file" == /* ]]; then
    current="/"
  else
    current="$PWD"
  fi
  IFS='/' read -ra components <<< "$input_file"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." ]] || continue
    current="${current%/}/$component"
    [[ ! -L "$current" ]] || return 0
  done
  return 1
}

_sgt_intent_validate() {
  local intent_file="$1"
  local validation_error

  validation_error="$(awk '
    BEGIN {
      expected[1] = "Objective"
      expected[2] = "Required Invariants"
      expected[3] = "Approved Tradeoffs"
      expected[4] = "Out Of Scope"
      expected[5] = "State Transitions"
      expected[6] = "Failure Windows"
      expected[7] = "Negative Test Matrix"
      expected[8] = "Validation Evidence"
      section = 0
      content = 0
      error = ""
    }
    /^## / {
      if (section > 0 && content == 0) {
        error = "intent section is empty: " expected[section]
        exit
      }
      section++
      if (section > 8 || $0 != "## " expected[section]) {
        error = "intent sections must appear exactly once in the required order"
        exit
      }
      content = 0
      next
    }
    section > 0 && $0 !~ /^[[:space:]]*$/ { content = 1 }
    END {
      if (error != "") print error
      else if (section != 8) print "intent must contain exactly eight required sections"
      else if (content == 0) print "intent section is empty: " expected[section]
    }
  ' "$intent_file")"

  [[ -z "$validation_error" ]] || _die "$validation_error"
}

_sgt_intent_prepare() {
  local input_file="$1"
  local objective="$2"
  local output_file="$3"

  if [[ -n "$input_file" ]]; then
    [[ "$input_file" != *$'\n'* && "$input_file" != *$'\r'* ]] || _die "intent path contains invalid characters"
    if [[ "$input_file" == ".." || "$input_file" == ../* || "$input_file" == */../* || "$input_file" == */.. ]]; then
      _die "intent path traversal is not allowed"
    fi
    [[ -e "$input_file" ]] || _die "intent file not found"
    if _sgt_intent_path_has_symlink "$input_file"; then
      _die "intent file must not traverse a symlink"
    fi
    [[ -f "$input_file" && -r "$input_file" ]] || _die "intent file must be a readable regular file"
    [[ "$(wc -c < "$input_file")" -le 65536 ]] || _die "intent file exceeds 65536 bytes"
    if LC_ALL=C od -An -tu1 "$input_file" | awk '
      { for (i = 1; i <= NF; i++) if (($i < 32 && $i != 9 && $i != 10) || $i == 127) bad = 1 }
      END { exit bad ? 0 : 1 }
    '; then
      _die "intent file contains unsupported control characters"
    fi
    _sgt_intent_validate "$input_file"
    cp "$input_file" "$output_file"
    return
  fi

  if printf '%s\n' "$objective" | grep -Eiq '(^|[^[:alnum:]])(auth|oauth|security|secrets?|credentials?|payments?|databases?|migrations?|stateful|production|destructive)([^[:alnum:]]|$)|persistent[[:space:]-]+state|state[[:space:]-]+transitions?'; then
    _die "safety-sensitive or stateful objective requires --intent-file before implementation"
  fi

  cat > "$output_file" <<EOF
# Sergeant Intent

Intent path: standard-isolated

## Objective

$objective

## Required Invariants

No product invariants were approved beyond the objective and active repository instructions.

## Approved Tradeoffs

None approved.

## Out Of Scope

Product behavior and repositories not named by the dispatch inputs.

## State Transitions

Standard-isolated path: no persistent or externally published state transition is authorized.

## Failure Windows

Standard-isolated path: stop on native validation, review, or dispatch failure; do not publish partial work.

## Negative Test Matrix

Run regressions for the objective and unchanged neighboring behavior; no safety-specific matrix was supplied.

## Validation Evidence

Record focused and full native validation plus independent review evidence before shipping.
EOF
  _sgt_intent_validate "$output_file"
}

_sgt_intent_install() {
  local source_file="$1"
  local target_file="$2"
  local temporary_file="${target_file}.tmp.$$"

  if ! cp "$source_file" "$temporary_file"; then
    rm -f "$temporary_file"
    return 1
  fi
  mv "$temporary_file" "$target_file"
}
