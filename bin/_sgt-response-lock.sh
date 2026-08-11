#!/usr/bin/env bash
# Shared serialization and archive format for response publication and consumption.

_SGT_RESPONSE_LOCK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1
# shellcheck source=bin/_sgt-process-identity.sh
source "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/_sgt-process-identity.sh"

# ── Response archive format ──────────────────────────────────────────────────
# A consumed response is recorded as a directory of four fields: `body` (the
# exact response transport), `gate_generation`, `applied_status`, and `proof`
# (the worker's .sergeant-response-applied record).  sgt-ack-response publishes
# these entries, sgt-cleanup validates them before retiring fleet state, and
# sgt-cleanup's retirement archive reuses the same field names for the fields it
# can prove.  Every reader parses the format through the helpers below so the
# format has exactly one definition.
_SGT_RESPONSE_ARCHIVE_FIELDS="body gate_generation applied_status proof"

# Print the single value of one `key=value` field, or fail when the key is
# missing, empty, or recorded more than once.
_sgt_response_archive_field() {
  local key="$1" record_file="$2"

  awk -F= -v key="$key" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END { if (count == 1 && value != "") print value; else exit 1 }
  ' "$record_file"
}

# A retired handshake records the same fields, so an archive entry also has to
# prove it is not one: sgt-cleanup marks a retirement archive with this file, and
# an entry carrying it is never an acknowledgement no matter where it is found.
_SGT_RESPONSE_RETIRED_MARKER="retired"

# Every canonical field of an archive entry is present as a regular file, and the
# entry does not claim to be a retirement.
_sgt_response_archive_entry_complete() {
  local entry="$1" field

  [[ -d "$entry" && ! -L "$entry" ]] || return 1
  [[ ! -e "$entry/$_SGT_RESPONSE_RETIRED_MARKER" && \
    ! -L "$entry/$_SGT_RESPONSE_RETIRED_MARKER" ]] || return 1
  for field in $_SGT_RESPONSE_ARCHIVE_FIELDS; do
    [[ -f "$entry/$field" && ! -L "$entry/$field" ]] || return 1
  done
}

# A complete entry whose recorded proof binds the same response identity,
# gate generation, and applied status as the entry itself.
#
# Every field must be present and non-empty.  An empty `applied_status` beside a
# `proof` with no `status=` line would otherwise compare equal as "" == "" and let
# an entry that records no applied status at all pass as a complete
# acknowledgement, so the three proof lookups must succeed rather than default to
# empty and both entry fields are range-checked.
_sgt_response_archive_entry_matches() {
  local entry="$1" response_id="$2" gate_generation="$3"
  local applied_status entry_generation proof_generation proof_id proof_status

  [[ -n "$response_id" && "$gate_generation" =~ ^[1-9][0-9]*$ ]] || return 1
  _sgt_response_archive_entry_complete "$entry" || return 1
  applied_status="$(cat "$entry/applied_status")" || return 1
  entry_generation="$(cat "$entry/gate_generation")" || return 1
  [[ -n "$applied_status" && "$entry_generation" == "$gate_generation" ]] || return 1
  proof_id="$(_sgt_response_archive_field response_id "$entry/proof")" || return 1
  proof_generation="$(_sgt_response_archive_field gate_generation "$entry/proof")" || return 1
  proof_status="$(_sgt_response_archive_field status "$entry/proof")" || return 1
  [[ "$proof_id" == "$response_id" && "$proof_generation" == "$gate_generation" && \
    "$proof_status" == "$applied_status" ]]
}

_sgt_response_lock_record_pid() {
  local record="$1"
  _sgt_response_lock_record_parse "$record" || return 1
  printf '%s\n' "$_SGT_LOCK_RECORD_PID"
}

_sgt_response_lock_record_parse() {
  local record="$1" canonical
  [[ "$(printf '%s\n' "$record" | awk 'END { print NR }')" == 3 ]] || return 1
  _SGT_LOCK_RECORD_PID="$(printf '%s\n' "$record" | sed -n '1s/^pid=//p')"
  _SGT_LOCK_RECORD_START="$(printf '%s\n' "$record" | sed -n '2s/^start=//p')"
  _SGT_LOCK_RECORD_NONCE="$(printf '%s\n' "$record" | sed -n '3s/^nonce=//p')"
  [[ "$_SGT_LOCK_RECORD_PID" =~ ^[1-9][0-9]*$ &&
     ( "$_SGT_LOCK_RECORD_START" =~ ^proc:[0-9]+$ ||
       "$_SGT_LOCK_RECORD_START" == ps:* ) &&
     "$_SGT_LOCK_RECORD_START" != ps: &&
     "$_SGT_LOCK_RECORD_NONCE" =~ ^[a-f0-9]{32}$ ]] || return 1
  canonical="$(printf 'pid=%s\nstart=%s\nnonce=%s' "$_SGT_LOCK_RECORD_PID" \
    "$_SGT_LOCK_RECORD_START" "$_SGT_LOCK_RECORD_NONCE")"
  [[ "$record" == "$canonical" ]]
}

