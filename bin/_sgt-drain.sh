#!/usr/bin/env bash
# _sgt-drain.sh — Drain state helpers sourced by sgt-* scripts.
# Source this file; do not execute it directly.
#
# Provides: _sgt_is_drained, _sgt_drain_state_dir,
#           _sgt_drain_global_file, _sgt_drain_project_file,
#           _sgt_drain_is_drained (file-path variant),
#           _sgt_drain_write, _sgt_drain_global_active,
#           _sgt_drain_project_active,
#           _sgt_drain_clear, _sgt_drain_read_field,
#           _sgt_drain_lock_file, _sgt_drain_lock_record,
#           _sgt_drain_host_id, _sgt_drain_process_alive,
#           _sgt_drain_process_start,
#           _sgt_drain_lock_acquire_fd, _sgt_drain_lock_release_fd,
#           _sgt_drain_check_admission_locked, _sgt_drain_run_locked,
#           _sgt_drain_remove_global, _sgt_drain_remove_project
#
# Drain state location: $SERGEANT_CONFIG/drain/
#   Global drain:  $SERGEANT_CONFIG/drain/global
#   Project drain: $SERGEANT_CONFIG/drain/<project>
#
# Drain file format (plain text, key=value lines):
#   reason=<text>     optional
#   actor=<text>      optional
#   created_at=<ISO-8601 timestamp>  always present

[[ "${SGT_DRAIN_LIB_LOADED:-}" == "1" ]] && return 0
SGT_DRAIN_LIB_LOADED=1

_sgt_drain_state_dir() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s\n' "$SERGEANT_DRAIN_DIR"
  else
    printf '%s\n' "${SERGEANT_CONFIG:-$HOME/.config/sergeant}/drain"
  fi
}

# _sgt_drain_dir — alias for _sgt_drain_state_dir
_sgt_drain_dir() {
  _sgt_drain_state_dir
}

# _sgt_drain_lock_file
#
# Prints the path to the drain admission lock file.
_sgt_drain_lock_file() {
  printf '%s/admission.lock\n' "$(_sgt_drain_state_dir)"
}

# _sgt_drain_global_file
#
# Prints the path to the global drain file.
# When SERGEANT_DRAIN_DIR is set uses a subdirectory layout.
_sgt_drain_global_file() {
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s/global/drain\n' "$(_sgt_drain_state_dir)"
  else
    printf '%s/global\n' "$(_sgt_drain_state_dir)"
  fi
}

# _sgt_drain_project_file <project>
#
# Prints the path to the per-project drain file.
# When SERGEANT_DRAIN_DIR is set uses a subdirectory layout.
_sgt_drain_project_file() {
  local project="${1:?_sgt_drain_project_file requires a project name}"
  if [[ -n "${SERGEANT_DRAIN_DIR:-}" ]]; then
    printf '%s/projects/%s/drain\n' "$(_sgt_drain_state_dir)" "$project"
  else
    printf '%s/%s\n' "$(_sgt_drain_state_dir)" "$project"
  fi
}

