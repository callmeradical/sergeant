#!/usr/bin/env bash
# _sgt-msg-lib.sh — shared input handling for the sgt-msg-* message bus.
#
# The bus carries agent-authored prose and agent-supplied identifiers straight
# into SQL and into a filesystem path. Both are attacker- and typo-reachable,
# so every value crosses one of the helpers below before it is used.
#
# Escaping strategy: SQLite string literals are delimited by single quotes and
# escape an embedded quote by doubling it. The grammar recognises no backslash
# escapes inside a standard string literal, so doubling is a complete escape
# for this context and is portable to every sqlite3 build. Values must still be
# wrapped in single quotes by the caller.
#
# shellcheck shell=bash

# _sgt_msg_q <value>
# Emit <value> escaped for inclusion inside a single-quoted SQL string literal.
_sgt_msg_q() {
  local s="${1-}"
  printf '%s' "${s//\'/\'\'}"
}

# _sgt_msg_valid_project <name>
# A project name selects a database file and appears in SQL. Restrict it to a
# leading-alphanumeric slug so it can neither traverse out of the database
# directory nor carry SQL or shell metacharacters.
_sgt_msg_valid_project() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  return 0
}

# _sgt_msg_valid_uint <value>
# Non-negative integer with no leading sign, whitespace or trailing text.
_sgt_msg_valid_uint() {
  [[ "${1-}" =~ ^[0-9]+$ ]]
}

# _sgt_msg_db_path <db-dir> <project>
# Resolve the database path for a project that has already been validated.
_sgt_msg_db_path() {
  printf '%s/%s.db' "$1" "$2"
}

# _sgt_msg_schema
# Emit the canonical schema. Every entry point applies it so a database is
# usable regardless of which command created it first.
_sgt_msg_schema() {
  cat <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS messages (
  id          TEXT PRIMARY KEY,
  project     TEXT NOT NULL,
  from_agent  TEXT NOT NULL,
  to_agent    TEXT NOT NULL,
  body        TEXT NOT NULL,
  sent_at     TEXT NOT NULL,
  read_at     TEXT
);
SQL
}
