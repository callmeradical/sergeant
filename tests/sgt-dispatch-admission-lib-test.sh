#!/usr/bin/env bash
# Tests for the dispatch admission-control library helpers added for
# openspec/changes/dispatch-admission-control: _sgt_live_worker_census,
# _sgt_system_pressure, _sgt_effective_worker_budget.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass=0
fail=0
_pass() { printf '  ok: %s\n' "$*"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }

_lib() {
  bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/bin/_sgt-lib.sh" "$@"
}

# ── _sgt_live_worker_census ───────────────────────────────────────────────────

fleet="$TEST_ROOT/fleet"
mkdir -p "$fleet/task-a/app" "$fleet/task-b/svc"

# A live, verified pane counts.
sleep 100 & live_pid=$!
disown "$live_pid" 2>/dev/null || true
printf 'in_progress\n' > "$fleet/task-a/app/status"
printf '%%77\n' > "$fleet/task-a/app/pane"

# Fake tmux so pane identity resolves deterministically for %77 as live.
fake_bin="$TEST_ROOT/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  # -t %77 -> live; -t %88 -> dead/gone
  for a in "$@"; do
    if [[ "$a" == "%77" ]]; then
      printf '0|%%77|4242|123456|fixture-worker-command\n'
      exit 0
    fi
  done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"

# Write the recorded pane_identity to match what tmux will report live.
printf '0|%%77|4242|123456|fixture-worker-command\n' > "$fleet/task-a/app/pane_identity"
chmod 600 "$fleet/task-a/app/pane_identity"

# task-b/svc: status says in_progress but pane is stale/dead (tmux can't find it).
printf 'in_progress\n' > "$fleet/task-b/svc/status"
printf '%%88\n' > "$fleet/task-b/svc/pane"
printf '0|%%88|9999|000000|fixture-worker-command\n' > "$fleet/task-b/svc/pane_identity"
chmod 600 "$fleet/task-b/svc/pane_identity"

census="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet" _lib _sgt_live_worker_census)"
if [[ "$census" == "1" ]]; then
  _pass "_sgt_live_worker_census: counts only the verified-live pane, not the stale record"
else
  _fail "_sgt_live_worker_census: expected 1, got '$census'"
fi

kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# A second coordinator's fleet directory is the SAME $FLEET_DIR: two
# independently-dispatched tasks both verified live both count toward one total.
fleet2="$TEST_ROOT/fleet2"
mkdir -p "$fleet2/coord-a/repo1" "$fleet2/coord-b/repo2"
for n in 1 2; do
  printf 'in_progress\n' > "$fleet2/coord-a/repo1/status"
  printf '%%1\n' > "$fleet2/coord-a/repo1/pane"
  printf '0|%%1|100|10|cmd\n' > "$fleet2/coord-a/repo1/pane_identity"
  chmod 600 "$fleet2/coord-a/repo1/pane_identity"
  printf 'in_progress\n' > "$fleet2/coord-b/repo2/status"
  printf '%%2\n' > "$fleet2/coord-b/repo2/pane"
  printf '0|%%2|200|20|cmd\n' > "$fleet2/coord-b/repo2/pane_identity"
  chmod 600 "$fleet2/coord-b/repo2/pane_identity"
done
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "display-message" ]]; then
  for a in "$@"; do
    case "$a" in
      %1) printf '0|%%1|100|10|cmd\n'; exit 0 ;;
      %2) printf '0|%%2|200|20|cmd\n'; exit 0 ;;
    esac
  done
  exit 1
fi
exit 1
EOF
chmod +x "$fake_bin/tmux"
census2="$(PATH="$fake_bin:$PATH" SERGEANT_FLEET="$fleet2" _lib _sgt_live_worker_census)"
if [[ "$census2" == "2" ]]; then
  _pass "_sgt_live_worker_census: two independent coordinators' live workers both count toward one machine-wide total"
else
  _fail "_sgt_live_worker_census: expected 2 across two coordinator task dirs, got '$census2'"
fi

# ── _sgt_system_pressure ──────────────────────────────────────────────────────

darwin_bin="$TEST_ROOT/darwin-bin"
mkdir -p "$darwin_bin"
cat > "$darwin_bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
chmod +x "$darwin_bin/uname"
cat > "$darwin_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n vm.loadavg" ]]; then
  printf '{ 1.50 2.00 2.50 }\n'
elif [[ "$*" == "-n hw.ncpu" ]]; then
  printf '4\n'
fi
EOF
chmod +x "$darwin_bin/sysctl"
cat > "$darwin_bin/vm_stat" <<'EOF'
#!/usr/bin/env bash
cat <<'STAT'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                              100000.
Pages active:                            100000.
Pages inactive:                          100000.
Pages wired down:                        100000.
STAT
EOF
chmod +x "$darwin_bin/vm_stat"

read -r p_load p_mem p_cpus < <(PATH="$darwin_bin:$PATH" _lib _sgt_system_pressure)
if [[ "$p_load" == "1.50" && "$p_cpus" == "4" ]]; then
  _pass "_sgt_system_pressure (Darwin): reads load average and CPU count from sysctl"
else
  _fail "_sgt_system_pressure (Darwin): got load='$p_load' mem='$p_mem' cpus='$p_cpus'"
