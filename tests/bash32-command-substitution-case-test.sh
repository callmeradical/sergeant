#!/usr/bin/env bash
# Regression: no shipped script may put a `case` statement inside `$( ... )`
# without the leading-paren pattern form (GH #368).
#
# Bash 3.2 finds the end of a command substitution by counting parentheses, so a
# case pattern such as `.sergeant-*)` closes the substitution early.  Inside
# double quotes the rest of the case body is then plain string text, so
# `bash -n` still passes and the failure only appears when the code runs:
#
#   command substitution: syntax error near unexpected token `newline'
#
# This test:
#  1. Statically scans bin/ and scripts/ the way Bash 3.2 does: it reads every
#     `$(` to its paren-matched close and fails if the text it reads opens more
#     `case` statements than it closes.  Requires python3; skipped without it.
#  2. Executes _sgt_worktree_is_validation_clean under Bash 3.2 (SGT_MINIMUM_BASH
#     or /bin/bash) against a git shim.  Skipped when that Bash is not 3.2.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export SERGEANT_DRAIN_DIR="$TEST_ROOT/drain"
export SERGEANT_CONFIG="$TEST_ROOT/sergeant-config"
export SERGEANT_FLEET="$TEST_ROOT/fleet"

# ── 1. Static scan ───────────────────────────────────────────────────────────

cat > "$TEST_ROOT/scan.py" <<'EOF'
import os, re, sys

def matched_end(s, i):
    # Bash 3.2 style: count parens, honour quotes and backslashes, but know
    # nothing about case patterns.
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = (j if j >= 0 else n) + 1
            continue
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                if s[i] == '\\':
                    i += 1
                elif s.startswith('$(', i):
                    i = matched_end(s, i + 2)
                    continue
                i += 1
            i += 1
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n

status = 0
for path in sys.argv[1:]:
    if not os.path.isfile(path):
        continue
    with open(path, errors='replace') as f:
        text = f.read()
    if not (path.endswith('.sh') or 'bash' in text.split('\n', 1)[0]):
        continue
    i = 0
    while i < len(text):
        if text.startswith('$(', i) and not text.startswith('$((', i):
            body = re.sub(r'(?m)(^|\s)#.*$', '', text[i + 2:matched_end(text, i + 2)])
            if len(re.findall(r'\bcase\b', body)) > len(re.findall(r'\besac\b', body)):
                print('%s:%d' % (path, text.count('\n', 0, i) + 1))
                status = 1
        i += 1
sys.exit(status)
EOF

if command -v python3 >/dev/null 2>&1; then
  # The scanner must still recognise the construct it guards against.
  cat > "$TEST_ROOT/bad.sh" <<'EOF'
#!/usr/bin/env bash
x="$(printf 'a\n' | while IFS= read -r p; do
  case "$p" in
    a) ;;
    *) printf '%s\n' "$p" ;;
  esac
done)"
EOF
  if python3 -I "$TEST_ROOT/scan.py" "$TEST_ROOT/bad.sh" >/dev/null; then
    printf 'scanner missed a case pattern inside $( )\n' >&2
    exit 1
  fi
  shopt -s nullglob
  if ! hits="$(python3 -I "$TEST_ROOT/scan.py" "$ROOT_DIR"/bin/* \
    "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/scripts/hooks/*)"; then
    printf 'case statement inside $( ) breaks under Bash 3.2:\n%s\n' "$hits" >&2
    exit 1
  fi
  shopt -u nullglob
  printf 'static scan: ok\n'
else
  printf 'static scan: skipped (python3 not available)\n'
fi

# ── 2. Execute under Bash 3.2 ────────────────────────────────────────────────

minimum_bash="${SGT_MINIMUM_BASH:-/bin/bash}"
# shellcheck disable=SC2016
version="$("$minimum_bash" -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || true)"
if [[ "$version" != "3.2" ]]; then
  printf 'Bash 3.2 execution: skipped (found %s at %s)\n' "${version:-none}" "$minimum_bash"
  exit 0
fi

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *ls-files*) [[ -z "${FAKE_UNTRACKED:-}" ]] || printf '%s\n' "$FAKE_UNTRACKED" ;;
esac
exit 0
EOF
chmod +x "$TEST_ROOT/bin/git"

_validation_clean() {
  # shellcheck disable=SC2016
  FAKE_UNTRACKED="$1" PATH="$TEST_ROOT/bin:$PATH" "$minimum_bash" -c \
    'set -u; source "$1/bin/_sgt-lib.sh"; _sgt_worktree_is_validation_clean "$2"' \
    _ "$ROOT_DIR" "$TEST_ROOT" 2> "$TEST_ROOT/stderr"
}

_validation_clean '' || {
  printf 'clean worktree reported dirty under Bash 3.2:\n' >&2
  cat "$TEST_ROOT/stderr" >&2
  exit 1
}
_validation_clean "$(printf '.sergeant-status\n.sergeant-response')" || {
  printf 'Sergeant control files reported dirty under Bash 3.2:\n' >&2
  cat "$TEST_ROOT/stderr" >&2
  exit 1
}
if _validation_clean "$(printf '.sergeant-status\nnotes.txt')"; then
  printf 'untracked user file reported clean under Bash 3.2\n' >&2
  exit 1
fi
if [[ -s "$TEST_ROOT/stderr" ]]; then
  printf 'validation-clean check wrote errors under Bash 3.2:\n' >&2
  cat "$TEST_ROOT/stderr" >&2
  exit 1
fi
printf 'Bash 3.2 execution: ok\n'
