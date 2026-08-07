#!/usr/bin/env bash
# Tests for the sgt-msg-* inter-agent message bus.
#
# Seams under test:
#   sgt-msg-send <project> --from <a> --to <b> "<body>"   INSERT path
#   sgt-msg-recv <project> --agent <a> [--limit N]        SELECT/UPDATE path
#   sgt-msg-ack  <project> <message-id>                   SELECT/UPDATE path
#   sgt-msg-list <project> [--agent <a>]                  SELECT path
#
# Every value that reaches SQL is attacker- or prose-controlled. These tests
# assert two properties:
#
#   1. Fidelity — a body survives a round trip byte-for-byte, including the
#      apostrophes, quotes, newlines and unicode that ordinary agent prose
#      contains.
#   2. Containment — no field can terminate its own string literal and execute
#      a second statement, and no project name can escape the database
#      directory.
#
# Both properties fail against string-interpolated SQL.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT_DIR/bin"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export SERGEANT_MSG_DB_DIR="$TEST_ROOT/messages"
mkdir -p "$SERGEANT_MSG_DB_DIR"

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

# _fresh <project> — start from an empty database for that project.
_fresh() { rm -f "$SERGEANT_MSG_DB_DIR/$1.db"* 2>/dev/null || true; }

# _table_exists <project>
_table_exists() {
  local out
  out="$(sqlite3 "$SERGEANT_MSG_DB_DIR/$1.db" \
    "SELECT name FROM sqlite_master WHERE type='table' AND name='messages';" 2>/dev/null || true)"
  [[ "$out" == "messages" ]]
}

# _body_of <project> <message-id>
_body_of() {
  sqlite3 "$SERGEANT_MSG_DB_DIR/$1.db" \
    "SELECT body FROM messages WHERE id=(SELECT id FROM messages ORDER BY rowid DESC LIMIT 1);" 2>/dev/null || true
}

# ── Fidelity: ordinary prose must survive a round trip ───────────────────────

while IFS='|' read -r label body; do
  [[ -z "$label" ]] && continue
  _fresh fidelity
  if ! "$BIN/sgt-msg-send" fidelity --from a --to b "$body" >/dev/null 2>&1; then
    _fail "send accepts $label"
    continue
  fi
  got="$(_body_of fidelity)"
  if [[ "$got" == "$body" ]]; then
    _pass "round-trip preserves $label"
  else
    _fail "round-trip preserves $label (sent '$body', stored '$got')"
  fi
done <<'CASES'
apostrophe|don't merge this
double quote|he said "ship it"
both quotes|don't say "ship it"
backslash|path\to\thing
semicolon|first; second
double dash|value -- trailing
unicode|résumé … ✅
CASES

# Newline is supplied separately: the case table above is newline-delimited.
_fresh fidelity_nl
nl_body="$(printf 'line one\nline two')"
if "$BIN/sgt-msg-send" fidelity_nl --from a --to b "$nl_body" >/dev/null 2>&1 \
  && [[ "$(_body_of fidelity_nl)" == "$nl_body" ]]; then
  _pass "round-trip preserves embedded newline"
else
  _fail "round-trip preserves embedded newline"
fi

# ── Containment: no field may execute a second statement ─────────────────────

# Body. This exact payload balances the VALUES list, so the trailing statement
# runs unless the value is escaped or bound.
_fresh inject_body
"$BIN/sgt-msg-send" inject_body --from a --to b "seed" >/dev/null 2>&1 || true
"$BIN/sgt-msg-send" inject_body --from a --to b \
  "x', '2020-01-01', NULL); DROP TABLE messages; --" >/dev/null 2>&1 || true
if _table_exists inject_body; then
  _pass "body cannot drop the messages table"
else
  _fail "body cannot drop the messages table (table was dropped)"
fi

# from/to fields. Assert the payload is stored as a literal value, not merely
# that the table survived — a column-count mismatch would "survive" by luck.
payload="x'); DROP TABLE messages; --"

_fresh inject_from
"$BIN/sgt-msg-send" inject_from --from "$payload" --to b "body" >/dev/null 2>&1 || true
got="$(sqlite3 "$SERGEANT_MSG_DB_DIR/inject_from.db" \
  "SELECT from_agent FROM messages LIMIT 1;" 2>/dev/null || true)"