# _sgt_drain_read_project_from_brief <task_dir>
#
# Extracts and validates the project name from the fleet brief.md file
# ($task_dir/brief.md).  Sets the global SGT_PROJECT variable.
# If the file is absent or the name is invalid, SGT_PROJECT is left empty.
_sgt_drain_read_project_from_brief() {
  local task_dir="$1" project
  # shellcheck disable=SC2034  # SGT_PROJECT is consumed by sourcing scripts.
  SGT_PROJECT=""
  [[ -f "$task_dir/brief.md" ]] || return 0
  project="$(sed -n 's/^Project:[[:space:]]*//p' "$task_dir/brief.md")"
  [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 0
  # shellcheck disable=SC2034  # SGT_PROJECT is consumed by sourcing scripts.
  SGT_PROJECT="$project"
}

# _sgt_is_drained <project>
#
# Returns 0 (true) if a global drain or a matching project drain is active.
# Returns 1 (false) otherwise — admission proceeds normally.
#
# A project name of "" or a name that does not match [A-Za-z0-9][A-Za-z0-9._-]*
# is treated as absent; only the global drain is checked in that case.
_sgt_is_drained() {
  local project="${1:-}"
  _sgt_drain_is_drained "$(_sgt_drain_global_file)" && return 0
  if [[ -n "$project" && "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")" && return 0
  fi
  return 1
}

# ── Drain admission lock helpers ──────────────────────────────────────────────
#
# These functions implement the drain-admission lock used by sgt-respond and
# sgt-dispatch to serialize the "read drain state → start new pane" window so a
# concurrent sgt-drain cannot slip in between, and by sgt-drain itself to
# read-then-write drain state atomically.
#
# Outcome contract — shared by _sgt_drain_lock_acquire_fd and
# _sgt_drain_run_locked.  Callers can tell all three cases apart:
#
#   0  acquired     the lock is held        SGT_DRAIN_LOCK_STATE=acquired
#   2  timeout      another owner holds it  SGT_DRAIN_LOCK_STATE=timeout
#   3  unavailable  no usable lock location SGT_DRAIN_LOCK_STATE=unavailable
#
# A nonzero return ALWAYS means the lock is not held.  No path returns success
# without exclusion, so a caller can never proceed silently unlocked.
#
# Exclusion is a hard link, not flock(1).  flock is absent from macOS system
# installs and limited on BusyBox, and guarding it with `command -v flock`
# previously meant the whole lock silently degraded to a no-op.  link(2) fails
# atomically when the target exists, is available everywhere Sergeant runs, and
# — unlike mkdir — publishes the lock together with its owner record in one
# atomic step, so the lock can never exist in an unattributable state that no
# later contender is able to reclaim.
#
# Every lock instance carries a nonce.  Reclamation and release are both bound
# to that nonce, so a contender can neither destroy a lock that was reacquired
# while it was deciding, nor release a lock it no longer owns.
#
# Usage pattern (mirroring sgt-respond):
#   _sgt_drain_lock_acquire_fd N [purpose]        # 0 = held; 2/3 = not held
#   _sgt_drain_check_admission_locked [project]   # 0 = admit, 1 = draining
#   ... spawn new pane ...
#   _sgt_drain_lock_release_fd N                  # release
#
# The <fd> argument is an opaque per-process handle: it names which acquisition
# a later release refers to.  It is no longer a file descriptor carrying kernel
# state, because ownership is proven by the on-disk record instead.
#
# NOTE: because release is explicit rather than kernel-backed, a holder killed
# mid-flight leaves its record behind.  That is safe: the record always names a
# verifiable owner, so the next contender reclaims it automatically.  No EXIT
# trap is installed here on purpose — this library is sourced by scripts that
# own their own traps.

# _sgt_drain_lock_record
#
# Prints the path of the lock record that provides the actual exclusion.  Its
# contents are the owner record.
_sgt_drain_lock_record() {
  printf '%s.held\n' "$(_sgt_drain_lock_file)"
}

# _sgt_drain_host_id
#
# Prints a host identifier, or nothing when the host cannot be identified.
# Owner liveness can only be verified on the host that recorded the lock, so an
# empty result must be treated as unverifiable rather than as a match.
_sgt_drain_host_id() {
  uname -n 2>/dev/null || true
}

# _sgt_drain_nonce
#
# Prints a unique token identifying one lock acquisition.
_sgt_drain_nonce() {
  local token
  token="$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
  [[ "$token" =~ ^[0-9a-f]{16}$ ]] || return 1
  printf '%s\n' "$token"
}

# _sgt_drain_process_alive <pid>
#
# Returns 0 when the process exists, 1 when it PROVABLY does not, and 2 when
# liveness cannot be determined.  Callers must treat 2 as "still alive" so an
# unverifiable owner is never displaced.
#
# /proc is authoritative on Linux and BusyBox — where `ps -p` does not exist —
# and `kill -0` alone is not, because it also fails with EPERM for a live
# process owned by another user.
_sgt_drain_process_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if [[ -d /proc/self ]]; then
    [[ -d "/proc/$pid" ]] && return 0
    return 1
  fi
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1 && return 0
  # Without a usable ps, an EPERM from kill -0 is indistinguishable from death.
  ps -p "$$" >/dev/null 2>&1 || return 2
  return 1
}

# _sgt_drain_process_start <pid>
#
# Prints the shared exact process identity used to detect PID reuse, or nothing
# when the platform cannot provide that identity.
_sgt_drain_process_start() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  declare -F _sgt_process_identity >/dev/null 2>&1 || return 0
  _sgt_process_identity "$pid" 2>/dev/null || true
}

