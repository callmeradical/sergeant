#!/usr/bin/env bash
# Tests for sgt-graphify: CLI, failure handling, symlink alias resolution (F2),
# and atomic publication guarantees.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
REAL_PYTHON="$(command -v python3 || command -v python)"
REAL_MV="$(command -v mv)"

home="$TEST_ROOT/home"
config="$TEST_ROOT/config"
dev_root="$TEST_ROOT/dev"
fake_bin="$TEST_ROOT/fake-bin"
fallback_path="$TEST_ROOT/fallback-path"
crossfs_path="$TEST_ROOT/crossfs-path"
output="$TEST_ROOT/project-graph-link"
real_output="$TEST_ROOT/project-graph"
repo_symlink_target="$TEST_ROOT/repo-symlink-target"
tmpdir="$TEST_ROOT/tmp"
mkdir -p "$home" "$config" "$dev_root/api/vendor" "$dev_root/app" "$fake_bin" "$fallback_path" \
  "$crossfs_path" "$real_output" "$repo_symlink_target" "$tmpdir"
ln -s "$real_output" "$output"
# Symlink fixtures for alias tests (F2: resolve symlink aliases before in-source output checks)
ln -s "$dev_root/api" "$dev_root/api-alias"
ln -s "$dev_root/api" "$dev_root/api-parent-alias"
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
cat > "$config/trailing-slash-output.yaml" <<EOF
name: trailing-slash-output
repos:
  - name: api
    path: api
graphify:
  output: $output/
EOF
cat > "$config/output-inside-source.yaml" <<EOF
name: output-inside-source
repos:
  - name: api
    path: api
graphify:
  output: $dev_root/api/graphify-out
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/output-inside-source-trailing-repo-path.yaml" <<EOF
name: output-inside-source-trailing-repo-path
repos:
  - name: api
    path: api/
graphify:
  output: $dev_root/api/graphify-out
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/repo-symlink-output.yaml" <<EOF
name: repo-symlink-output
repos:
  - name: api
    path: api
graphify:
  output: $dev_root/api/graphify-out/
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/symlink-repo-root.yaml" <<EOF
name: symlink-repo-root
repos:
  - name: api
    path: api-alias
graphify:
  output: $dev_root/api/graphify-out
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/symlink-output-parent.yaml" <<EOF
name: symlink-output-parent
repos:
  - name: api
    path: api
graphify:
  output: $dev_root/api-parent-alias/graphify-out
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/symlink-output-nonexistent.yaml" <<EOF
name: symlink-output-nonexistent
repos:
  - name: api
    path: api
graphify:
  output: $dev_root/api-parent-alias/new-graphify-out
  exclude_patterns:
    - "**/vendor/**"
    - "**/*.generated.*"
EOF
cat > "$config/invalid-name.yaml" <<EOF
name: invalid-name
repos:
  - name: "api server"
    path: api
graphify:
  output: $TEST_ROOT/invalid-name-graph
EOF
cat > "$config/fallback-runtime.yaml" <<EOF
name: fallback-runtime
repos:
  - name: api
    path: api
graphify:
  output: $TEST_ROOT/fallback-runtime-graph
EOF

cat > "$fake_bin/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'python3 %q\n' "\$*" >> "$TEST_ROOT/python.log"
exec "$REAL_PYTHON" "\$@"
EOF
chmod +x "$fake_bin/python3"

# Intercept the atomic symlink rename (mv -T) to simulate publication failure.
# The example project uses a symlink configured output, so the publication path
# does mv -T to atomically replace the symlink.
cat > "$crossfs_path/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-T" ]]; then
  printf 'intercepted\n' > "$TEST_ROOT/crossfs-intercepted"
  exit 1
fi
exec "$REAL_MV" "\$@"
EOF
chmod +x "$crossfs_path/mv"

for tool in bash cp dirname grep ln mkdir mktemp mv rm sed tar tr yq; do
  ln -s "$(command -v "$tool")" "$fallback_path/$tool"
done

cat > "$fallback_path/python" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'python %q\n' "\$*" >> "$TEST_ROOT/fallback-python.log"
exit 1
EOF
chmod +x "$fallback_path/python"

cat > "$fallback_path/graphify" <<EOF
#!$REAL_PYTHON
import json
import os
import sys
from pathlib import Path

with open("$TEST_ROOT/fallback-graphify.log", "a", encoding="utf-8") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\\n")

command = sys.argv[1]
args = sys.argv[2:]

