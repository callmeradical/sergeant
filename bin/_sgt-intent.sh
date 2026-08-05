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

_sgt_no_mistakes_version() {
  no-mistakes --version 2>/dev/null | sed -n '1s/^no-mistakes version //p'
}

# Flag names accepted by `no-mistakes axi run`, space-delimited and space-padded.
# Help output is the only capability surface no-mistakes exposes, so the probe
# reads it rather than inferring support from a version number.
_sgt_no_mistakes_axi_run_flags() {
  local flags
  flags="$(no-mistakes axi run --help 2>&1 | \
    sed -n 's/^[[:space:]]\{2,\}\(-[A-Za-z], \)\{0,1\}\(--[a-z][a-z-]*\).*/\2/p' | \
    sort -u | tr '\n' ' ')"
  [[ -n "$flags" ]] || return 1
  printf ' %s\n' "$flags"
}

# Resolve the intent transport for a coordinator-owned validation run.
# Prints the transport name, or fails when no permitted transport exists.
# Transports:
#   intent-file  private: no-mistakes reads the canonical intent from a path, so
#                intent content never enters argv (td-102049).
#   argv         exposes intent content through ps and /proc/<pid>/cmdline; only
#                selected when the operator explicitly consents.
_sgt_resolve_intent_transport() {
  local allow_argv="$1" flags
  flags="$(_sgt_no_mistakes_axi_run_flags)" || return 1
  case "$flags" in
    *' --intent-file '*) printf 'intent-file\n'; return 0 ;;
  esac
  case "$flags" in
    *' --intent '*) ;;
    *) return 1 ;;
  esac
  [[ "$allow_argv" == "true" ]] || return 2
  printf 'argv\n'
}

# Actionable diagnostic for a failed transport resolution. $1 is the status
# _sgt_resolve_intent_transport returned: 1 when no intent flag exists at all,
# 2 when only the argv transport exists and the operator has not consented.
# Is one specific transport available on the installed build? Used where the
# coordinator's recorded decision must be honoured exactly rather than
# re-optimised.
_sgt_intent_transport_available() {
  local transport="$1" flags
  flags="$(_sgt_no_mistakes_axi_run_flags)" || return 1
  case "$transport" in
    intent-file)
      case "$flags" in *' --intent-file '*) return 0 ;; esac
      ;;
    argv)
      case "$flags" in *' --intent '*) return 0 ;; esac
      ;;
  esac
  return 1
}

# The consented argv transport was recorded at launch, but the build running the
# validation does not accept --intent.
_sgt_intent_argv_unavailable_diagnostic() {
  local flags
  flags="$(_sgt_no_mistakes_axi_run_flags 2>/dev/null || true)"
  printf 'no-mistakes cannot serve the consented argv intent transport\n'
  printf '  recorded transport:  argv (operator consented at launch)\n'
  printf '  required capability: no-mistakes axi run --intent <text>\n'
  printf '  observed version:    %s\n' "$(_sgt_no_mistakes_version)"
  printf '  observed axi run flags:%s\n' "${flags:- none}"
  printf '  options:\n'
  case "$flags" in
    *' --intent-file '*)
      printf '    1. Relaunch validation without --allow-argv-intent: this build\n'
      printf '       accepts the private --intent-file transport.\n'
      ;;
    *)
      printf '    1. Install a no-mistakes build that accepts an intent flag.\n'
      ;;
  esac
}

_sgt_intent_transport_diagnostic() {
  local status="$1" flags
  flags="$(_sgt_no_mistakes_axi_run_flags 2>/dev/null || true)"
  printf 'no-mistakes lacks the private intent transport required for validation\n'
  printf '  required capability: no-mistakes axi run --intent-file <path>\n'
  printf '  observed version:    %s\n' "$(_sgt_no_mistakes_version)"
  printf '  observed axi run flags:%s\n' "${flags:- none}"
  printf '  options:\n'
  printf '    1. Install a no-mistakes build that accepts --intent-file.\n'
  if [[ "$status" == "2" ]]; then
    printf '    2. Re-run with --allow-argv-intent to consent to canonical intent in\n'
    printf '       argv, which exposes it through ps and /proc/<pid>/cmdline.\n'
  else
    printf '    2. --allow-argv-intent cannot help: this build accepts no intent flag,\n'
    printf '       so no canonical intent can reach the run at all.\n'
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