_sgt_response_lock_record_live() {
  local record="$1" pid expected current
  pid="$(_sgt_response_lock_record_pid "$record")" || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  _sgt_response_lock_record_parse "$record" || return 1
  expected="$_SGT_LOCK_RECORD_START"
  current="$(_sgt_process_start_token "$pid")" || return 1
  [[ "$current" == "$expected" ]]
}

_sgt_response_lock_record_for_pid() {
  local pid="$1" start nonce
  start="$(_sgt_process_start_token "$pid")" || return 1
  nonce="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ "$nonce" =~ ^[a-f0-9]{32}$ ]] || return 1
  printf 'pid=%s\nstart=%s\nnonce=%s\n' "$pid" "$start" "$nonce"
}

_sgt_response_lock_record_is_this_process() {
  local record="$1" acquisition="${_SGT_RESPONSE_LOCK_OWNER_RECORD:-}"
  local pid expected
  [[ -n "$acquisition" && "$record" == "$acquisition" ]] || return 1
  _sgt_response_lock_record_parse "$acquisition" || return 1
  pid="$_SGT_LOCK_RECORD_PID"
  expected="$_SGT_LOCK_RECORD_START"
  [[ "$pid" == "$$" ]] || return 1
  [[ "$expected" == "$(_sgt_process_start_token "$$")" ]]
}

_sgt_response_lock_acquire() {
  local repo_state="$1"
  local lock_path="$repo_state/${2:-response.lock}"
  local candidate="$repo_state/.${2:-response.lock}.$$.$RANDOM.$RANDOM"
  local owner current_owner interval timeout started owner_record
  interval="${SGT_RESPONSE_LOCK_INTERVAL:-0.01}"
  timeout="${SGT_RESPONSE_LOCK_TIMEOUT:-30}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || { printf 'ERROR: Invalid response lock timeout: %s\n' "$timeout" >&2; return 1; }
  started=$SECONDS
  owner_record="$(_sgt_response_lock_record_for_pid "$$")" || return 1
  printf '%s\n' "$owner_record" > "$candidate" || return 1

  while true; do
    if (( SECONDS - started >= timeout )); then
      rm -f "$candidate"
      printf 'ERROR: Timed out waiting for response lock: %s\n' "$lock_path" >&2
      return 1
    fi
    if [[ -d "$lock_path" ]]; then
      owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      if [[ -z "$owner" ]]; then
        # The directory may have been atomically retired after the -d check.
        # Only a still-present ownerless directory is ambiguous.
        [[ -d "$lock_path" ]] || continue
        rm -f "$candidate"
        printf 'ERROR: Response lock directory has no authenticated owner: %s\n' "$lock_path" >&2
        return 1
      fi
      _sgt_response_lock_record_pid "$owner" >/dev/null || {
        rm -f "$candidate"
        printf 'ERROR: Legacy or malformed response lock directory owner is ambiguous: %s\n' "$lock_path/pid" >&2
        return 1
      }
      if _sgt_response_lock_record_live "$owner"; then sleep "$interval"; continue; fi
      current_owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      [[ "$current_owner" == "$owner" ]] || continue
      if ! rm -f "$lock_path/pid" || ! rmdir "$lock_path"; then
        rm -f "$candidate"
        return 1
      fi
      continue
    fi
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
      owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      [[ -n "$owner" ]] || continue
      _sgt_response_lock_record_pid "$owner" >/dev/null || { rm -f "$candidate"; printf 'ERROR: Response lock has an invalid owner: %s\n' "$lock_path" >&2; return 1; }
      if _sgt_response_lock_record_live "$owner"; then sleep "$interval"; continue; fi
      current_owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      [[ "$current_owner" == "$owner" ]] && rm -f "$lock_path"
      continue
    fi
    if ln "$candidate" "$lock_path" 2>/dev/null; then
      rm -f "$candidate"
      _SGT_RESPONSE_LOCK_DIR="$lock_path"
      _SGT_RESPONSE_LOCK_OWNER_RECORD="$owner_record"
      return 0
    elif [[ ! -e "$lock_path" && ! -L "$lock_path" ]]; then
      rm -f "$candidate"
      printf 'ERROR: Could not create response lock: %s\n' "$lock_path" >&2
      return 1
    fi
  done
}

# Release the caller-owned response lock.
# Success, or discovering that another PID owns the lock, clears
# _SGT_RESPONSE_LOCK_DIR. If removing our own lock fails, preserve
# _SGT_RESPONSE_LOCK_DIR and return non-zero so callers can retry without
# spinning on their own live PID.
_sgt_response_lock_release() {
  [[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]] || return 0
  local owner
  owner="$(cat "$_SGT_RESPONSE_LOCK_DIR" 2>/dev/null || true)"
  if [[ -n "${_SGT_RESPONSE_LOCK_OWNER_RECORD:-}" &&
        "$owner" == "$_SGT_RESPONSE_LOCK_OWNER_RECORD" ]]; then
    if ! rm -f "$_SGT_RESPONSE_LOCK_DIR"; then
      printf 'ERROR: Could not release response lock: %s\n' "$_SGT_RESPONSE_LOCK_DIR" >&2
      return 1
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
  _SGT_RESPONSE_LOCK_OWNER_RECORD=""
}