# _sgt_drain_legacy_process_start <pid>
#
# Reads the historical `ps lstart` representation without `ps -p`, which is
# absent from BusyBox. This value is compatibility evidence only: its
# second-resolution timestamp is never promoted to an exact process identity.
# Callers must retain a live PID when the field is unsupported or differs.
_sgt_drain_legacy_process_start() {
  local pid="$1" table value
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  table="$(ps -o pid=,lstart= 2>/dev/null)" || return 1
  value="$(printf '%s\n' "$table" | awk -v target="$pid" '
    $1 == target {
      $1 = ""
      sub(/^[[:space:]]+/, "")
      value = $0
      count++
    }
    END {
      if (count == 1 && value != "") print value
      else exit 1
    }
  ')" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

# _sgt_drain_snapshot_field <snapshot> <field>
#
# Reads one field from an already-captured record body, so a whole record can be
# parsed from a single read.
_sgt_drain_snapshot_field() {
  printf '%s\n' "$1" | grep -m1 "^${2}=" | cut -d= -f2- || true
}

# _sgt_drain_record_line <field> <value>
#
# Emits one record line with the value forced onto a single line.  Every value
# must be sanitised: a newline in USER, in `uname -n`, or in a process start
# token would inject additional fields, and an injected owner_nonce read first
# by grep -m1 would stop the true owner from ever releasing its own lock.
_sgt_drain_record_line() {
  local field="$1" value="$2"
  value="$(printf '%s' "$value" | tr -d '\n\r' | cut -c1-256)"
  printf '%s=%s\n' "$field" "$value"
}

# _sgt_drain_lock_owner_is_gone <record>
#
# Returns 0 only when the recorded owner is PROVABLY gone: an identified host
# matching this one, and a pid that either no longer exists or has been reused
# by a different process.  Anything unverifiable — an unidentified host, a
# foreign host, a missing or malformed record, or an undeterminable liveness —
# returns 1 so a live lock is never stolen.
#
# On success the observed owner_nonce is published in _SGT_DRAIN_OBSERVED_NONCE
# so the caller can bind its reclamation to this exact lock instance.
_sgt_drain_lock_owner_is_gone() {
  local record="$1"
  local snapshot pid host nonce local_host recorded_start actual_start alive_rc
  _SGT_DRAIN_OBSERVED_NONCE=""
  [[ -f "$record" ]] || return 1

  # Read the record ONCE.  Field-at-a-time reads would each re-open the path, so
  # a competing reclaimer renaming the record mid-check could hand back fields
  # from different generations — including an empty nonce, which used to make
  # reclamation unbounded.
  snapshot="$(cat "$record" 2>/dev/null || true)"
  [[ -n "$snapshot" ]] || { exec 5<&-; return 1; }

  host="$(_sgt_drain_snapshot_field "$snapshot" owner_host)"
  local_host="$(_sgt_drain_host_id)"
  # An unidentified host must never compare equal to another unidentified host.
  [[ -n "$host" && -n "$local_host" && "$host" == "$local_host" ]] || return 1

  pid="$(_sgt_drain_snapshot_field "$snapshot" owner_pid)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  # A record without a nonce cannot be bound to a reclamation, so it is
  # unverifiable — never reclaimable.  Treating it as reclaimable would let a
  # contender delete a lock legitimately acquired during the race.
  nonce="$(_sgt_drain_snapshot_field "$snapshot" owner_nonce)"
  [[ -n "$nonce" ]] || return 1

  alive_rc=0
  _sgt_drain_process_alive "$pid" || alive_rc=$?
  if [[ $alive_rc -eq 1 ]]; then
    _SGT_DRAIN_OBSERVED_NONCE="$nonce"
    return 0
  fi
  [[ $alive_rc -eq 0 ]] || return 1

  # The pid exists: only a changed start token proves it is a different process.
  recorded_start="$(_sgt_drain_snapshot_field "$snapshot" owner_start)"
  actual_start="$(_sgt_drain_process_start "$pid")"
  if [[ -n "$recorded_start" && -n "$actual_start" && "$actual_start" != "$recorded_start" ]]; then
    _SGT_DRAIN_OBSERVED_NONCE="$nonce"
    return 0
  fi
  return 1
}

# True only for a complete same-host record whose PID is live and whose exact
# process birth identity still matches. Ambiguous or legacy records are not
# evidence that a peer transaction ran.
_sgt_drain_lock_owner_is_verified_live() {
  local record="$1" snapshot pid host nonce recorded_start actual_start alive_rc=0
  _SGT_DRAIN_VERIFIED_LIVE_NONCE=""
  [[ -f "$record" ]] || return 1
  exec 5< "$record" || return 1
  [[ "/proc/self/fd/5" -ef "$record" ]] || { exec 5<&-; return 1; }
  snapshot="$(cat <&5 2>/dev/null || true)"
  [[ -n "$snapshot" ]] || return 1
  printf '%s\n' "$snapshot" | awk -F= '
    BEGIN { required["owner_pid"]; required["owner_start"]; required["owner_host"];
      required["owner_user"]; required["owner_purpose"]; required["owner_nonce"];
      required["created_at"]; required["created_epoch"] }
    !($1 in required) || substr($0, length($1) + 2) == "" { exit 1 }
    { seen[$1]++ }
    END { if (length(seen) != 8) exit 1; for (key in required) if (seen[key] != 1) exit 1 }
  ' || { exec 5<&-; return 1; }
  host="$(_sgt_drain_snapshot_field "$snapshot" owner_host)"
  [[ -n "$host" && "$host" == "$(_sgt_drain_host_id)" ]] || { exec 5<&-; return 1; }
  pid="$(_sgt_drain_snapshot_field "$snapshot" owner_pid)"
  nonce="$(_sgt_drain_snapshot_field "$snapshot" owner_nonce)"
  recorded_start="$(_sgt_drain_snapshot_field "$snapshot" owner_start)"
  [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$nonce" && -n "$recorded_start" ]] || { exec 5<&-; return 1; }
  _sgt_drain_process_alive "$pid" || alive_rc=$?
  [[ $alive_rc -eq 0 ]] || { exec 5<&-; return 1; }
  actual_start="$(_sgt_drain_process_start "$pid")"
  [[ -n "$actual_start" && "$actual_start" == "$recorded_start" && \
    "/proc/self/fd/5" -ef "$record" ]] || { exec 5<&-; return 1; }
  _SGT_DRAIN_VERIFIED_LIVE_NONCE="$nonce"
  exec 5<&-
  return 0
}

_sgt_worker_launch_transaction_begin() {
  local repo="$1" fd="$2" before
  before="$(_sgt_worker_process_marker_state_digest "$repo")" || return 1
  [[ "$before" == absent || "$before" =~ ^[0-9a-f]{64}$ ]] || return 1
  eval "_SGT_WORKER_LAUNCH_BEFORE_${fd}=\$before"
}

_sgt_worker_launch_completion_publish() {
  local repo="$1" fd="$2" nonce before after
  eval "nonce=\${_SGT_DRAIN_LOCK_NONCE_${fd}:-}"
  eval "before=\${_SGT_WORKER_LAUNCH_BEFORE_${fd}:-}"
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 1
  [[ "$before" == absent || "$before" =~ ^[0-9a-f]{64}$ ]] || return 1
  after="$(_sgt_worker_process_marker_state_digest "$repo")" || return 1
  [[ "$after" =~ ^[0-9a-f]{64}$ && "$before" != "$after" ]] || return 1
  _sgt_replace_owned_file "$repo/worker-launch.completed" "$nonce|$before|$after"
}

_sgt_worker_launch_observed_completion_matches() {
  local repo="$1" record nonce before after current_digest extra
  nonce="${SGT_DRAIN_LOCK_CONTENDED_NONCE:-}"
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 1
  record="$(_sgt_read_owned_file "$repo/worker-launch.completed" 2>/dev/null || true)"
  IFS='|' read -r record_nonce before after extra <<< "$record"
  [[ -z "$extra" && "$record_nonce" == "$nonce" && \
    ( "$before" == absent || "$before" =~ ^[0-9a-f]{64}$ ) && \
    "$after" =~ ^[0-9a-f]{64}$ && "$before" != "$after" ]] || return 1
  current_digest="$(_sgt_worker_process_marker_state_digest "$repo")" || return 1
  [[ "$current_digest" == "$after" ]]
}

_sgt_worker_launch_sha256() {
  _sgt_sha256_stream
}

# _sgt_drain_lock_reclaim <record> <expected_nonce>
#
# Reclaims a lock proven stale, but only that exact instance.  The record is
# renamed first, because rename is atomic: at most one contender can move it.
# The nonce is then re-checked, so a lock that was legitimately reacquired
# between the staleness decision and the rename is restored instead of deleted.
_sgt_drain_lock_reclaim() {
  local record="$1" expected_nonce="$2" quarantine observed
  # Without a nonce there is nothing to bind the reclamation to, so refuse
  # rather than delete whatever happens to occupy the path.
  [[ -n "$expected_nonce" ]] || return 1
  quarantine="${record}.stale.$$"
  rm -f "$quarantine" 2>/dev/null || true
  mv "$record" "$quarantine" 2>/dev/null || return 1

  observed="$(_sgt_drain_read_field "$quarantine" owner_nonce)"
  if [[ "$observed" != "$expected_nonce" ]]; then
    # A different lock instance than the one proven stale — put it back.  ln
    # refuses to clobber, so a third party that has already taken the lock keeps
    # it.  The quarantine copy is discarded only once the record is back in
    # place (by us or by that third party); otherwise it is the ONLY copy of a
    # live record and must be kept for the next contender to find.
    if ln "$quarantine" "$record" 2>/dev/null || [[ -e "$record" ]]; then
      rm -f "$quarantine" 2>/dev/null || true
    else
      printf 'ERROR: could not restore drain admission lock record %s; preserved at %s\n' \
        "$record" "$quarantine" >&2
    fi
    return 1
  fi
  rm -f "$quarantine" 2>/dev/null || true
  return 0
}

# _sgt_drain_lock_sweep_artifacts <record>
#
# Removes quarantine copies left by a reclaimer that died mid-rename, and
# staging records left by an acquirer killed while contending.  Both embed their
# owning pid, and only artifacts whose owner is provably gone are removed, so a
# concurrent reclamation or acquisition is never disturbed.  Without this, a
# Ctrl-C during contention would leave a staging file in shared state forever.
_sgt_drain_lock_sweep_artifacts() {
  local record="$1" leftover leftover_pid rc
  for leftover in "$record".stale.* "$record".staging.*; do
    [[ -e "$leftover" ]] || continue
    case "$leftover" in
      *.stale.*)   leftover_pid="${leftover##*.stale.}" ;;
      *.staging.*) leftover_pid="${leftover##*.staging.}"
                   leftover_pid="${leftover_pid%%.*}" ;;
      *)           continue ;;
    esac
    case "$leftover_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    rc=0
    _sgt_drain_process_alive "$leftover_pid" || rc=$?
    [[ $rc -eq 1 ]] || continue
    rm -f "$leftover" 2>/dev/null || true
  done
}

