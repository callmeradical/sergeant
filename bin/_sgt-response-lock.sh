#!/usr/bin/env bash
# Shared serialization and archive format for response publication and consumption.

_SGT_RESPONSE_LOCK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_sgt-bash-version.sh
source "$_SGT_RESPONSE_LOCK_SCRIPT_DIR/_sgt-bash-version.sh"
_sgt_require_running_bash || return 1

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

_sgt_response_lock_acquire() {
  local repo_state="$1"
  local lock_name="${2:-response.lock}"
  local lock_path="$repo_state/$lock_name"
  local candidate="$repo_state/.$lock_name.$$.$RANDOM.$RANDOM"
  local candidate_name="${candidate##*/}"
  local owner current_owner interval
  interval="${SGT_RESPONSE_LOCK_INTERVAL:-0.01}"

  if ! printf '%s\n' "$$" > "$candidate"; then
    printf 'ERROR: Could not create response lock candidate: %s\n' "$candidate" >&2
    return 1
  fi

  while true; do
    if [[ -d "$lock_path" ]]; then
      owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      if [[ -z "$owner" ]]; then
        if [[ -n "$(ls -A "$lock_path" 2>/dev/null)" ]]; then
          rm -f "$candidate"
          printf 'ERROR: Response lock directory has no valid owner: %s\n' "$lock_path" >&2
          return 1
        fi
        if [[ -z "$(find "$lock_path" -prune -mmin +0 -print 2>/dev/null)" ]]; then
          sleep "$interval"
          continue
        fi
      else
        if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
          rm -f "$candidate"
          printf 'ERROR: Response lock directory has an invalid owner: %s\n' "$lock_path" >&2
          return 1
        fi
        if kill -0 "$owner" 2>/dev/null; then
          sleep "$interval"
          continue
        fi
      fi

      current_owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
      if [[ "$current_owner" != "$owner" ]]; then
        continue
      fi
      if [[ -n "$owner" ]] && ! rm -f "$lock_path/pid"; then
        rm -f "$candidate"
        printf 'ERROR: Could not remove stale response lock owner: %s\n' "$lock_path/pid" >&2
        return 1
      fi
      if ! rmdir "$lock_path" 2>/dev/null; then
        rm -f "$candidate"
        printf 'ERROR: Could not recover response lock directory: %s\n' "$lock_path" >&2
        return 1
      fi
      continue
    fi

    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
      owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      if [[ -z "$owner" ]]; then
        # Lock file disappeared between the -e check and the read (TOCTOU: just released).
        # Retry; the next iteration will find the file gone and attempt ln.
        continue
      fi
      if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
        rm -f "$candidate"
        printf 'ERROR: Response lock has an invalid owner: %s\n' "$lock_path" >&2
        return 1
      fi
      if kill -0 "$owner" 2>/dev/null; then
        sleep "$interval"
        continue
      fi
      current_owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
      if [[ "$current_owner" == "$owner" ]]; then
        if ! rm -f "$lock_path"; then
          rm -f "$candidate"
          printf 'ERROR: Could not remove stale response lock: %s\n' "$lock_path" >&2
          return 1
        fi
      fi
      continue
    fi

    if ln "$candidate" "$lock_path" 2>/dev/null; then
      if [[ "$lock_path" -ef "$candidate" ]]; then
        rm -f "$candidate"
        _SGT_RESPONSE_LOCK_DIR="$lock_path"
        return 0
      fi
      rm -f "$lock_path/$candidate_name"
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
  if [[ "$owner" == "$$" ]]; then
    if ! rm -f "$_SGT_RESPONSE_LOCK_DIR"; then
      printf 'ERROR: Could not release response lock: %s\n' "$_SGT_RESPONSE_LOCK_DIR" >&2
      return 1
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
}

# _sgt_response_lock_reclaim <repo_state> [lock_name]
#
# Drop a response lock whose recorded owner is THIS process.
#
# The lock records "$$", which in Bash is the shell's PID and is therefore
# identical in every subshell of the same process.  A background loop killed
# while holding the lock leaves a record naming a PID that is still very much
# alive, so _sgt_response_lock_acquire's liveness check would spin forever.
#
# Only call this once every other context in this process that could hold the
# lock has been terminated; otherwise it would break mutual exclusion.
_sgt_response_lock_reclaim() {
  local repo_state="$1"
  local lock_path="$repo_state/${2:-response.lock}"
  local owner

  if [[ -d "$lock_path" ]]; then
    owner="$(cat "$lock_path/pid" 2>/dev/null || true)"
    if [[ "$owner" == "$$" ]]; then
      rm -f "$lock_path/pid" 2>/dev/null || true
      rmdir "$lock_path" 2>/dev/null || true
    fi
  elif [[ -e "$lock_path" || -L "$lock_path" ]]; then
    owner="$(cat "$lock_path" 2>/dev/null || readlink "$lock_path" 2>/dev/null || true)"
    if [[ "$owner" == "$$" ]]; then
      rm -f "$lock_path" 2>/dev/null || true
    fi
  fi
  _SGT_RESPONSE_LOCK_DIR=""
}

# _sgt_response_lock_held_by_this_process <repo_state> [lock_name]
# 0 when the lock exists and names this process, but this context does not own
# it.  Waiting on such a lock can never succeed.
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
  [[ "$owner" == "$$" ]]
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
_sgt_action_lease_record() {
  local notification_dir="$1" name="$2" body="$3" temporary
  [[ -d "$notification_dir" ]] || return 1
  [[ ! -e "$notification_dir/$name" ]] || return 0
  temporary="$notification_dir/$name.tmp.$$.$RANDOM"
  printf '%s' "$body" > "$temporary" || { rm -f "$temporary"; return 1; }
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