if command == "extract":
    repo_path = args[0]
    repo_name = Path(repo_path).name
    out = ""
    idx = 1
    while idx < len(args):
        if args[idx] == "--out":
            out = args[idx + 1]
            idx += 2
        elif args[idx] == "--exclude" or args[idx].startswith("--exclude="):
            raise SystemExit(64)
        else:
            idx += 1
    out_dir = Path(out) / "graphify-out"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "graph.json").write_text(
        json.dumps(
            {
                "nodes": [
                    {
                        "id": f"{repo_name}-node",
                        "label": f"{repo_name} node",
                        "file_type": "code",
                        "source_file": "source.txt",
                    }
                ],
                "links": [],
            }
        )
        + "\\n",
        encoding="utf-8",
    )
    (out_dir / "manifest.json").write_text(
        json.dumps({"source.txt": {"mtime": 1, "ast_hash": repo_name, "semantic_hash": repo_name}}) + "\\n",
        encoding="utf-8",
    )
elif command == "merge-graphs":
    out = ""
    inputs = []
    idx = 0
    while idx < len(args):
        if args[idx] == "--out":
            out = args[idx + 1]
            idx += 2
        else:
            inputs.append(args[idx])
            idx += 1
    merged = {"nodes": [], "links": []}
    for raw in inputs:
        data = json.loads(Path(raw).read_text(encoding="utf-8"))
        merged["nodes"].extend(data.get("nodes", []))
        merged["links"].extend(data.get("links", []))
    Path(out).write_text(json.dumps(merged) + "\\n", encoding="utf-8")
elif command == "cluster-only":
    project_root = Path(args[0])
    out_dir = project_root / "graphify-out"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "GRAPH_REPORT.md").write_text("fallback report\\n", encoding="utf-8")
else:
    raise SystemExit(64)
