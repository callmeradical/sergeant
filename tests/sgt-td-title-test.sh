#!/usr/bin/env bash
# Regression test for _sgt_td_title() in _sgt-lib.sh (Deloitte support #34,
# #40): a router's own field-parsing limit (e.g. a 240-character summary cap)
# can legitimately exceed td's separate 200-character title limit once a
# prefix is added, and both reported issues describe exactly that: task
# creation fails with only a generic/opaque error, and a retained retry
# artifact replays the identical overlong title on every retry with nothing
# ever shortening it, permanently blocking routing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../bin/_sgt-lib.sh
source "$ROOT/bin/_sgt-lib.sh"

# A short text plus prefix well under 200 chars passes through unchanged.
out="$(_sgt_td_title "review: " "short summary")"
[[ "$out" == "review: short summary" ]] || {
  printf 'FAIL: short text was altered: %s\n' "$out" >&2
  exit 1
}

# A 211-character summary (the exact figure #34 reproduces with) must
# produce a title of exactly 200 characters, never longer.
long_summary="$(python3 -c 'print("x" * 211)')"
out="$(_sgt_td_title "review: " "$long_summary")"
[[ ${#out} -le 200 ]] || {
  printf 'FAIL: title is %d characters, want <= 200: %s\n' "${#out}" "$out" >&2
  exit 1
}
[[ "$out" == review:\ * ]] || {
  printf 'FAIL: truncated title lost its prefix: %s\n' "$out" >&2
  exit 1
}
[[ "$out" == *'...' ]] || {
  printf 'FAIL: truncated title has no visible truncation marker: %s\n' "$out" >&2
  exit 1
}
printf '_sgt_td_title bounds an overlong review summary to 200 chars: ok\n'

# A completely unbounded description (#40's router applies no upstream cap
# at all) must still be bounded by the title helper regardless of length.
huge_description="$(python3 -c 'print("y" * 5000)')"
out="$(_sgt_td_title "no-mistakes: " "$huge_description")"
[[ ${#out} -le 200 ]] || {
  printf 'FAIL: title is %d characters for an unbounded 5000-char description, want <= 200\n' "${#out}" >&2
  exit 1
}
printf '_sgt_td_title bounds a completely unbounded description to 200 chars: ok\n'

# Exactly at the boundary (no truncation needed) must not gain an ellipsis.
exact="$(python3 -c 'print("z" * 187)')"  # 187 + len("no-mistakes: ")=13 == 200
out="$(_sgt_td_title "no-mistakes: " "$exact")"
[[ "$out" == "no-mistakes: $exact" ]] || {
  printf 'FAIL: an exactly-fitting title was altered: %s\n' "$out" >&2
  exit 1
}
[[ ${#out} -eq 200 ]] || {
  printf 'FAIL: exact-boundary title is %d chars, want 200\n' "${#out}" >&2
  exit 1
}
printf '_sgt_td_title leaves an exactly-200-char title untouched: ok\n'