fi
if [[ "$p_mem" == "0.25" ]]; then
  _pass "_sgt_system_pressure (Darwin): computes free/total memory ratio from vm_stat"
else
  _fail "_sgt_system_pressure (Darwin): expected mem_ratio 0.25, got '$p_mem'"
fi

# ── _sgt_effective_worker_budget ──────────────────────────────────────────────

# Idle machine: nominal budget is cpus*2, unaffected by low load/ample memory.
idle_bin="$TEST_ROOT/idle-bin"
mkdir -p "$idle_bin"
cp "$darwin_bin/uname" "$idle_bin/uname"
cat > "$idle_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n vm.loadavg" ]]; then
  printf '{ 0.10 0.10 0.10 }\n'
elif [[ "$*" == "-n hw.ncpu" ]]; then
  printf '4\n'
fi
EOF
chmod +x "$idle_bin/sysctl"
cat > "$idle_bin/vm_stat" <<'EOF'
#!/usr/bin/env bash
cat <<'STAT'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                              300000.
Pages active:                            50000.
Pages inactive:                          50000.
Pages wired down:                        50000.
STAT
EOF
chmod +x "$idle_bin/vm_stat"
idle_budget="$(PATH="$idle_bin:$PATH" _lib _sgt_effective_worker_budget)"
if [[ "$idle_budget" == "8" ]]; then
  _pass "_sgt_effective_worker_budget: idle machine gets the full cpus*2 nominal ceiling"
else
  _fail "_sgt_effective_worker_budget: expected 8 on an idle 4-cpu machine, got '$idle_budget'"
fi

# Busy machine: same CPU count, much higher load -> lower effective budget.
busy_bin="$TEST_ROOT/busy-bin"
mkdir -p "$busy_bin"
cp "$darwin_bin/uname" "$busy_bin/uname"
cat > "$busy_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n vm.loadavg" ]]; then
  printf '{ 16.00 16.00 16.00 }\n'
elif [[ "$*" == "-n hw.ncpu" ]]; then
  printf '4\n'
fi
EOF
chmod +x "$busy_bin/sysctl"
cp "$idle_bin/vm_stat" "$busy_bin/vm_stat"
busy_budget="$(PATH="$busy_bin:$PATH" _lib _sgt_effective_worker_budget)"
if [[ "$busy_budget" -lt "$idle_budget" ]]; then
  _pass "_sgt_effective_worker_budget: busier machine at the same nominal ceiling admits fewer workers ($busy_budget < $idle_budget)"
else
  _fail "_sgt_effective_worker_budget: expected busy budget < idle budget, got busy=$busy_budget idle=$idle_budget"
fi

# Low memory also reduces the budget.
lowmem_bin="$TEST_ROOT/lowmem-bin"
mkdir -p "$lowmem_bin"
cp "$idle_bin/uname" "$lowmem_bin/uname"
cp "$idle_bin/sysctl" "$lowmem_bin/sysctl"
cat > "$lowmem_bin/vm_stat" <<'EOF'
#!/usr/bin/env bash
cat <<'STAT'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                              5000.
Pages active:                            300000.
Pages inactive:                          300000.
Pages wired down:                        300000.
STAT
EOF
chmod +x "$lowmem_bin/vm_stat"
lowmem_budget="$(PATH="$lowmem_bin:$PATH" _lib _sgt_effective_worker_budget)"
if [[ "$lowmem_budget" -lt "$idle_budget" ]]; then
  _pass "_sgt_effective_worker_budget: low available memory reduces the budget below nominal"
else
  _fail "_sgt_effective_worker_budget: expected low-memory budget < idle budget, got $lowmem_budget vs $idle_budget"
fi

# SERGEANT_DISPATCH_MAX_WORKERS overrides the CPU-derived nominal ceiling outright.
override_budget="$(PATH="$idle_bin:$PATH" SERGEANT_DISPATCH_MAX_WORKERS=2 \
  _lib _sgt_effective_worker_budget)"
if [[ "$override_budget" == "2" ]]; then
  _pass "_sgt_effective_worker_budget: SERGEANT_DISPATCH_MAX_WORKERS overrides the nominal ceiling"
else
  _fail "_sgt_effective_worker_budget: expected override 2, got '$override_budget'"
fi

# Budget never drops below 1.
extreme_bin="$TEST_ROOT/extreme-bin"
mkdir -p "$extreme_bin"
cp "$idle_bin/uname" "$extreme_bin/uname"
cat > "$extreme_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n vm.loadavg" ]]; then
  printf '{ 999.00 999.00 999.00 }\n'
elif [[ "$*" == "-n hw.ncpu" ]]; then
  printf '1\n'
fi
EOF
chmod +x "$extreme_bin/sysctl"
cp "$lowmem_bin/vm_stat" "$extreme_bin/vm_stat"
extreme_budget="$(PATH="$extreme_bin:$PATH" _lib _sgt_effective_worker_budget)"
if [[ "$extreme_budget" == "1" ]]; then
  _pass "_sgt_effective_worker_budget: floors at 1 under extreme load+memory pressure"
else
  _fail "_sgt_effective_worker_budget: expected floor of 1, got '$extreme_budget'"
fi

printf '\nsgt-dispatch-admission-lib: %d passed' "$pass"
if [[ "$fail" -gt 0 ]]; then
  printf ', %d FAILED\n' "$fail" >&2
  exit 1
fi
printf '\n'
