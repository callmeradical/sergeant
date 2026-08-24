package naming

// BranchName is the dispatched branch name for a run (decision O2):
// <type>/<change-id>. It is the single source every call site that names or
// creates that branch must use, so the name actually created can never drift
// from the name another part of the system computes independently.
func BranchName(workType, changeID string) string {
	return workType + "/" + changeID
}