if _table_exists inject_from && [[ "$got" == "$payload" ]]; then
  _pass "--from is stored as a literal value"
else
  _fail "--from is stored as a literal value (stored '$got')"
fi

_fresh inject_to
"$BIN/sgt-msg-send" inject_to --from a --to "$payload" "body" >/dev/null 2>&1 || true
got="$(sqlite3 "$SERGEANT_MSG_DB_DIR/inject_to.db" \
  "SELECT to_agent FROM messages LIMIT 1;" 2>/dev/null || true)"
if _table_exists inject_to && [[ "$got" == "$payload" ]]; then
  _pass "--to is stored as a literal value"
else
  _fail "--to is stored as a literal value (stored '$got')"
fi

# sgt-msg-ack message id.
_fresh inject_ack
"$BIN/sgt-msg-send" inject_ack --from a --to b "seed" >/dev/null 2>&1 || true
"$BIN/sgt-msg-ack" inject_ack "x' OR '1'='1'; DROP TABLE messages; --" >/dev/null 2>&1 || true
if _table_exists inject_ack; then
  _pass "ack message-id cannot drop the messages table"
else
  _fail "ack message-id cannot drop the messages table (table was dropped)"
fi

# sgt-msg-recv agent and limit. A tautology payload must match nothing, not
# every row — surviving the table check alone is not evidence.
_fresh inject_recv
"$BIN/sgt-msg-send" inject_recv --from a --to b "seed" >/dev/null 2>&1 || true
out="$("$BIN/sgt-msg-recv" inject_recv --agent "x' OR '1'='1" 2>/dev/null || true)"
if [[ "$out" != *"seed"* ]]; then
  _pass "recv --agent tautology matches no rows"
else
  _fail "recv --agent tautology matches no rows (it returned another agent's mail)"
fi

"$BIN/sgt-msg-recv" inject_recv --agent b --limit "1; DROP TABLE messages" >/dev/null 2>&1 || true
if _table_exists inject_recv; then
  _pass "recv --limit cannot drop the messages table"
else
  _fail "recv --limit cannot drop the messages table (table was dropped)"
fi

# A non-numeric --limit must be refused rather than interpolated.
_fresh limit_type
"$BIN/sgt-msg-send" limit_type --from a --to b "seed" >/dev/null 2>&1 || true
if "$BIN/sgt-msg-recv" limit_type --agent b --limit "not-a-number" >/dev/null 2>&1; then
  _fail "recv rejects a non-numeric --limit"
else
  _pass "recv rejects a non-numeric --limit"
fi

# sgt-msg-list agent. Same tautology property as recv.
_fresh inject_list
"$BIN/sgt-msg-send" inject_list --from a --to b "seed" >/dev/null 2>&1 || true
out="$("$BIN/sgt-msg-list" inject_list --agent "x' OR '1'='1" 2>/dev/null || true)"
if _table_exists inject_list && [[ "$out" != *"seed"* ]]; then
  _pass "list --agent tautology matches no rows"
else
  _fail "list --agent tautology matches no rows"
fi

# ── Containment: project name may not escape the database directory ──────────

escape_target="$TEST_ROOT/escaped.db"
rm -f "$escape_target"
"$BIN/sgt-msg-send" "../escaped" --from a --to b "body" >/dev/null 2>&1 || true
if [[ -f "$escape_target" ]]; then
  _fail "project name cannot traverse out of the database directory"
else
  _pass "project name cannot traverse out of the database directory"
fi

for bad in "../evil" "a/b" "a'b" "a;b" ".." "/abs"; do
  if "$BIN/sgt-msg-send" "$bad" --from a --to b "body" >/dev/null 2>&1; then
    _fail "project name '$bad' is rejected"
  else
    _pass "project name '$bad' is rejected"
  fi
done

# A normal project name must still be accepted.
_fresh normal-project_1
if "$BIN/sgt-msg-send" normal-project_1 --from a --to b "hello" >/dev/null 2>&1; then
  _pass "ordinary project name is accepted"
else
  _fail "ordinary project name is accepted"
fi

printf '\nsgt-msg bus: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