# _sgt_response_lock_reclaim <repo_state> [lock_name]
#
# Drop a response lock whose recorded owner is THIS process.
#
# The lock records an exact PID, process-birth token, and acquisition nonce.
# Bash keeps $$ and the process-birth token stable in its subshells, so a
# background loop killed while holding the lock can leave a record naming this
# still-live shell.  The exact record prevents a bare or reused PID from proving
# ownership.
#
# Only call this once every other context in this process that could hold the
# lock has been terminated; otherwise it would break mutual exclusion.
_sgt_response_lock_reclaim() {
  local repo_state="$1"
  local lock_path="$repo_state/${2:-response.lock}"
  local owner

  if [[ -d "$lock_path" ]]; then
    owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
    if _sgt_response_lock_record_is_this_process "$owner"; then
      rm -f "$lock_path/pid" 2>/dev/null || true
      rmdir "$lock_path" 2>/dev/null || true
    fi
  elif [[ -e "$lock_path" || -L "$lock_path" ]]; then
    owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
    if _sgt_response_lock_record_is_this_process "$owner"; then
      rm -f "$lock_path" 2>/dev/null || true
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
  _SGT_RESPONSE_LOCK_OWNER_RECORD=""
}

# _sgt_response_lock_held_by_this_process <repo_state> [lock_name]
# 0 when the lock contains this process's exact current acquisition record, but
# this context does not own its path. Waiting on such a lock can never succeed.
_sgt_response_lock_held_by_this_process() {
  local repo_state="$1"
  local lock_path="$repo_state/${2:-response.lock}"
  local owner
  [[ "${_SGT_RESPONSE_LOCK_DIR:-}" != "$lock_path" ]] || return 1
  if [[ -d "$lock_path" ]]; then
    owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
  elif [[ -e "$lock_path" || -L "$lock_path" ]]; then
    owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
  else
    return 1
  fi
  _sgt_response_lock_record_is_this_process "$owner"
}

# Canonical replacement command and pane authentication. The tmux start command
# is the durable spawn capability: a token appearing somewhere in a foreign
# command is not ownership proof.
_sgt_replacement_worker_command() {
  local token="$1" role="$2" worker_command="$3"
  [[ "$token" =~ ^[a-f0-9]{32}$ && "$role" =~ ^worker:[A-Za-z0-9._-]+$ &&
     -n "$worker_command" && "$worker_command" != *$'\n'* ]] || return 1
  printf '%q %q %q %s' "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/sgt-replacement-launch" \
    "$token" "$role" "$worker_command"
}

_sgt_replacement_pane_auth() {
  local pane="$1" expected_token="$2" expected_role="$3"
  local evidence current current_start
  local marker_dead marker_pane marker_pid marker_command marker_token marker_role marker_option_pid marker_start
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 1
  evidence=""
  for _ in $(seq 1 "${SGT_REPLACEMENT_MARKER_ATTEMPTS:-100}"); do
    evidence="$(tmux display-message -p -t "$pane" \
      '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_current_command}|#{@sergeant_replacement_token}|#{@sergeant_replacement_role}|#{@sergeant_replacement_pid}|#{@sergeant_replacement_start}' \
      2>/dev/null)" || return 1
    IFS='|' read -r marker_dead marker_pane marker_pid marker_command marker_token marker_role marker_option_pid marker_start <<< "$evidence"
    if [[ "$marker_token" == "$expected_token" && "$marker_role" == "$expected_role" &&
          -n "$marker_option_pid" && -n "$marker_start" ]]; then
      break
    fi
    # Any non-empty conflicting marker is another owner. Only the launcher's
    # short, wholly-unmarked publication window is retryable.
    [[ -z "$marker_token" && -z "$marker_role" && -z "$marker_option_pid" && -z "$marker_start" ]] || return 1
    sleep "${SGT_REPLACEMENT_MARKER_INTERVAL:-0.01}"
  done
  current="$(tmux display-message -p -t "$pane" \
    '#{pane_dead}|#{pane_id}|#{pane_pid}|#{pane_current_command}|#{@sergeant_replacement_token}|#{@sergeant_replacement_role}|#{@sergeant_replacement_pid}|#{@sergeant_replacement_start}' \
    2>/dev/null)" || return 1
  [[ "$evidence" == "$current" ]] || return 1
  IFS='|' read -r marker_dead marker_pane marker_pid marker_command marker_token marker_role marker_option_pid marker_start <<< "$evidence"
  current_start="$(_sgt_process_start_token "$marker_pid")" || return 1
  [[ "$marker_dead" == 0 && "$marker_pane" == "$pane" && "$marker_pid" =~ ^[1-9][0-9]*$ &&
     -n "$marker_command" && "$marker_token" == "$expected_token" &&
     "$marker_role" == "$expected_role" && "$marker_option_pid" == "$marker_pid" &&
     "$marker_start" == "$current_start" ]] || return 1
  printf '%s|%s|%s|%s|%s\n' "$pane" "$marker_pid" "$marker_start" "$marker_token" "$marker_role"
}

