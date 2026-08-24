package naming

import "testing"

// Decision O2: a dispatched branch is named <type>/<change-id>, computed by
// exactly one function so every call site agrees.
func TestBranchNameJoinsTypeAndChangeID(t *testing.T) {
	cases := []struct {
		workType, changeID, want string
	}{
		{"feat", "add-stripe-webhooks", "feat/add-stripe-webhooks"},
		{"fix", "graphify-exclude-patterns", "fix/graphify-exclude-patterns"},
		{"refactor", "consolidate-store", "refactor/consolidate-store"},
	}
	for _, tc := range cases {
		if got := BranchName(tc.workType, tc.changeID); got != tc.want {
			t.Errorf("BranchName(%q, %q) = %q, want %q", tc.workType, tc.changeID, got, tc.want)
		}
	}
}

// A run recorded before the O2 migration has workType == "" — its branch was
// actually created as "sergeant/<run-id>", not "/<change-id>".
func TestBranchNameForRunFallsBackToLegacyNameWhenTypeIsEmpty(t *testing.T) {
	got := BranchNameForRun("sgt-1700000000-abc123", "", "some-change")
	want := "sergeant/sgt-1700000000-abc123"
	if got != want {
		t.Errorf("BranchNameForRun with empty type = %q, want %q", got, want)
	}
}

func TestBranchNameForRunUsesTypeWhenPresent(t *testing.T) {
	got := BranchNameForRun("sgt-1700000000-abc123", "feat", "some-change")
	want := "feat/some-change"
	if got != want {
		t.Errorf("BranchNameForRun with type = %q, want %q", got, want)
	}
}