EOF
chmod +x "$fallback_path/graphify"

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
    if [[ "$repo_path" == */sources/* && -e "$repo_path/graphify-out/stale.txt" ]]; then
      printf 'configured output reached graphify extraction\n' >&2
      exit 66
    fi
    mkdir -p "$out/graphify-out"
    cat > "$out/graphify-out/graph.json" <<JSON
{"nodes":[{"id":"${repo_name}-node","label":"${repo_name} node","file_type":"code","source_file":"source.txt","source_files":["source.txt"]}],"links":[{"source":"${repo_name}-node","target":"${repo_name}-node","relation":"references","confidence":"EXTRACTED","source_file":"source.txt"}],"hyperedges":[{"id":"${repo_name}-hyperedge","label":"${repo_name} group","nodes":["${repo_name}-node"],"relation":"participate_in","confidence":"EXTRACTED","source_file":"source.txt","source_files":["source.txt"]}]}
JSON
    printf '{"source.txt": {"mtime": 1, "ast_hash": "%s", "semantic_hash": "%s"}}\n' \
      "$repo_name" "$repo_name" > "$out/graphify-out/manifest.json"
    ;;
  merge-graphs)
    inputs=()
    out=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--out" ]]; then
        out="$2"
        shift 2
      else
        inputs+=("$1")
        shift
      fi
    done
    mkdir -p "$(dirname "$out")"
    MERGE_OUT="$out" python3 - "${inputs[@]}" <<'PY'
import json
import os
import sys
from pathlib import Path

merged = {"nodes": [], "links": [], "hyperedges": []}
for raw in sys.argv[1:]:
    data = json.loads(Path(raw).read_text(encoding="utf-8"))
    for key in ("nodes", "links", "hyperedges"):
        merged[key].extend(data.get(key, []))

Path(os.environ["MERGE_OUT"]).write_text(json.dumps(merged) + "\n", encoding="utf-8")
PY
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

run_graphify_with_path() {
  local path_override="$1"
  local fail_repos="${2:-}"
  local project="${3:-example}"
  HOME="$home" PATH="$path_override" SERGEANT_CONFIG="$config" GRAPHIFY_LOG="$TEST_ROOT/graphify.log" \
    GRAPHIFY_FAIL_REPOS="$fail_repos" "$ROOT_DIR/bin/sgt-graphify" "$project"
}

mkdir -p "$output/wiki" "$output/memory"
printf 'wiki\n' > "$output/wiki/index.md"
printf 'memory\n' > "$output/memory/query.md"
success_output="$(run_graphify)"
grep -Fq 'python3 -' "$TEST_ROOT/python.log"
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
[[ -f "$output/.graphify_root" ]]
[[ -L "$output" ]]
grep -Fq 'api/source.txt' "$output/manifest.json"
grep -Fq 'app/source.txt' "$output/manifest.json"
grep -Fq '"source_file": "api/source.txt"' "$output/graph.json"
grep -Fq '"source_file": "app/source.txt"' "$output/graph.json"
grep -Fq '"source_files": [' "$output/graph.json"
grep -Fq '"api/source.txt"' "$output/graph.json"
grep -Fq '"app/source.txt"' "$output/graph.json"
# After atomic symlink swap, .graphify_root contains the configured (symlink) path.
grep -Fxq "$output/.graphify_sources" "$output/.graphify_root"
[[ -L "$output/.graphify_sources/api" ]]
[[ -L "$output/.graphify_sources/app" ]]
grep -Fq 'api' "$output/.graphify_sources/api/source.txt"
grep -Fq 'app' "$output/.graphify_sources/app/source.txt"
grep -Fq 'wiki' "$output/wiki/index.md"
grep -Fq 'memory' "$output/memory/query.md"
[[ ! -e "$dev_root/api/graphify-out" ]]
[[ ! -e "$dev_root/app/graphify-out" ]]
grep -Fq "Graph report available at: $output/GRAPH_REPORT.md" <<< "$success_output"

: > "$TEST_ROOT/graphify.log"
run_graphify "" no-excludes >/dev/null
[[ -f "$TEST_ROOT/no-excludes-graph/graph.json" ]]
[[ -f "$TEST_ROOT/no-excludes-graph/.graphify_root" ]]
grep -Fq '"source_file": "api/source.txt"' "$TEST_ROOT/no-excludes-graph/graph.json"
grep -Fxq "$TEST_ROOT/no-excludes-graph/.graphify_sources" "$TEST_ROOT/no-excludes-graph/.graphify_root"
if grep -Fq -- '--exclude' "$TEST_ROOT/graphify.log"; then
  printf 'sgt-graphify added an exclusion to an empty configuration\n' >&2
  exit 1
fi

: > "$TEST_ROOT/graphify.log"
run_graphify "" trailing-slash-output >/dev/null
[[ -L "$output" ]]
[[ -f "$output/graph.json" ]]

: > "$TEST_ROOT/graphify.log"
rm -f "$TEST_ROOT/crossfs-intercepted"
printf 'preexisting graph\n' > "$output/graph.json"
printf 'preexisting manifest\n' > "$output/manifest.json"
printf 'preexisting report\n' > "$output/GRAPH_REPORT.md"
set +e
crossfs_output="$(TMPDIR="$tmpdir" run_graphify_with_path "$crossfs_path:$fake_bin:$PATH" "" example 2>&1)"
crossfs_status=$?
set -e
[[ $crossfs_status -ne 0 ]]
[[ -f "$TEST_ROOT/crossfs-intercepted" ]]
grep -Fq 'Could not publish project graph' <<< "$crossfs_output"
# Configured output must still be accessible and retain preexisting content.
[[ -d "$output" ]]
grep -Fq 'preexisting graph' "$output/graph.json"
grep -Fq 'preexisting manifest' "$output/manifest.json"
grep -Fq 'preexisting report' "$output/GRAPH_REPORT.md"

mkdir -p "$dev_root/api/graphify-out"
printf 'stale\n' > "$dev_root/api/graphify-out/stale.txt"
: > "$TEST_ROOT/graphify.log"
run_graphify "" output-inside-source >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -f "$dev_root/api/graphify-out/graph.json" ]]
[[ ! -e "$dev_root/api/graphify-out/stale.txt" ]]

rm -rf "$dev_root/api/graphify-out"
mkdir -p "$dev_root/api/graphify-out"
printf 'stale\n' > "$dev_root/api/graphify-out/stale.txt"
: > "$TEST_ROOT/graphify.log"
run_graphify "" output-inside-source-trailing-repo-path >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -f "$dev_root/api/graphify-out/graph.json" ]]
[[ ! -e "$dev_root/api/graphify-out/stale.txt" ]]

rm -rf "$dev_root/api/graphify-out"
ln -s "$repo_symlink_target" "$dev_root/api/graphify-out"
printf 'stale\n' > "$repo_symlink_target/stale.txt"
: > "$TEST_ROOT/graphify.log"
run_graphify "" repo-symlink-output >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -L "$dev_root/api/graphify-out" ]]
[[ -f "$repo_symlink_target/graph.json" ]]
[[ ! -e "$repo_symlink_target/stale.txt" ]]

: > "$TEST_ROOT/graphify.log"
: > "$TEST_ROOT/fallback-python.log"
: > "$TEST_ROOT/fallback-graphify.log"
fallback_output="$(run_graphify_with_path "$fallback_path" "" fallback-runtime)"
[[ -f "$TEST_ROOT/fallback-runtime-graph/graph.json" ]]
grep -Fq 'extract' "$TEST_ROOT/fallback-graphify.log"
if [[ -s "$TEST_ROOT/fallback-python.log" ]]; then
  printf 'sgt-graphify preferred bare python over Graphify runtime\n' >&2
  exit 1
fi
grep -Fq 'Graph report available at: ' <<< "$fallback_output"

: > "$TEST_ROOT/graphify.log"
set +e
invalid_output="$(run_graphify "" invalid-name 2>&1)"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -Fq 'repos[].name "api server" must match [A-Za-z0-9._-]+' <<< "$invalid_output"
grep -Fq "rename it in $config/invalid-name.yaml" <<< "$invalid_output"
if grep -Fq 'extract ' "$TEST_ROOT/graphify.log"; then
  printf 'sgt-graphify attempted extraction for an invalid repo name\n' >&2
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

# F2: aliased repo root — repo path is a symlink; output is inside the real path.
# Without canonicalization the containment check is lexical and misses the alias,
# so the output would not be excluded from the scan.
rm -rf "$dev_root/api/graphify-out"
mkdir -p "$dev_root/api/graphify-out"
printf 'stale\n' > "$dev_root/api/graphify-out/stale.txt"
: > "$TEST_ROOT/graphify.log"
run_graphify "" symlink-repo-root >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -f "$dev_root/api/graphify-out/graph.json" ]]
[[ ! -e "$dev_root/api/graphify-out/stale.txt" ]]

# F2: aliased output parent — output path has a symlinked parent component.
# Without canonicalization graphify_output keeps the alias form, so the
# containment check against the real repo path misses it.
rm -rf "$dev_root/api/graphify-out"
mkdir -p "$dev_root/api/graphify-out"
printf 'stale\n' > "$dev_root/api/graphify-out/stale.txt"
: > "$TEST_ROOT/graphify.log"
run_graphify "" symlink-output-parent >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -f "$dev_root/api/graphify-out/graph.json" ]]
[[ ! -e "$dev_root/api/graphify-out/stale.txt" ]]

# F2: non-existent publication target — output path under a symlinked parent
# does not exist yet.  _canonicalize_path must resolve the parent through the
# symlink and _publish_parent_for_output must walk outside the repo before
# calling mktemp -d, even when the leaf directory hasn't been created yet.
rm -rf "$dev_root/api/new-graphify-out"
: > "$TEST_ROOT/graphify.log"
run_graphify "" symlink-output-nonexistent >/dev/null
grep -Eq 'extract .*/sources/api --out' "$TEST_ROOT/graphify.log"
[[ -f "$dev_root/api/new-graphify-out/graph.json" ]]
rm -rf "$dev_root/api/new-graphify-out"

printf 'sgt-graphify current CLI and failure handling: ok\n'

# ── Atomic publication: symlink failure leaves no dangling symlink ────────────
# When mv -T fails during the symlink atomic swap, the old symlink must remain
# valid — the old backing directory must not be removed.
#
# We simulate mv -T failure via a dedicated fake mv that exits 1 for -T.

at_bin="$TEST_ROOT/atomic-test-bin"
at_config="$TEST_ROOT/atomic-test-config"
at_repo="$TEST_ROOT/atomic-test-repo"
# Use a dedicated subdirectory for the atomic-test output so the leftover
# check does not see the .sgt-graphify-live.* backing dir from the
# project-graph-link symlink (which also lives in $TEST_ROOT).
at_pub_dir="$TEST_ROOT/atomic-test-pub"
at_live="$at_pub_dir/atomic-test-live"
at_output="$at_pub_dir/atomic-test-link"
mkdir -p "$at_bin" "$at_config" "$at_repo" "$at_pub_dir" "$at_live"
printf 'content\n' > "$at_live/old.txt"
ln -sfn "$at_live" "$at_output"

cat > "$at_config/atproject.yaml" <<EOF
name: atproject
repos:
  - name: repo1
    path: $at_repo
graphify:
  output: $at_output
EOF

# A fake graphify that supports extract/merge-graphs/cluster-only (minimal).
cat > "$at_bin/graphify" <<'ATEOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
shift
case "$command" in
  extract)
    out=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--out" ]] && { out="$2"; shift 2; continue; }
      shift
    done
    mkdir -p "$out/graphify-out"
    printf '{"nodes":[],"links":[]}\n' > "$out/graphify-out/graph.json"
    printf '{"f":{"mtime":1}}\n' > "$out/graphify-out/manifest.json"
    ;;
  merge-graphs)
    out=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--out" ]] && { out="$2"; shift 2; continue; }
      shift
    done
    mkdir -p "$(dirname "$out")"
    printf '{"nodes":[],"links":[]}\n' > "$out"
    ;;
  cluster-only)
    project_root="$1"
    mkdir -p "$project_root/graphify-out"
    printf '# report\n' > "$project_root/graphify-out/GRAPH_REPORT.md"
    ;;