# _sgt_drain_lock_report_timeout <record>
#
# Reports who holds the lock, for how long, and why, plus the exact recovery
# command — an undiagnosable "could not acquire lock" is not actionable.
_sgt_drain_lock_report_timeout() {
  local record="$1"
  local pid user host purpose created epoch age
  local waited="${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10}"
  if [[ -f "$record" ]]; then
    pid="$(_sgt_drain_read_field "$record" owner_pid)"
    user="$(_sgt_drain_read_field "$record" owner_user)"
    host="$(_sgt_drain_read_field "$record" owner_host)"
    purpose="$(_sgt_drain_read_field "$record" owner_purpose)"
    created="$(_sgt_drain_read_field "$record" created_at)"
    epoch="$(_sgt_drain_read_field "$record" created_epoch)"
    age="unknown"
    case "$epoch" in
      ''|*[!0-9]*) : ;;
      *) age="$(( $(date +%s) - epoch ))s" ;;
    esac
    printf 'ERROR: could not acquire drain admission lock after %ss: held by owner_pid=%s user=%s host=%s purpose=%s since=%s age=%s\n' \
      "$waited" "$pid" "$user" "$host" "$purpose" "$created" "$age" >&2
    printf 'ERROR: retry when that process finishes; a lock whose owner has died is reclaimed automatically on the next attempt.\n' >&2
  else
    printf 'ERROR: could not acquire drain admission lock after %ss: contended at %s\n' \
      "$waited" "$record" >&2
  fi
}

