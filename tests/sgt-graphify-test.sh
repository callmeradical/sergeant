#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

home="$TEST_ROOT/home"
config="$TEST_ROOT/config"
dev_root="$TEST_ROOT/dev"
fake_bin="$TEST_ROOT/fake-bin"
output="$TEST_ROOT/project-graph-link"
real_output="$TEST_ROOT/project-graph"
mkdir -p "$home" "$config" "$dev_root/api/vendor" "$dev_root/app" "$fake_bin" "$real_output"
ln -s "$real_output" "$output"
printf 'api\n' > "$dev_root/api/source.txt"
printf 'ignored\n' > "$dev_root/api/vendor/ignored.py"
printf 'ignored\n' > "$dev_root/api/schema.generated.json"
printf 'app\n' > "$dev_root/app/source.txt"

cat > "$config/config.yaml" <<EOF
dev_root: $dev_root
EOF
cat > "$config/example.yaml" <<EOF
name: example
repos:
  - name: api
    path: api
  - name: app
    path: app
graphify:
  output: $output
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/no-excludes.yaml" <<EOF
name: no-excludes
repos:
  - name: api
    path: api
graphify:
  output: $TEST_ROOT/no-excludes-graph
EOF

cat > "$fake_bin/graphify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$GRAPHIFY_LOG"
printf '\n' >> "$GRAPHIFY_LOG"

command="$1"
shift
case "$command" in
  extract)
    repo_path="$1"
    repo_name="$(basename "$repo_path")"
    shift
    if [[ ",${GRAPHIFY_FAIL_REPOS:-}," == *",$repo_name,"* ]]; then
      printf 'extraction failed for %s\n' "$repo_name" >&2
      exit 7
    fi
    out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--out" ]]; then
        out="$2"
        shift 2
      elif [[ "$1" == "--exclude" || "$1" == --exclude=* ]]; then
        printf 'graphify 0.8.39 does not support --exclude\n' >&2
        exit 64
      else
        shift
      fi
    done
    if [[ "$repo_path" == */sources/* ]] && \
       [[ -e "$repo_path/vendor/ignored.py" || -e "$repo_path/schema.generated.json" ]]; then
      printf 'configured exclusions reached graphify extraction\n' >&2
      exit 65
    fi
    mkdir -p "$out/graphify-out"
    printf '{"nodes": [], "links": []}\n' > "$out/graphify-out/graph.json"
    printf '{"source.txt": {"mtime": 1, "ast_hash": "%s", "semantic_hash": "%s"}}\n' \
      "$repo_name" "$repo_name" > "$out/graphify-out/manifest.json"
    ;;
  merge-graphs)
    out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--out" ]]; then
        out="$2"
        shift 2
      else
        shift
      fi
    done
    mkdir -p "$(dirname "$out")"
    printf '{"nodes": [], "links": []}\n' > "$out"
    ;;
  cluster-only)
    project_root="$1"
    mkdir -p "$project_root/graphify-out"
    printf 'current report\n' > "$project_root/graphify-out/GRAPH_REPORT.md"
    ;;
  *)
    printf 'unexpected graphify command: %s\n' "$command" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fake_bin/graphify"

run_graphify() {
  HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" GRAPHIFY_LOG="$TEST_ROOT/graphify.log" \
    GRAPHIFY_FAIL_REPOS="${1:-}" "$ROOT_DIR/bin/sgt-graphify" "${2:-example}"
}

mkdir -p "$output/wiki" "$output/memory"
printf 'wiki\n' > "$output/wiki/index.md"
printf 'memory\n' > "$output/memory/query.md"
success_output="$(run_graphify)"
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
grep -Eq 'extract .*/sources/app --out' "$TEST_ROOT/graphify.log"
if grep -Fq -- '--exclude' "$TEST_ROOT/graphify.log"; then
  printf 'sgt-graphify passed exclusions unsupported by Graphify 0.8.39\n' >&2
  exit 1
fi
grep -Fq 'merge-graphs ' "$TEST_ROOT/graphify.log"
grep -Fq 'cluster-only ' "$TEST_ROOT/graphify.log"
if grep -Eq '(^| )update( |$)|--output' "$TEST_ROOT/graphify.log"; then
  printf 'sgt-graphify used obsolete CLI syntax\n' >&2
  exit 1
fi
[[ -f "$output/graph.json" ]]
[[ -f "$output/manifest.json" ]]
[[ -f "$output/GRAPH_REPORT.md" ]]
[[ -L "$output" ]]
grep -Fq 'api/source.txt' "$output/manifest.json"
grep -Fq 'app/source.txt' "$output/manifest.json"
grep -Fq 'wiki' "$output/wiki/index.md"
grep -Fq 'memory' "$output/memory/query.md"
[[ ! -e "$dev_root/api/graphify-out" ]]
[[ ! -e "$dev_root/app/graphify-out" ]]
grep -Fq "Graph report available at: $output/GRAPH_REPORT.md" <<< "$success_output"

: > "$TEST_ROOT/graphify.log"
run_graphify "" no-excludes >/dev/null
[[ -f "$TEST_ROOT/no-excludes-graph/graph.json" ]]
if grep -Fq -- '--exclude' "$TEST_ROOT/graphify.log"; then
  printf 'sgt-graphify added an exclusion to an empty configuration\n' >&2
  exit 1
fi

printf 'stale report\n' > "$output/GRAPH_REPORT.md"
: > "$TEST_ROOT/graphify.log"
set +e
partial_output="$(run_graphify app 2>&1)"
partial_status=$?
set -e
[[ $partial_status -ne 0 ]]
grep -Fq 'app' <<< "$partial_output"
if grep -Fq 'Graph report available at:' <<< "$partial_output"; then
  printf 'partial failure advertised a stale report\n' >&2
  exit 1
fi
grep -Fq 'stale report' "$output/GRAPH_REPORT.md"

: > "$TEST_ROOT/graphify.log"
set +e
total_output="$(run_graphify api,app 2>&1)"
total_status=$?
set -e
[[ $total_status -ne 0 ]]
grep -Fq 'api' <<< "$total_output"
grep -Fq 'app' <<< "$total_output"
if grep -Eq '=== done ===|Graph report available at:' <<< "$total_output"; then
  printf 'total failure reported success\n' >&2
  exit 1
fi
grep -Fq 'stale report' "$output/GRAPH_REPORT.md"

printf 'sgt-graphify current CLI and failure handling: ok\n'