esac
ATEOF
chmod +x "$at_bin/graphify"

# Fake mv that fails on -T (atomic symlink rename step).
REAL_MV_PATH="$(command -v mv)"
cat > "$at_bin/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "-T" ]]; then exit 1; fi
exec "$REAL_MV_PATH" "\$@"
EOF
chmod +x "$at_bin/mv"

# Also need python3 for the graph-source-prefix step.
ln -s "$(command -v python3)" "$at_bin/python3"

set +e
SERGEANT_CONFIG="$at_config" PATH="$at_bin:$PATH" \
  "$ROOT_DIR/bin/sgt-graphify" atproject >/dev/null 2>&1
at_status=$?
set -e

# Configured symlink must not be dangling after the failed publication.
[[ -L "$at_output" ]] || {
  printf 'FAIL: symlink_failure_no_dangling: configured path is no longer a symlink\n' >&2
  exit 1
}
[[ -d "$at_output" ]] || {
  printf 'FAIL: symlink_failure_no_dangling: configured symlink is dangling after failed publication\n' >&2
  exit 1
}
[[ -f "$at_output/old.txt" ]] || {
  printf 'FAIL: symlink_failure_no_dangling: old backing dir content is gone after failed publication\n' >&2
  exit 1
}
# No leftover temp dirs should remain in the output parent (the dedicated
# at_pub_dir, which is separate from $TEST_ROOT so the project-graph-link
# backing dir in $TEST_ROOT does not produce a false positive).
leftover=0
for d in "$at_pub_dir"/.sgt-graphify-live.* "$at_pub_dir"/.sgt-graphify-nextsym.*; do
  [[ -e "$d" ]] && leftover=$((leftover + 1))
