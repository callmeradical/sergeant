package dag

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// v1FleetRoot is the path v2 must never build. Decision D7 in AGENTS.md: v1 is
// not a dependency, and ~/.local/share/sergeant/fleet is v1's. The two layouts
// have the same shape and incompatible meaning, so a path built against the
// wrong one fails silently rather than erroring.
const v1FleetRoot = "share/sergeant/fleet"

// Scenario: The helper honours the environment override.
func TestFleetRootHonoursEnvironmentOverride(t *testing.T) {
	want := t.TempDir()
	t.Setenv("SERGEANT_FLEET_DIR", want)

	if got := FleetRoot(); got != want {
		t.Errorf("FleetRoot() = %q, want the SERGEANT_FLEET_DIR value %q", got, want)
	}
}

// Scenario: The helper defaults to the v2 root, never v1's.
func TestFleetRootDefaultsToV2RootNeverV1(t *testing.T) {
	t.Setenv("SERGEANT_FLEET_DIR", "")

	got := filepath.ToSlash(FleetRoot())

	if !strings.HasSuffix(got, "share/sergeant-v2/fleet") {
		t.Errorf("FleetRoot() = %q, want a path ending %q", got, "share/sergeant-v2/fleet")
	}
	if strings.Contains(got, v1FleetRoot) {
		t.Errorf("FleetRoot() = %q, must not contain v1 root %q", got, v1FleetRoot)
	}
}

// Scenario: FleetDir agrees with the helper.
//
// Two independent resolutions of the same root are how the current defect
// arose, so this asserts one is expressed in terms of the other rather than
// that they happen to match.
func TestFleetDirIsFleetRootJoinedWithRunAndRepo(t *testing.T) {
	for _, tc := range []struct {
		name  string
		fleet string
	}{
		{name: "override set", fleet: t.TempDir()},
		{name: "override unset", fleet: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("SERGEANT_FLEET_DIR", tc.fleet)

			want := filepath.Join(FleetRoot(), "run-7", "backend")
			if got := FleetDir("run-7", "backend"); got != want {
				t.Errorf("FleetDir(%q, %q) = %q, want FleetRoot() joined with them = %q",
					"run-7", "backend", got, want)
			}
		})
	}
}

// Scenario: No source outside the helper names v1's fleet root.
//
// This is the scenario that holds the invariant. A test pinning the four known
// call sites would pass again the moment someone added a fifth, so this scans
// every non-test Go source under internal/ instead.
//
// It matches on path literals in code, not on raw file text, for two reasons:
//
//  1. Comments legitimately name v1's root to explain why it is wrong —
//     FleetRoot's own doc comment and internal/handoff/envelope.go both do.
//     Reading the AST excludes comments structurally, so no exclusion list is
//     needed and none is granted.
//  2. The offenders do not contain the literal "share/sergeant/fleet" at all.
//     They build it a segment at a time, as
//     filepath.Join(home, ".local", "share", "sergeant", "fleet"). A substring
//     search over the source text finds nothing and passes on a broken tree.
//     So consecutive string-literal arguments to a call are joined as path
//     segments before matching.
//
// The store's database path is out of scope for this change and stays out of
// scope here by construction: it builds share/sergeant/sergeant.db, which does
// not contain share/sergeant/fleet.
func TestNoSourceOutsideTheHelperNamesV1FleetRoot(t *testing.T) {
	internalDir := internalSourceDir(t)
	repoRoot := filepath.Dir(internalDir)

	var offenders []string
	err := filepath.WalkDir(internalDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		offenders = append(offenders, scanForV1FleetRoot(t, repoRoot, path)...)
		return nil
	})
	if err != nil {
		t.Fatalf("walking %s: %v", internalDir, err)
	}

	if len(offenders) > 0 {
		sort.Strings(offenders)
		t.Errorf("%d source location(s) build v1's fleet root %q; every fleet path must go through dag.FleetRoot():\n  %s",
			len(offenders), v1FleetRoot, strings.Join(offenders, "\n  "))
	}
}

// internalSourceDir is the internal/ directory of this repository, located from
// this test file rather than the working directory so the scan covers the whole
// tree no matter which package `go test` is run from.
func internalSourceDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed, cannot locate the source tree to scan")
	}
	// thisFile is <repo>/internal/dag/fleet_root_test.go
	dir := filepath.Dir(filepath.Dir(thisFile))
	if filepath.Base(dir) != "internal" {
		t.Fatalf("expected to locate the internal/ directory, got %q", dir)
	}
	return dir
}

var repeatedSlash = regexp.MustCompile(`/{2,}`)

// scanForV1FleetRoot reports every location in one Go source file whose code
// builds a path containing v1's fleet root, as "<rel path>:<line>: <path>".
func scanForV1FleetRoot(t *testing.T, repoRoot, path string) []string {
	t.Helper()

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, nil, 0)
	if err != nil {
		t.Fatalf("parsing %s: %v", path, err)
	}

	rel, err := filepath.Rel(repoRoot, path)
	if err != nil {
		rel = path
	}

	var found []string
	seen := map[int]bool{}
	check := func(pos token.Pos, built string) {
		built = repeatedSlash.ReplaceAllString(strings.ReplaceAll(built, `\`, "/"), "/")
		if !strings.Contains(built, v1FleetRoot) {
			return
		}
		line := fset.Position(pos).Line
		if seen[line] {
			return
		}
		seen[line] = true
		found = append(found, fmt.Sprintf("%s:%d: builds %q", filepath.ToSlash(rel), line, built))
	}

	ast.Inspect(file, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.CallExpr:
			// Join each run of consecutive string-literal arguments as path
			// segments. A non-literal argument (home, taskID, run.ID) ends the
			// run, so unrelated literals on either side are never fused.
			var segments []string
			var start token.Pos
			flush := func() {
				if len(segments) > 0 {
					check(start, strings.Join(segments, "/"))
					segments = nil
				}
			}
			for _, arg := range node.Args {
				lit, ok := stringLiteral(arg)
				if !ok {
					flush()
					continue
				}
				if len(segments) == 0 {
					start = arg.Pos()
				}
				segments = append(segments, lit)
			}
			flush()
		case *ast.BasicLit:
			// Catches the whole root written as one literal, wherever it sits.
			if lit, ok := stringLiteral(node); ok {
				check(node.Pos(), lit)
			}
		}
		return true
	})

	return found
}

func stringLiteral(e ast.Expr) (string, bool) {
	lit, ok := e.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	s, err := strconv.Unquote(lit.Value)
	if err != nil {
		return "", false
	}
	return s, true
}
