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
  for cmd in git gh tmux yq lsof; do
    make_stub "$cmd" "#!/usr/bin/env bash
printf '%s version 1.0\\n' \"$cmd\""
  done
}

run_check() {
  local td_mode="$1"
  stubs="$test_root/$td_mode/bin"
  mkdir -p "$stubs"
  write_required_stubs

  if [[ "$td_mode" == "supported" ]]; then
    make_stub td '#!/usr/bin/env bash
case "$1" in
  --version)
    printf "%s\n" "td version v0.51.2"
    ;;
  create)
    if [[ "${2:-}" == "--help" ]]; then
      printf "%s\n" "Usage: td create TITLE --description TEXT --json --work-dir DIR"
    else
      exit 1
    fi
    ;;
  *)
    exit 1
    ;;
esac'
  elif [[ "$td_mode" == "unsupported" ]]; then
    make_stub td '#!/usr/bin/env bash
case "$1" in
  --version)
    printf "%s\n" "td version v0.51.2"
    ;;
  create)
    if [[ "${2:-}" == "--help" ]]; then
      printf "%s\n" "Usage: td create TITLE --description TEXT --json"
    else
      exit 1
    fi
    ;;
  *)
    exit 1
    ;;
esac'
  fi

  PATH="$stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    MISE_PROJECT_ROOT="$repo_root" \
    "$check_script"
}

set +e
missing_output="$(run_check missing 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 ]] || [[ "$missing_output" != *"td"* ]] || [[ "$missing_output" != *"MISSING"* ]]; then
  printf 'dependency check did not fail when td was missing:\n%s\n' "$missing_output" >&2
  exit 1
fi

set +e
unsupported_output="$(run_check unsupported 2>&1)"
unsupported_status=$?
set -e
if [[ "$unsupported_status" -eq 0 ]] || [[ "$unsupported_output" != *"Unsupported"* ]] || [[ "$unsupported_output" != *"Marcus td"* ]]; then
  printf 'dependency check did not reject unsupported td:\n%s\n' "$unsupported_output" >&2
  exit 1
fi

supported_output="$(run_check supported 2>&1)"
if [[ "$supported_output" != *"All required dependencies present."* ]]; then
  printf 'dependency check did not pass with supported td:\n%s\n' "$supported_output" >&2
  exit 1
fi

printf 'mise dependency check validates Marcus td support: ok\n'