_sgt_replacement_pane_identity_matches() {
  _sgt_replacement_pane_auth "$2" "$3" "$4" >/dev/null
}

# Discover the one authenticated replacement pane from one successful, exact
# inventory snapshot. Status 1 means the replacement window is absent; status 2
# means tmux failed or returned malformed/duplicate inventory; status 3 means
# the window is ambiguous; status 4 means its sole pane is foreign.
_sgt_replacement_discover_pane() {
  local window_name="$1" token="$2" role="$3" phase="$4"
  local journal_pane="$5" journal_auth="$6"
  local inventory line candidate candidate_window candidate_auth
  local authenticated="" pane_count=0 seen_panes="|"
  inventory="$(tmux list-panes -a -F '#{pane_id}|#{window_name}' 2>/dev/null)" || return 2
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    candidate="${line%%|*}"
    [[ "$candidate" != "$line" ]] || return 2
    candidate_window="${line#*|}"
    [[ "$candidate" =~ ^%[0-9]+$ && -n "$candidate_window" &&
       "$candidate_window" != *'|'* ]] || return 2
    [[ "$seen_panes" != *"|$candidate|"* ]] || return 2
    seen_panes="${seen_panes}${candidate}|"
    [[ "$candidate_window" == "$window_name" ]] || continue
    pane_count=$((pane_count + 1))
    candidate_auth="$(_sgt_replacement_pane_auth "$candidate" "$token" "$role" 2>/dev/null || true)"
    if [[ -n "$candidate_auth" ]] &&
        { [[ "$phase" == bound || "$phase" == fenced || "$phase" == spawning ]] ||
          [[ "$journal_pane" == "$candidate" && "$journal_auth" == "$candidate_auth" ]]; }; then
      [[ -z "$authenticated" ]] || return 3
      authenticated="$candidate"
    fi
  done <<< "$inventory"
  (( pane_count > 0 )) || return 1
  [[ -n "$authenticated" ]] || return 4
  (( pane_count == 1 )) || return 3
  printf '%s\n' "$authenticated"
}

_sgt_replacement_recorded_auth_valid() {
  local auth="$1" pane="$2" token="$3" role="$4"
  local auth_pane auth_pid auth_start auth_token auth_role
  IFS='|' read -r auth_pane auth_pid auth_start auth_token auth_role <<< "$auth"
  [[ "$auth_pane" == "$pane" && "$auth_pid" =~ ^[1-9][0-9]*$ &&
     ( "$auth_start" =~ ^proc:[0-9]+$ || "$auth_start" == ps:* ) &&
     "$auth_start" != ps: &&
     "$auth_token" == "$token" && "$auth_role" == "$role" ]]
}

# Strict shared relaunch journal. Both public recovery CLIs use this canonical
# shape; malformed, partial, or extended records are never interpreted.
_sgt_transfer_journal_render() {
  printf 'version=1\nresponse_id=%s\nnotification_id=%s\nspawn_token=%s\ngate_generation=%s\ntmux_session=%s\nwindow_name=%s\nworker_role=%s\nworker_command=%s\nphase=%s\npane=%s\npane_auth=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}"
}