done
[[ "$leftover" -eq 0 ]] || {
  printf 'FAIL: symlink_failure_no_dangling: leftover temp files after failed publication\n' >&2
  exit 1
}

printf 'symlink_failure_no_dangling_symlink: ok\n'

# ── Slice: --code-only fallback when no LLM API key is set (issue #86) ─────────
# When no supported LLM API key env var is set, sgt-graphify must pass --code-only
# to graphify extract so the code graph is still built even when doc/paper files
# are present. Without --code-only graphify aborts the entire run.

# Run sgt-graphify in a subshell so we can unset all LLM key env vars cleanly.
graphify_log_no_key="$TEST_ROOT/graphify-no-key.log"
no_key_status=0
(
  unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY
  unset KIMI_API_KEY DEEPSEEK_API_KEY OPENROUTER_API_KEY
  HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
    GRAPHIFY_LOG="$graphify_log_no_key" \
    "$ROOT_DIR/bin/sgt-graphify" example >/dev/null 2>&1
) || no_key_status=$?

[[ "$no_key_status" -eq 0 ]] || {
  printf 'FAIL no_llm_key_code_only: sgt-graphify should exit 0 even with no LLM key, got %d\n' \
    "$no_key_status" >&2; exit 1
}
grep -qF -- '--code-only' "$graphify_log_no_key" || {
  printf 'FAIL no_llm_key_code_only: --code-only must be passed to graphify extract when no API key is set\n' >&2
  printf 'actual extract call: %s\n' "$(grep 'extract' "$graphify_log_no_key" | head -1)" >&2
  exit 1
}
printf 'no_llm_key_code_only_fallback: ok\n'

# With an API key set, --code-only must NOT be added (full semantic extraction intended).
graphify_log_with_key="$TEST_ROOT/graphify-with-key.log"
(
  export ANTHROPIC_API_KEY="sk-ant-test-key-placeholder"
  HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
    GRAPHIFY_LOG="$graphify_log_with_key" \
    "$ROOT_DIR/bin/sgt-graphify" example >/dev/null 2>&1
)
! grep -qF -- '--code-only' "$graphify_log_with_key" || {
  printf 'FAIL no_llm_key_code_only: --code-only must NOT be passed when an API key is available\n' >&2; exit 1
}
printf 'llm_key_present_no_code_only_flag: ok\n'
