#!/usr/bin/env bash
# Regression test for GH #257: sgt-graphify records the Sergeant checkout's
# own HEAD as the graph's "built_at_commit"/"Built from commit" freshness
# marker, instead of the indexed source repository's real HEAD. This is
# graphify's own behavior (it calls _git_head() with no target directory,
# so it reports whatever the calling shell's cwd happened to be) --
# sgt-graphify is expected to correct it for the unambiguous single-repo
# case by overwriting both fields with the source repo's actual HEAD.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

home="$TEST_ROOT/home"
config="$TEST_ROOT/config"
dev_root="$TEST_ROOT/dev"
fake_bin="$TEST_ROOT/fake-bin"
output="$TEST_ROOT/project-graph"
mkdir -p "$home" "$config" "$dev_root/api" "$fake_bin"

# A real source repo with a real, known HEAD -- the value sgt-graphify must
# end up reporting, regardless of where graphify's own subprocess thought
# its cwd's HEAD was.
git -C "$dev_root/api" init -q
git -C "$dev_root/api" config user.email "test@example.com"
git -C "$dev_root/api" config user.name "Test"
printf 'api\n' > "$dev_root/api/source.txt"
git -C "$dev_root/api" add source.txt
git -C "$dev_root/api" commit -q -m "initial"
real_commit="$(git -C "$dev_root/api" rev-parse HEAD)"
real_commit_short="${real_commit:0:8}"

# A second, unrelated repo standing in for "wherever the operator's shell
# happened to be" (e.g. the Sergeant checkout) -- its HEAD is what the real
# graphify bug would have reported instead.
wrong_repo="$TEST_ROOT/unrelated-checkout"
mkdir -p "$wrong_repo"
git -C "$wrong_repo" init -q
git -C "$wrong_repo" config user.email "test@example.com"
git -C "$wrong_repo" config user.name "Test"
printf 'unrelated\n' > "$wrong_repo/f.txt"
git -C "$wrong_repo" add f.txt
git -C "$wrong_repo" commit -q -m "unrelated"
wrong_commit="$(git -C "$wrong_repo" rev-parse HEAD)"

cat > "$config/config.yaml" <<EOF
dev_root: $dev_root
EOF
cat > "$config/example.yaml" <<EOF
name: example
repos:
  - name: api
    path: api
graphify:
  output: $output
EOF

# A fake graphify whose cluster-only step deliberately reports wrong_commit
# -- exactly graphify's real _git_head()-with-no-target-dir behavior -- so
# this test proves sgt-graphify corrects it, not that the fake tool already
# behaves correctly.
cat > "$fake_bin/graphify" <<EOF
#!/usr/bin/env bash
set -euo pipefail
command="\$1"
shift
case "\$command" in
  extract)
    repo_path="\$1"
    repo_name="\$(basename "\$repo_path")"
    out=""
    while [[ \$# -gt 0 ]]; do
      if [[ "\$1" == "--out" ]]; then out="\$2"; shift 2; else shift; fi
    done
    mkdir -p "\$out/graphify-out"
    printf '{"nodes":[],"links":[],"hyperedges":[]}\n' > "\$out/graphify-out/graph.json"
    printf '{}\n' > "\$out/graphify-out/manifest.json"
    ;;
  cluster-only)
    project_root="\$1"
    mkdir -p "\$project_root/graphify-out"
    printf '{"nodes":[],"links":[],"hyperedges":[],"built_at_commit":"$wrong_commit"}\n' \
      > "\$project_root/graphify-out/graph.json"
    printf '# Graph Report\n\n- Built from commit: \`${wrong_commit:0:8}\`\n' \
      > "\$project_root/graphify-out/GRAPH_REPORT.md"
    ;;
  *)
    printf 'unexpected graphify command: %s\n' "\$command" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fake_bin/graphify"

# yq is a real dependency of sgt-graphify; use whatever the environment has
# rather than faking it, matching this suite's existing convention.
HOME="$home" PATH="$fake_bin:$PATH" SERGEANT_CONFIG="$config" \
  "$ROOT_DIR/bin/sgt-graphify" example >/dev/null

published_commit="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('built_at_commit',''))" \
  "$output/graph.json")"
[[ "$published_commit" == "$real_commit" ]] || {
  printf 'FAIL: graph.json built_at_commit = %s, want the source repo HEAD %s (got the unrelated checkout HEAD %s)\n' \
    "$published_commit" "$real_commit" "$wrong_commit" >&2
  exit 1
}

grep -Fq "Built from commit: \`$real_commit_short\`" "$output/GRAPH_REPORT.md" || {
  printf 'FAIL: GRAPH_REPORT.md does not report the source repo HEAD %s:\n' "$real_commit_short" >&2
  cat "$output/GRAPH_REPORT.md" >&2
  exit 1
}
grep -Fq "$wrong_commit" "$output/GRAPH_REPORT.md" && {
  printf 'FAIL: GRAPH_REPORT.md still contains the wrong (unrelated-checkout) commit\n' >&2
  exit 1
}

printf 'sgt-graphify built_at_commit reflects the source repo: ok\n'