_sgt_transfer_journal_read() {
  local file="$1" canonical
  [[ -f "$file" && ! -L "$file" && "$(wc -l < "$file" | tr -d ' ')" == 12 ]] || return 1
  _SGT_TRANSFER_RESPONSE_ID="$(sed -n '2s/^response_id=//p' "$file")"
  _SGT_TRANSFER_NOTIFICATION_ID="$(sed -n '3s/^notification_id=//p' "$file")"
  _SGT_TRANSFER_SPAWN_TOKEN="$(sed -n '4s/^spawn_token=//p' "$file")"
  _SGT_TRANSFER_GATE_GENERATION="$(sed -n '5s/^gate_generation=//p' "$file")"
  _SGT_TRANSFER_TMUX_SESSION="$(sed -n '6s/^tmux_session=//p' "$file")"
  _SGT_TRANSFER_WINDOW_NAME="$(sed -n '7s/^window_name=//p' "$file")"
  _SGT_TRANSFER_WORKER_ROLE="$(sed -n '8s/^worker_role=//p' "$file")"
  _SGT_TRANSFER_WORKER_COMMAND="$(sed -n '9s/^worker_command=//p' "$file")"
  _SGT_TRANSFER_PHASE="$(sed -n '10s/^phase=//p' "$file")"
  _SGT_TRANSFER_PANE="$(sed -n '11s/^pane=//p' "$file")"
  _SGT_TRANSFER_PANE_AUTH="$(sed -n '12s/^pane_auth=//p' "$file")"
  [[ "$(_sgt_response_archive_field version "$file" 2>/dev/null || true)" == 1 &&
     ( -z "$_SGT_TRANSFER_RESPONSE_ID" || "$_SGT_TRANSFER_RESPONSE_ID" =~ ^[a-f0-9]{32}$ ) &&
     "$_SGT_TRANSFER_NOTIFICATION_ID" =~ ^[a-f0-9]{32}$ &&
     "$_SGT_TRANSFER_SPAWN_TOKEN" =~ ^[a-f0-9]{32}$ &&
     "$_SGT_TRANSFER_GATE_GENERATION" =~ ^[1-9][0-9]*$ &&
     "$_SGT_TRANSFER_TMUX_SESSION" =~ ^[A-Za-z0-9._:-]+$ &&
     "$_SGT_TRANSFER_WINDOW_NAME" =~ ^[A-Za-z0-9._:/-]+$ &&
     "$_SGT_TRANSFER_WORKER_ROLE" =~ ^worker:[A-Za-z0-9._-]+$ &&
     -n "$_SGT_TRANSFER_WORKER_COMMAND" ]] || return 1
  case "$_SGT_TRANSFER_PHASE" in
    bound|fenced|spawning)
      [[ -z "$_SGT_TRANSFER_PANE" && -z "$_SGT_TRANSFER_PANE_AUTH" ]] || return 1
      ;;
    spawned|published|acked)
      _sgt_replacement_recorded_auth_valid "$_SGT_TRANSFER_PANE_AUTH" \
        "$_SGT_TRANSFER_PANE" "$_SGT_TRANSFER_SPAWN_TOKEN" \
        "$_SGT_TRANSFER_WORKER_ROLE" || return 1
      ;;
    *) return 1 ;;
  esac
  canonical="$(_sgt_transfer_journal_render "$_SGT_TRANSFER_RESPONSE_ID" \
    "$_SGT_TRANSFER_NOTIFICATION_ID" "$_SGT_TRANSFER_SPAWN_TOKEN" \
    "$_SGT_TRANSFER_GATE_GENERATION" "$_SGT_TRANSFER_TMUX_SESSION" \
    "$_SGT_TRANSFER_WINDOW_NAME" "$_SGT_TRANSFER_WORKER_ROLE" \
    "$_SGT_TRANSFER_WORKER_COMMAND" \
    "$_SGT_TRANSFER_PHASE" "$_SGT_TRANSFER_PANE" "$_SGT_TRANSFER_PANE_AUTH")"
  cmp -s "$file" <(printf '%s\n' "$canonical")
}

_sgt_transfer_journal_write() {
  local file="$1" response_id="$2" notification_id="$3" spawn_token="$4"
  local generation="$5" session="$6" window="$7" role="$8" command="$9" phase="${10}"
  local pane="${11:-}" identity="${12:-}" previous="" body temporary
  if [[ -e "$file" || -L "$file" ]]; then
    _sgt_transfer_journal_read "$file" || return 1
    [[ "$_SGT_TRANSFER_RESPONSE_ID" == "$response_id" &&
       "$_SGT_TRANSFER_NOTIFICATION_ID" == "$notification_id" &&
       "$_SGT_TRANSFER_SPAWN_TOKEN" == "$spawn_token" &&
       "$_SGT_TRANSFER_GATE_GENERATION" == "$generation" &&
       "$_SGT_TRANSFER_TMUX_SESSION" == "$session" &&
       "$_SGT_TRANSFER_WINDOW_NAME" == "$window" &&
       "$_SGT_TRANSFER_WORKER_ROLE" == "$role" &&
       "$_SGT_TRANSFER_WORKER_COMMAND" == "$command" ]] || return 1
    previous="$_SGT_TRANSFER_PHASE"
    if [[ "$previous" == "$phase" ]]; then
      [[ "$_SGT_TRANSFER_PANE" == "$pane" && "$_SGT_TRANSFER_PANE_AUTH" == "$identity" ]] || return 1
    else
      case "$previous:$phase" in
        bound:fenced|bound:spawning|fenced:spawning|spawning:spawned|\
        spawned:spawning|spawned:published|spawned:acked|published:acked) ;;
        *) return 1 ;;
      esac
    fi
  else
    [[ "$phase" == bound ]] || return 1
  fi
  body="$(_sgt_transfer_journal_render "$response_id" "$notification_id" "$spawn_token" \
    "$generation" "$session" "$window" "$role" "$command" "$phase" "$pane" "$identity")"
  temporary="$file.tmp.$$.$RANDOM"
  _sgt_transfer_io_failpoint "$file" write && return 1
  printf '%s\n' "$body" > "$temporary" || { rm -f "$temporary"; return 1; }
  # Validate the candidate through the same parser before publication.
  _sgt_transfer_journal_read "$temporary" || { rm -f "$temporary"; return 1; }
  _sgt_transfer_io_failpoint "$file" rename && { rm -f "$temporary"; return 1; }
  mv "$temporary" "$file"
}

# ── Action-lease finalization ─────────────────────────────────────────────────
#
# An accepted notification takes an action lease
# (notifications/<id>/action_lease == <nonce>).  The lease is only settled once
# targets/<nonce>/completed exists.  Previously nothing but the delivery loop
# could publish that file, and only when the agent had already written its own
# proof, so every worker-exit path — drained, needs_input, blocked, waiting,
# orphaned — could exit with the lease pending forever.  sgt-respond and
# sgt-recover then refused the lease as prior-supervisor-owned and the worker
# became unrecoverable.
#
# _sgt_finalize_action_lease is the ONE writer of targets/<nonce>/completed.  It
# is called at every worker-exit boundary and at terminal recycling.
#
# It never fabricates completion.  Completion is published only when the agent's
# own durable proof, worktree/.sergeant-notification-complete/<nonce>, contains
# exactly "<notification_id>|<nonce>".  Anything else — a mismatched id, a
# mismatched nonce, a malformed lease, a missing target directory — fails closed
# and is recorded as pending with its reason, so no lease is ever left silently
# outstanding.

