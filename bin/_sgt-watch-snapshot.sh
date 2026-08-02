#!/usr/bin/env bash
# Read-only positive-witness snapshot support for sgt-watch.

_sgt_snapshot_valid_id() {
  local value="$1" id_re
  id_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
  [[ "$value" =~ $id_re ]]
}

_sgt_snapshot_read_line() {
  local path="$1" limit="$2" size size_after value="" extra="" extra_status=0
  local LC_ALL=C
  [[ -e "$path" || -L "$path" ]] || return 1
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 2
  size="$(stat -c %s "$path" 2>/dev/null || stat -f %z "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 && "$size" -le $((limit + 1)) ]] || return 2
  tr -d '\000' < "$path" | cmp -s - "$path" || return 2
  exec 7< "$path" || return 2
  IFS= read -r -n "$((limit + 1))" value <&7 || true
  IFS= read -r -n 1 extra <&7 || extra_status=$?
  exec 7<&-
  size_after="$(stat -c %s "$path" 2>/dev/null || stat -f %z "$path" 2>/dev/null || true)"
  [[ "$size_after" == "$size" && -n "$value" && ${#value} -le limit && \
     "$extra_status" -ne 0 && -z "$extra" ]] || return 2
  tr -d '\000' < "$path" | cmp -s - "$path" || return 2
  printf '%s\n' "$value"
}

_sgt_snapshot_read_owned_line() {
  local path="$1" limit="$2" value secure after
  value="$(_sgt_snapshot_read_line "$path" "$limit" 2>/dev/null)" || return 1
  secure="$(_sgt_read_owned_file "$path" 2>/dev/null || true)"
  [[ -n "$secure" && "$secure" == "$value" ]] || return 1
  after="$(_sgt_snapshot_read_line "$path" "$limit" 2>/dev/null)" || return 1
  [[ "$after" == "$value" ]] || return 1
  printf '%s\n' "$value"
}