# _sgt_drain_lock_acquire_fd <fd> [purpose]
#
# Acquires the drain admission lock.  See the outcome contract above:
# 0 = acquired, 2 = timeout, 3 = unavailable.
_sgt_drain_lock_acquire_fd() {
  local fd="${1:?_sgt_drain_lock_acquire_fd requires an fd}"
  local purpose="${2:-}"
  local record_override="${3:-}"
  local record state_dir deadline nonce staging

  SGT_DRAIN_LOCK_STATE="unavailable"
  SGT_DRAIN_LOCK_CONTENDED_LIVE=false
  SGT_DRAIN_LOCK_CONTENDED_NONCE=""
  case "$fd" in
    ''|*[!0-9]*)
      printf 'ERROR: invalid drain admission lock handle: %s\n' "$fd" >&2
      return 3
      ;;
  esac
  [[ -n "$purpose" ]] || purpose="${0##*/}"
  purpose="$(printf '%s' "$purpose" | tr -d '\n\r')"

  record="${record_override:-$(_sgt_drain_lock_record)}"
  state_dir="$(dirname "$record")"
  if ! nonce="$(_sgt_drain_nonce)"; then
    printf 'ERROR: drain admission lock unavailable: secure entropy read failed\n' >&2
    return 3
  fi
  if [[ -e "$state_dir" && ! -d "$state_dir" ]]; then
    printf 'ERROR: drain admission lock unavailable: %s exists but is not a directory\n' \
      "$state_dir" >&2
    return 3
  fi
  if ! mkdir -p "$state_dir" 2>/dev/null || [[ ! -w "$state_dir" ]]; then
    printf 'ERROR: drain admission lock unavailable: %s is not writable\n' "$state_dir" >&2
    return 3
  fi

  _sgt_drain_lock_sweep_artifacts "$record"

  staging="${record}.staging.$$.$nonce"
  # The record is complete BEFORE it becomes the lock, so the lock is never
  # visible without the owner state needed to verify or reclaim it.
  if ! {
    _sgt_drain_record_line owner_pid      "$$"
    _sgt_drain_record_line owner_start    "$(_sgt_drain_process_start "$$")"
    _sgt_drain_record_line owner_host     "$(_sgt_drain_host_id)"
    _sgt_drain_record_line owner_user     "${USER:-$(id -un 2>/dev/null || printf 'unknown')}"
    _sgt_drain_record_line owner_purpose  "$purpose"
    _sgt_drain_record_line owner_nonce    "$nonce"
    _sgt_drain_record_line created_at     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _sgt_drain_record_line created_epoch  "$(date +%s)"
  } > "$staging" 2>/dev/null; then
    rm -f "$staging" 2>/dev/null || true
    printf 'ERROR: drain admission lock unavailable: cannot stage owner record at %s\n' \
      "$staging" >&2
    return 3
  fi

  deadline=$(( $(date +%s) + ${SERGEANT_DRAIN_LOCK_TIMEOUT_SECS:-10} ))
  while :; do
    if ln "$staging" "$record" 2>/dev/null; then
      rm -f "$staging" 2>/dev/null || true
      eval "_SGT_DRAIN_LOCK_HELD_${fd}=1"
      eval "_SGT_DRAIN_LOCK_PATH_${fd}=\$record"
      eval "_SGT_DRAIN_LOCK_NONCE_${fd}=\$nonce"
      SGT_DRAIN_LOCK_STATE="acquired"
      return 0
    fi
    # `ln` failing while the target does NOT exist is not contention: the
    # filesystem cannot make hard links (FAT/exFAT, some CIFS and FUSE mounts).
    # Spinning to the deadline and reporting "contended" would send the operator
    # after a holder that does not exist.
    if [[ ! -e "$record" ]]; then
      rm -f "$staging" 2>/dev/null || true
      printf 'ERROR: drain admission lock unavailable: %s cannot create hard links, which the lock requires\n' \
        "$state_dir" >&2
      return 3
    fi
    if _sgt_drain_lock_owner_is_gone "$record"; then
      _sgt_drain_lock_reclaim "$record" "$_SGT_DRAIN_OBSERVED_NONCE" && continue
    fi
    if _sgt_drain_lock_owner_is_verified_live "$record"; then
      SGT_DRAIN_LOCK_CONTENDED_LIVE=true
      [[ -n "$SGT_DRAIN_LOCK_CONTENDED_NONCE" ]] || \
        SGT_DRAIN_LOCK_CONTENDED_NONCE="$_SGT_DRAIN_VERIFIED_LIVE_NONCE"
      if [[ "${SGT_TEST_HOOKS:-}" == 1 && \
        -n "${_SGT_TEST_DRAIN_LOCK_CONTENDED_MARKER:-}" && \
        "${_SGT_TEST_DRAIN_LOCK_CONTENDED_MARKER%/*}" == "$state_dir" && \
        ! -e "$_SGT_TEST_DRAIN_LOCK_CONTENDED_MARKER" && \
        ! -L "$_SGT_TEST_DRAIN_LOCK_CONTENDED_MARKER" ]]; then
        (umask 077; : > "$_SGT_TEST_DRAIN_LOCK_CONTENDED_MARKER") || return 3
      fi
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      rm -f "$staging" 2>/dev/null || true
      # shellcheck disable=SC2034  # Read by callers as part of the outcome contract.
      SGT_DRAIN_LOCK_STATE="timeout"
      _sgt_drain_lock_report_timeout "$record"
      return 2
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
}