# _sgt_action_lease_record <notifications-dir> <name> <body>
# Write a lease outcome record once; never overwrite an existing record so the
# first, most proximate reason survives repeated finalization attempts.
_sgt_transfer_io_failpoint() {
  local target="$1" stage="$2"
  [[ "${SGT_TEST_HOOKS:-}" == 1 &&
     "${SGT_TEST_FAIL_TRANSFER_IO_STAGE:-}" == "$stage" &&
     "${SGT_TEST_FAIL_TRANSFER_IO_TARGET:-}" == "${target##*/}" ]]
}

_sgt_action_lease_record() {
  local notification_dir="$1" name="$2" body="$3" temporary
  [[ -d "$notification_dir" ]] || return 1
  temporary="$notification_dir/$name.tmp.$$.$RANDOM"
  _sgt_transfer_io_failpoint "$notification_dir/$name" write && return 1
  printf '%s' "$body" > "$temporary" || { rm -f "$temporary"; return 1; }
  if [[ -e "$notification_dir/$name" ]]; then
    cmp -s "$temporary" "$notification_dir/$name" || {
      rm -f "$temporary"
      return 1
    }
    rm -f "$temporary"
    return 0
  fi
  if _sgt_transfer_io_failpoint "$notification_dir/$name" rename; then
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$notification_dir/$name" || { rm -f "$temporary"; return 1; }
}

# _sgt_notification_action_completed <repo_state> <notification_id>
# 0 when the lease held for this notification has durable completion evidence.
# Distinct from the delivery handshake, which only proves the nudge landed.
_sgt_notification_action_completed() {
  local repo_state="$1" notification_id="$2" lease
  [[ -n "$notification_id" ]] || return 1
  lease="$(cat "$repo_state/notifications/$notification_id/action_lease" 2>/dev/null || true)"
  [[ -n "$lease" ]] || return 1
  [[ "$(cat "$repo_state/notifications/$notification_id/targets/$lease/completed" \
    2>/dev/null || true)" == "$notification_id|$lease" ]]
}

# _sgt_notification_action_pending <repo_state> <notification_id>
# 0 when a lease is held for this notification and is not yet completed.
_sgt_notification_action_pending() {
  local repo_state="$1" notification_id="$2" lease
  [[ -n "$notification_id" ]] || return 1
  lease="$(cat "$repo_state/notifications/$notification_id/action_lease" 2>/dev/null || true)"
  [[ -n "$lease" ]] || return 1
  ! _sgt_notification_action_completed "$repo_state" "$notification_id"
}