_sgt_snapshot_parse_decimal() {
  local value="$1"
  SGT_SNAPSHOT_DECIMAL=""
  [[ "$value" =~ ^[0-9]+$ && ${#value} -le 10 ]] || return 1
  SGT_SNAPSHOT_DECIMAL=$((10#$value))
}

_sgt_snapshot_identity_is_worker() {
  local identity="$1" pane="$2" expected_command="$3"
  local dead remainder pane_id pane_pid created command
  SGT_SNAPSHOT_PANE_CREATED=""
  [[ "$identity" == *"|"* ]] || return 1
  dead="${identity%%|*}"
  remainder="${identity#*|}"
  [[ "$remainder" == *"|"* ]] || return 1
  pane_id="${remainder%%|*}"
  remainder="${remainder#*|}"
  [[ "$remainder" == *"|"* ]] || return 1
  pane_pid="${remainder%%|*}"
  remainder="${remainder#*|}"
  [[ "$remainder" == *"|"* ]] || return 1
  created="${remainder%%|*}"
  command="${remainder#*|}"
  [[ "$dead" == "0" && "$pane_id" == "$pane" && \
     "$pane_pid" =~ ^[1-9][0-9]*$ && "$created" =~ ^[1-9][0-9]*$ && \
     "$command" == "$expected_command" ]] || return 1
  _sgt_snapshot_parse_decimal "$created" || return 1
  SGT_SNAPSHOT_PANE_CREATED="$SGT_SNAPSHOT_DECIMAL"
}

_sgt_snapshot_recent_progress() {
  local repo_dir="$1" pane="$2" pane_created="$3"
  local progress="" progress_after="" activity="" activity_after=""
  local timestamp activity_timestamp read_status activity_status=0
  local last_event=0 have_event=false

  if progress="$(_sgt_snapshot_read_line "$repo_dir/progress_ts" 32 2>/dev/null)"; then
    _sgt_snapshot_parse_decimal "$progress" || return 1
    timestamp="$SGT_SNAPSHOT_DECIMAL"
    (( timestamp > pane_created && timestamp <= SGT_SNAPSHOT_NOW )) || return 1
    last_event="$timestamp"
    have_event=true
  else
    read_status=$?
    [[ "$read_status" -eq 1 ]] || return 1
  fi

  activity="$(tmux display-message -p -t "$pane" '#{pane_activity}' 2>/dev/null)" || \
    activity_status=$?
  if (( activity_status == 0 )) && _sgt_snapshot_parse_decimal "$activity"; then
    timestamp="$SGT_SNAPSHOT_DECIMAL"
    (( timestamp <= SGT_SNAPSHOT_NOW )) || return 1
    if (( timestamp > 0 )); then
      (( timestamp > pane_created )) || return 1
      activity_timestamp="$timestamp"
      (( timestamp > last_event )) && last_event="$timestamp"
      have_event=true
      activity_after="$(tmux display-message -p -t "$pane" '#{pane_activity}' 2>/dev/null || true)"
      _sgt_snapshot_parse_decimal "$activity_after" || return 1
      timestamp="$SGT_SNAPSHOT_DECIMAL"
      (( timestamp >= activity_timestamp && timestamp <= SGT_SNAPSHOT_NOW )) || return 1
      (( timestamp > last_event )) && last_event="$timestamp"
    fi
  fi

  if [[ -n "$progress" ]]; then
    progress_after="$(_sgt_snapshot_read_line "$repo_dir/progress_ts" 32 2>/dev/null || true)"
    [[ "$progress_after" == "$progress" ]] || return 1
  elif [[ -e "$repo_dir/progress_ts" || -L "$repo_dir/progress_ts" ]]; then
    return 1
  fi

  $have_event || return 1
  (( SGT_SNAPSHOT_NOW - last_event < SGT_SNAPSHOT_STALL_GRACE ))
}

_sgt_snapshot_repo_is_active() {
  local repo_dir="$1" fleet_status fleet_after worktree worktree_after
  local wt_status="" wt_after="" wt_present=false effective_status
  local pane pane_after agent agent_after expected expected_after actual current actual_after
  local expected_command

  [[ -d "$repo_dir" && ! -L "$repo_dir" ]] || return 1
  fleet_status="$(_sgt_snapshot_read_line "$repo_dir/status" 256 2>/dev/null)" || return 1
  worktree="$(_sgt_snapshot_read_line "$repo_dir/worktree" 4096 2>/dev/null)" || return 1
  [[ "$worktree" == /* && -d "$worktree" && ! -L "$worktree" && \
     -r "$worktree" && -x "$worktree" ]] || return 1

  if [[ -e "$worktree/.sergeant-status" || -L "$worktree/.sergeant-status" ]]; then
    wt_status="$(_sgt_snapshot_read_line "$worktree/.sergeant-status" 256 2>/dev/null)" || return 1
    wt_present=true
    effective_status="$wt_status"
  else
    effective_status="$fleet_status"
  fi
  case "$effective_status" in in_progress|dispatched) ;; *) return 1 ;; esac

  pane="$(_sgt_snapshot_read_line "$repo_dir/pane" 64 2>/dev/null)" || return 1
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 1
  agent="$(_sgt_snapshot_read_line "$repo_dir/agent" 256 2>/dev/null)" || return 1
  expected_command="$(_sgt_worker_command \
    "$SCRIPT_DIR/sgt-interactive-worker" "$repo_dir" "$worktree" "$agent")"
  expected="$(_sgt_snapshot_read_owned_line "$repo_dir/pane_identity" 1024)" || return 1
  _sgt_snapshot_identity_is_worker "$expected" "$pane" "$expected_command" || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  actual="$(_sgt_pane_identity "$pane")" || return 1
  current="$(_sgt_pane_identity "$pane")" || return 1
  [[ "$actual" == "$expected" && "$current" == "$actual" ]] || return 1
  _sgt_snapshot_recent_progress "$repo_dir" "$pane" "$SGT_SNAPSHOT_PANE_CREATED" || return 1
  actual_after="$(_sgt_pane_identity "$pane")" || return 1
  [[ "$actual_after" == "$expected" ]] || return 1

  fleet_after="$(_sgt_snapshot_read_line "$repo_dir/status" 256 2>/dev/null)" || return 1
  worktree_after="$(_sgt_snapshot_read_line "$repo_dir/worktree" 4096 2>/dev/null)" || return 1
  pane_after="$(_sgt_snapshot_read_line "$repo_dir/pane" 64 2>/dev/null)" || return 1
  agent_after="$(_sgt_snapshot_read_line "$repo_dir/agent" 256 2>/dev/null)" || return 1
  expected_after="$(_sgt_snapshot_read_owned_line "$repo_dir/pane_identity" 1024)" || return 1
  [[ "$fleet_after" == "$fleet_status" && "$worktree_after" == "$worktree" && \
     "$pane_after" == "$pane" && "$agent_after" == "$agent" && \
     "$expected_after" == "$expected" ]] || return 1
  if $wt_present; then
    wt_after="$(_sgt_snapshot_read_line "$worktree/.sergeant-status" 256 2>/dev/null)" || return 1
    [[ "$wt_after" == "$wt_status" ]] || return 1
  elif [[ -e "$worktree/.sergeant-status" || -L "$worktree/.sergeant-status" ]]; then
    return 1
  fi
  [[ -d "$worktree" && ! -L "$worktree" && -r "$worktree" && -x "$worktree" ]]
}

_sgt_snapshot_json_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

_sgt_snapshot_child_dirs() {
  command find "$1" ! -path "$1" -prune -type d -print0 2>/dev/null
}

_sgt_watch_snapshot() {
  local task_id="" repo_name="" observation observed_at now_raw grace_raw
  local task_dir repo_dir task_name candidate_repo busy=null scan_stop=false
  local task_candidates=0 repo_candidates=0 candidate_limit=64
  local basis=no_verified_active_witness
  shift

  if [[ $# -gt 0 && "${1:-}" != "--repo" ]]; then
    task_id="$1"
    _sgt_snapshot_valid_id "$task_id" || _die "Invalid snapshot task ID"
    shift
  fi
  if [[ "${1:-}" == "--repo" ]]; then
    [[ -n "$task_id" && $# -eq 2 ]] || \
      _die "Usage: sgt-watch --snapshot [<task-id> [--repo <repo>]]"
    repo_name="$2"
    _sgt_snapshot_valid_id "$repo_name" || _die "Invalid snapshot repo"
    shift 2
  fi
  [[ $# -eq 0 ]] || _die "Usage: sgt-watch --snapshot [<task-id> [--repo <repo>]]"

  observation="$(date -u '+%Y-%m-%dT%H:%M:%SZ|%s')"
  observed_at="${observation%%|*}"
  now_raw="${observation##*|}"
  _sgt_snapshot_parse_decimal "$now_raw" || _die "Could not establish snapshot observation time"
  SGT_SNAPSHOT_NOW="$SGT_SNAPSHOT_DECIMAL"
  grace_raw="${SERGEANT_STALL_GRACE_SECONDS:-300}"
  _sgt_snapshot_parse_decimal "$grace_raw" || \
    _die "SERGEANT_STALL_GRACE_SECONDS must be a non-negative integer"
  SGT_SNAPSHOT_STALL_GRACE="$SGT_SNAPSHOT_DECIMAL"

  if [[ -d "$FLEET_DIR" && ! -L "$FLEET_DIR" && -r "$FLEET_DIR" && -x "$FLEET_DIR" ]]; then
    if [[ -n "$task_id" ]]; then
      task_dir="$FLEET_DIR/$task_id"
      if [[ -d "$task_dir" && ! -L "$task_dir" ]]; then
        if [[ -n "$repo_name" ]]; then
          repo_dir="$task_dir/$repo_name"
          if [[ -d "$repo_dir" && ! -L "$repo_dir" ]] && \
             _sgt_snapshot_repo_is_active "$repo_dir"; then
            busy=true
            basis=verified_active_worker
          fi
        else
          while IFS= read -r -d '' repo_dir; do
            (( repo_candidates >= candidate_limit )) && break
            repo_candidates=$((repo_candidates + 1))
            candidate_repo="${repo_dir##*/}"
            _sgt_snapshot_valid_id "$candidate_repo" || continue
            if _sgt_snapshot_repo_is_active "$repo_dir"; then
              busy=true
              basis=verified_active_worker
              break
            fi
          done < <(_sgt_snapshot_child_dirs "$task_dir")
        fi
      fi
    else
      while IFS= read -r -d '' task_dir; do
        (( task_candidates >= candidate_limit )) && break
        task_candidates=$((task_candidates + 1))
        task_name="${task_dir##*/}"
        _sgt_snapshot_valid_id "$task_name" || continue
        while IFS= read -r -d '' repo_dir; do
          if (( repo_candidates >= candidate_limit )); then
            scan_stop=true
            break
          fi
          repo_candidates=$((repo_candidates + 1))
          candidate_repo="${repo_dir##*/}"
          _sgt_snapshot_valid_id "$candidate_repo" || continue
          if _sgt_snapshot_repo_is_active "$repo_dir"; then
            busy=true
            basis=verified_active_worker
            scan_stop=true
            break
          fi
        done < <(_sgt_snapshot_child_dirs "$task_dir")
        $scan_stop && break
      done < <(_sgt_snapshot_child_dirs "$FLEET_DIR")
    fi
  fi

  printf '{"schema":"sergeant.watch-status/v1","observed_at":%s,' \
    "$(_sgt_snapshot_json_quote "$observed_at")"
  if [[ -n "$task_id" ]]; then
    printf '"scope":{"kind":"task","task_id":%s,' "$(_sgt_snapshot_json_quote "$task_id")"
    if [[ -n "$repo_name" ]]; then
      printf '"repo":%s},' "$(_sgt_snapshot_json_quote "$repo_name")"
    else
      printf '"repo":null},'
    fi
  else
    printf '"scope":{"kind":"fleet","task_id":null,"repo":null},'
  fi
  printf '"busy":%s,"basis":%s}\n' "$busy" "$(_sgt_snapshot_json_quote "$basis")"
}
