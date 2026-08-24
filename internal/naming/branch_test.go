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