# _sgt_fence_dead_action_lease <repo_state> <worktree> <successor-id> <generation> <reason>
#
# Archive an unfinished action lease only when all three durable ownership
# records for the accepted target bind one old lease generation and both that
# exact target pane and its recorded process are gone. The current fleet pane
# may belong to a later generation and is deliberately not conflated with it.
# A live pane, a reused pane id/PID, or incomplete/mismatched evidence fails
# closed. The old lease and target tree are never removed or marked completed.
_sgt_fence_dead_action_lease() {
  local repo_state="$1" worktree="$2" successor="$3" generation="$4" reason="$5"
  local notification_id lease notification_dir target_dir pane target_identity token
  local owner_pid actual expected_transition existing stamp process_probe

  notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
  [[ -n "$notification_id" ]] || return 1
  notification_dir="$repo_state/notifications/$notification_id"
  lease="$(cat "$notification_dir/action_lease" 2>/dev/null || true)"
  [[ "$lease" =~ ^[a-f0-9]{32}$ && -n "$successor" && "$generation" =~ ^[1-9][0-9]*$ ]] || return 1
  target_dir="$notification_dir/targets/$lease"
  [[ -d "$target_dir" && ! -e "$target_dir/completed" ]] || return 1

  target_identity="$(cat "$target_dir/pane_identity" 2>/dev/null || true)"
  [[ "$target_identity" =~ ^[01]\|%[0-9]+\|[1-9][0-9]*\|[0-9]+\| ]] || return 1
  pane="${target_identity#*|}"
  pane="${pane%%|*}"
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 1
  owner_pid="${target_identity#*|*|}"
  owner_pid="${owner_pid%%|*}"
  token="$notification_id|$lease"
  [[ "$(cat "$target_dir/accepted" 2>/dev/null || true)" == "$token" &&
     "$(cat "$target_dir/delivered" 2>/dev/null || true)" == "$token" ]] || return 1

  # Any resolvable pane is ambiguous: it is either the owner or a reused id.
  command -v tmux >/dev/null 2>&1 || return 1
  if actual="$(_sgt_pane_identity "$pane" 2>/dev/null)" && [[ -n "$actual" ]]; then
    return 1
  fi
  # Any process at the recorded PID is ambiguous (including PID reuse). `ps`
  # distinguishes absence from kill(2)'s EPERM; lack of permission must never be
  # misread as proof of death.
  command -v ps >/dev/null 2>&1 || return 1
  process_probe="$(ps -p "$owner_pid" -o pid= 2>/dev/null || true)"
  [[ -z "${process_probe//[[:space:]]/}" ]] || return 1

  # Re-verify the durable binding immediately before publishing the fence.
  [[ "$(cat "$repo_state/notification_id" 2>/dev/null || true)" == "$notification_id" &&
     "$(cat "$notification_dir/action_lease" 2>/dev/null || true)" == "$lease" &&
     "$(cat "$target_dir/pane_identity" 2>/dev/null || true)" == "$target_identity" &&
     "$(cat "$target_dir/accepted" 2>/dev/null || true)" == "$token" &&
     "$(cat "$target_dir/delivered" 2>/dev/null || true)" == "$token" &&
     ! -e "$target_dir/completed" ]] || return 1
  if actual="$(_sgt_pane_identity "$pane" 2>/dev/null)" && [[ -n "$actual" ]]; then
    return 1
  fi
  process_probe="$(ps -p "$owner_pid" -o pid= 2>/dev/null || true)"
  [[ -z "${process_probe//[[:space:]]/}" ]] || return 1

  stamp="$(sed -n 's/^recorded_at=//p' \
    "$notification_dir/action_lease_abandoned" 2>/dev/null || true)"
  [[ -n "$stamp" ]] || stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  _sgt_action_lease_record "$notification_dir" action_lease_abandoned \
    "$(printf 'notification_id=%s\nlease=%s\nowner_pane=%s\nowner_pid=%s\nowner_identity=%s\nreason=%s; exact pane and process owner proven dead; completion not fabricated\nrecorded_at=%s\n' \
      "$notification_id" "$lease" "$pane" "$owner_pid" "$target_identity" "$reason" "$stamp")" || return 1

  expected_transition="$(printf 'old_notification=%s\nold_lease=%s\nold_owner_identity=%s\nnew_notification=%s\nnew_generation=%s\nreason=%s\n' \
    "$notification_id" "$lease" "$target_identity" "$successor" "$generation" "$reason")"
  if [[ -e "$notification_dir/ownership_transition" ]]; then
    existing="$(cat "$notification_dir/ownership_transition" 2>/dev/null || true)"
    [[ "$existing" == "$expected_transition" ]] || return 1
  else
    _sgt_action_lease_record "$notification_dir" ownership_transition "$expected_transition" || return 1
  fi
}

# _sgt_bind_action_lease_successor <repo_state> <generation>
# Print "successor|spawn-token". The binding is immutable and shared by
# sgt-respond and sgt-recover, so a crash may be resumed through either CLI.
_sgt_bind_action_lease_successor() {
  local repo_state="$1" generation="$2" notification_id lease notification_dir
  local binding successor spawn_token expected
  notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
  lease="$(cat "$repo_state/notifications/$notification_id/action_lease" 2>/dev/null || true)"
  [[ -n "$notification_id" && "$lease" =~ ^[a-f0-9]{32}$ &&
     "$generation" =~ ^[1-9][0-9]*$ ]] || return 1
  notification_dir="$repo_state/notifications/$notification_id"
  binding="$(cat "$notification_dir/successor_binding" 2>/dev/null || true)"
  if [[ -n "$binding" ]]; then
    [[ "$(sed -n 's/^source_notification=//p' <<< "$binding")" == "$notification_id" &&
       "$(sed -n 's/^source_lease=//p' <<< "$binding")" == "$lease" &&
       "$(sed -n 's/^generation=//p' <<< "$binding")" == "$generation" ]] || return 1
    successor="$(sed -n 's/^successor_notification=//p' <<< "$binding")"
    spawn_token="$(sed -n 's/^spawn_token=//p' <<< "$binding")"
    [[ "$successor" =~ ^[a-f0-9]{32}$ && "$spawn_token" =~ ^[a-f0-9]{32}$ ]] || return 1
    printf '%s|%s\n' "$successor" "$spawn_token"
    return 0
  fi
  successor="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  spawn_token="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  expected="$(printf 'source_notification=%s\nsource_lease=%s\ngeneration=%s\nsuccessor_notification=%s\nspawn_token=%s\n' \
    "$notification_id" "$lease" "$generation" "$successor" "$spawn_token")"
  _sgt_action_lease_record "$notification_dir" successor_binding "$expected" || return 1
  printf '%s|%s\n' "$successor" "$spawn_token"
}

