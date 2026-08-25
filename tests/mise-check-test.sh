#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

check_script="$test_root/check.sh"
awk '
  /^\[tasks\.check\]$/ { in_task=1; next }
  in_task && /^run = """$/ { in_run=1; next }
  in_run && /^"""$/ { exit }
  in_run { print }
' "$repo_root/mise.toml" > "$check_script"
chmod +x "$check_script"

make_stub() {
  local name="$1"
  local body="$2"
  printf '%s\n' "$body" > "$stubs/$name"
  chmod +x "$stubs/$name"
}

write_required_stubs() {
  for cmd in git gh openspec; do
    make_stub "$cmd" "#!/usr/bin/env bash
printf '%s version 1.0\\n' \"$cmd\""
  done
}

run_check() {
  local agent_mode="$1"
  stubs="$test_root/${agent_mode}/bin"
  mkdir -p "$stubs"
  write_required_stubs

  if [[ "$agent_mode" == "opencode" ]]; then
    make_stub opencode '#!/usr/bin/env bash
printf "%s\n" "OpenCode 1.0"'
  elif [[ "$agent_mode" == "claude" ]]; then
    make_stub claude '#!/usr/bin/env bash
printf "%s\n" "Claude Code 1.0"'
  fi

  PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    MISE_PROJECT_ROOT="$repo_root" \
    "$check_script"
}

set +e
missing_agent_output="$(run_check none 2>&1)"
missing_agent_status=$?
set -e
if [[ "$missing_agent_status" -eq 0 ]] || [[ "$missing_agent_output" != *"MISSING"* ]] || [[ "$missing_agent_output" != *"opencode oc claude goose codex pi"* ]]; then
  printf 'dependency check did not fail when no supported agent harness was present:\n%s\n' "$missing_agent_output" >&2
  exit 1
fi

supported_output="$(run_check opencode 2>&1)"
if [[ "$supported_output" != *"agent"* ]] || [[ "$supported_output" != *"ok   opencode"* ]] || [[ "$supported_output" != *"All v2 prerequisites present."* ]]; then
  printf 'dependency check did not pass with a supported agent harness:\n%s\n' "$supported_output" >&2
  exit 1
fi

alternate_agent_output="$(run_check claude 2>&1)"
if [[ "$alternate_agent_output" != *"ok   claude"* ]] || [[ "$alternate_agent_output" != *"All v2 prerequisites present."* ]]; then
  printf 'dependency check did not accept Claude:\n%s\n' "$alternate_agent_output" >&2
  exit 1
fi

# Test: missing a required non-agent tool (openspec) fails the check even when
# an agent harness is present.
no_openspec_stubs="$test_root/no-openspec/bin"
mkdir -p "$no_openspec_stubs"
for cmd in git gh; do
  printf '#!/usr/bin/env bash\nprintf "%%s version 1.0\\n" "%s"\n' "$cmd" > "$no_openspec_stubs/$cmd"
  chmod +x "$no_openspec_stubs/$cmd"
done
printf '#!/usr/bin/env bash\nprintf "OpenCode 1.0\n"\n' > "$no_openspec_stubs/opencode"
chmod +x "$no_openspec_stubs/opencode"

set +e
no_openspec_output="$(PATH="$no_openspec_stubs:/usr/bin:/bin:/usr/sbin:/sbin" MISE_PROJECT_ROOT="$repo_root" "$check_script" 2>&1)"
no_openspec_status=$?
set -e
if [[ "$no_openspec_status" -eq 0 ]] || [[ "$no_openspec_output" != *"openspec"*"MISSING"* ]]; then
  printf 'dependency check did not fail when openspec was missing:\n%s\n' "$no_openspec_output" >&2
  exit 1
fi

printf 'mise check validates v2 engine prerequisites: ok\n'