# _sgt_drain_lock_release_fd <fd>
#
# Releases a lock acquired through <fd>.  The on-disk nonce is verified first,
# so this can never remove a lock that now belongs to another process — for
# example after an operator removed the record by hand and someone else took
# it.  Returns nonzero, keeping the handle marked, when the lock is still
# present but could not be removed.
_sgt_drain_lock_release_fd() {
  local fd="${1:?_sgt_drain_lock_release_fd requires an fd}"
  local held record nonce observed
  case "$fd" in
    ''|*[!0-9]*) return 0 ;;
  esac
  eval "held=\${_SGT_DRAIN_LOCK_HELD_${fd}:-}"
  [[ "$held" == "1" ]] || return 0
  eval "record=\${_SGT_DRAIN_LOCK_PATH_${fd}:-}"
  eval "nonce=\${_SGT_DRAIN_LOCK_NONCE_${fd}:-}"

  if [[ -z "$record" || ! -e "$record" ]]; then
    _sgt_drain_lock_forget_handle "$fd"
    return 0
  fi

  observed="$(_sgt_drain_read_field "$record" owner_nonce)"
  if [[ "$observed" != "$nonce" ]]; then
    printf 'ERROR: drain admission lock %s is no longer held by this process; leaving it in place\n' \
      "$record" >&2
    _sgt_drain_lock_forget_handle "$fd"
    return 1
  fi

  rm -f "$record" 2>/dev/null || true
  if [[ -e "$record" ]]; then
    printf 'ERROR: could not release drain admission lock %s\n' "$record" >&2
    return 1
  fi
  _sgt_drain_lock_forget_handle "$fd"
  return 0
}