# _sgt_finalize_action_lease <repo_state> <worktree> <reason>
#
# 0  the notification has no outstanding lease, or the lease is now completed.
# 1  a lease remains outstanding; the reason is recorded in action_lease_pending.
_sgt_finalize_action_lease() {
  local repo_state="$1" worktree="$2" reason="$3"
  local notification_id lease notification_dir target_dir proof token held status stamp

  [[ -n "$repo_state" && -d "$repo_state" ]] || return 1
  notification_id="$(cat "$repo_state/notification_id" 2>/dev/null || true)"
  # No notification has ever been published: there is nothing to settle.
  [[ -n "$notification_id" ]] || return 0
  notification_dir="$repo_state/notifications/$notification_id"
  [[ -d "$notification_dir" ]] || return 0
  lease="$(cat "$notification_dir/action_lease" 2>/dev/null || true)"
  # No lease was ever taken: delivery may not have been accepted yet, which is
  # not an outstanding action.
  [[ -n "$lease" ]] || return 0

  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  token="$notification_id|$lease"

  if [[ ! "$lease" =~ ^[a-f0-9]{32}$ ]]; then
    _sgt_action_lease_record "$notification_dir" action_lease_pending \
      "$(printf 'notification_id=%s\nlease=%s\nreason=invalid action lease nonce; %s\nrecorded_at=%s\n' \
        "$notification_id" "$lease" "$reason" "$stamp")" || true
    return 1
  fi

  target_dir="$notification_dir/targets/$lease"
  if [[ ! -d "$target_dir" ]]; then
    _sgt_action_lease_record "$notification_dir" action_lease_pending \
      "$(printf 'notification_id=%s\nlease=%s\nreason=action lease names a missing notification target; %s\nrecorded_at=%s\n' \
        "$notification_id" "$lease" "$reason" "$stamp")" || true
    return 1
  fi

  # Already settled: record the outcome once and succeed idempotently.
  if [[ "$(cat "$target_dir/completed" 2>/dev/null || true)" == "$token" ]]; then
    _sgt_action_lease_record "$notification_dir" action_lease_finalized \
      "$(printf 'completed=%s\nreason=%s\nrecorded_at=%s\n' "$token" "$reason" "$stamp")" || true
    return 0
  fi

  # Completion requires the agent's own durable proof for this exact turn.
  proof="$(cat "$worktree/.sergeant-notification-complete/$lease" 2>/dev/null || true)"
  if [[ "$proof" != "$token" ]]; then
    _sgt_action_lease_record "$notification_dir" action_lease_pending \
      "$(printf 'notification_id=%s\nlease=%s\nreason=no matching agent completion proof (identity or nonce mismatch); %s\nexpected=%s\nobserved=%s\nrecorded_at=%s\n' \
        "$notification_id" "$lease" "$reason" "$token" "${proof:-<absent>}" "$stamp")" || true
    return 1
  fi

  # Publish completion under the response lock.  Reentrant: a caller that
  # already holds the lock keeps ownership and is responsible for releasing it.
  held=0
  if [[ -n "${_SGT_RESPONSE_LOCK_DIR:-}" ]]; then
    held=1
  elif _sgt_response_lock_held_by_this_process "$repo_state"; then
    # Another context in this same process holds the lock.  Waiting is futile:
    # the liveness check would see our own live PID forever.  Record the reason
    # and let the exit boundary, which runs after those contexts are gone,
    # reclaim the lock and settle the lease.
    _sgt_action_lease_record "$notification_dir" action_lease_pending \
      "$(printf 'notification_id=%s\nlease=%s\nreason=response lock is held by another context in this process; %s\nrecorded_at=%s\n' \
        "$notification_id" "$lease" "$reason" "$stamp")" || true
    return 1
  elif ! _sgt_response_lock_acquire "$repo_state"; then
    _sgt_action_lease_record "$notification_dir" action_lease_pending \
      "$(printf 'notification_id=%s\nlease=%s\nreason=could not acquire the response lock to finalize; %s\nrecorded_at=%s\n' \
        "$notification_id" "$lease" "$reason" "$stamp")" || true
    return 1
  fi

  status=1
  # Re-verify every premise under the lock: a concurrent supersede may have
  # replaced the notification, the lease, or the proof since the checks above.
  if [[ "$(cat "$repo_state/notification_id" 2>/dev/null || true)" == "$notification_id" &&
        "$(cat "$notification_dir/action_lease" 2>/dev/null || true)" == "$lease" &&
        "$(cat "$worktree/.sergeant-notification-complete/$lease" 2>/dev/null || true)" == "$token" ]]; then
    temporary="$target_dir/completed.tmp.$$.$RANDOM"
    if printf '%s\n' "$token" > "$temporary" && mv "$temporary" "$target_dir/completed"; then
      status=0
    else
      rm -f "$temporary"
    fi
  fi

  if (( held == 0 )); then
    _sgt_response_lock_release || status=1
  fi

  if (( status == 0 )); then
    _sgt_action_lease_record "$notification_dir" action_lease_finalized \
      "$(printf 'completed=%s\nreason=%s\nrecorded_at=%s\n' "$token" "$reason" "$stamp")" || true
    return 0
  fi

  _sgt_action_lease_record "$notification_dir" action_lease_pending \
    "$(printf 'notification_id=%s\nlease=%s\nreason=completion publication failed or was superseded under lock; %s\nrecorded_at=%s\n' \
      "$notification_id" "$lease" "$reason" "$stamp")" || true
  return 1
}