# _sgt_drain_lock_forget_handle <fd>
#
# Clears the bookkeeping for one lock handle.
_sgt_drain_lock_forget_handle() {
  local fd="$1"
  eval "unset _SGT_DRAIN_LOCK_HELD_${fd} _SGT_DRAIN_LOCK_PATH_${fd} _SGT_DRAIN_LOCK_NONCE_${fd}"
  return 0
}

# _sgt_drain_check_admission_locked [project]
#
# Must be called while the drain admission lock is held (after a successful
# _sgt_drain_lock_acquire_fd).  Returns 0 if admission is allowed (no active
# drain), 1 if a drain is active.
_sgt_drain_check_admission_locked() {
  local project="${1:-}"
  if _sgt_drain_is_drained "$(_sgt_drain_global_file)"; then
    printf 'ERROR: dispatch rejected: global drain is active\n' >&2
    return 1
  fi
  if [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"; then
    printf 'ERROR: dispatch rejected: project drain is active for %s\n' "$project" >&2
    return 1
  fi
  return 0
}

# Internal handle used by the command-running lock wrapper below.
_SGT_DRAIN_LOCK_INTERNAL_FD=200

# _sgt_drain_run_locked <command> [args...]
#
# Runs a command with its arguments while holding the admission lock, then
# releases it and returns the command's exit status.  Arguments are passed as
# argv, so caller-supplied text (a drain reason, a path) is never re-parsed by
# the shell.
#
# When the lock could not be acquired the command does NOT run and the lock
# outcome (2 timeout, 3 unavailable) is returned.  Because a wrapped command may
# itself exit 2 or 3, SGT_DRAIN_LOCK_STATE is the authoritative lock outcome for
# callers that need to distinguish the two.
_sgt_drain_run_locked() {
  local rc=0 acquired=0
  # Misuse must not report success: an empty invocation never held the lock.
  [[ $# -ge 1 ]] || {
    printf 'ERROR: _sgt_drain_run_locked requires a command\n' >&2
    return 3
  }
  _sgt_drain_lock_acquire_fd "$_SGT_DRAIN_LOCK_INTERNAL_FD" "${0##*/}" || acquired=$?
  [[ $acquired -eq 0 ]] || return $acquired
  "$@" || rc=$?
  _sgt_drain_lock_release_fd "$_SGT_DRAIN_LOCK_INTERNAL_FD" || true
  return $rc
}

# ── File-path helpers ─────────────────────────────────────────────────────────

# _sgt_drain_is_drained <drain_file>
#
# File-path variant: returns 0 if the given drain file exists, 1 otherwise.
# Used by sgt-interactive-worker which already resolved the file path.
_sgt_drain_is_drained() {
  [[ -f "${1:?_sgt_drain_is_drained requires a drain file path}" ]]
}

# _sgt_drain_read_field <drain_file> <field>
#
# Reads a single field value from a drain file.  Returns empty string if the
# file is absent or the field is not present.
_sgt_drain_read_field() {
  local file="$1" field="$2"
  grep -m1 "^${field}=" "$file" 2>/dev/null | cut -d= -f2- || true
}

# _sgt_drain_write <drain_file> [reason] [actor] [deadline]
#
# Creates a drain file atomically using a tmp+mv pattern.  The caller must
# have already resolved the drain file path (e.g. via _sgt_drain_global_file
# or _sgt_drain_project_file).  reason, actor, and deadline are optional fields
# recorded in the drain file for human inspection; drain activation is based
# solely on file existence.
_sgt_drain_write() {
  local drain_file="${1:?_sgt_drain_write requires a drain file path}"
  local reason="${2:-}"
  local actor="${3:-}"
  local deadline="${4:-}"
  local temporary
  mkdir -p "$(dirname "$drain_file")" 2>/dev/null || true
  temporary="$(mktemp "${drain_file}.tmp.XXXXXX")"
  {
    [[ -z "$reason" ]] || printf 'reason=%s\n' "$reason"
    [[ -z "$actor" ]] || printf 'actor=%s\n' "$actor"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$deadline" ]] || printf 'deadline=%s\n' "$deadline"
  } > "$temporary"
  mv "$temporary" "$drain_file"
}

# _sgt_drain_clear <drain_file>
#
# Removes the drain file if it exists.  Idempotent.
_sgt_drain_clear() {
  rm -f "${1:?_sgt_drain_clear requires a drain file path}"
}

# _sgt_drain_global_active
#
# Returns 0 (true) when a global drain file is present, 1 otherwise.
_sgt_drain_global_active() {
  _sgt_drain_is_drained "$(_sgt_drain_global_file)"
}

# _sgt_drain_project_active <project>
#
# Returns 0 (true) when a per-project drain file is present for <project>,
# 1 otherwise.
_sgt_drain_project_active() {
  local project="${1:?_sgt_drain_project_active requires a project name}"
  [[ -n "$project" ]] && _sgt_drain_is_drained "$(_sgt_drain_project_file "$project")"
}

# _sgt_drain_remove_global
#
# Removes the global drain file under the drain admission lock.  Safe to call when
# no drain is active (idempotent).
_sgt_drain_remove_global() {
  local drain_file
  drain_file="$(_sgt_drain_global_file)"
  _sgt_drain_run_locked rm -f "$drain_file"
}

# _sgt_drain_remove_project <project>
#
# Removes the per-project drain file under the drain admission lock.  The project
# name must already be validated by the caller.
_sgt_drain_remove_project() {
  local project="${1:?_sgt_drain_remove_project requires a project name}"
  local drain_file
  drain_file="$(_sgt_drain_project_file "$project")"
  _sgt_drain_run_locked rm -f "$drain_file"
}
