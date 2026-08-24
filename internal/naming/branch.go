package naming

// BranchName is the dispatched branch name for a run (decision O2):
// <type>/<change-id>. It is the single source every call site that names or
// creates that branch must use, so the name actually created can never drift
// from the name another part of the system computes independently.
func BranchName(workType, changeID string) string {
	return workType + "/" + changeID
}

// BranchNameForRun is BranchName, except for a run recorded before the O2
// migration (workType == ""), where it falls back to the branch that was
// actually created for that run at the time: "sergeant/<run-id>". Without
// this fallback, a pre-migration run's empty workType would make BranchName
// produce a malformed "/<change-id>" string that names no branch that ever
// existed.
func BranchNameForRun(runID, workType, changeID string) string {
	if workType == "" {
		return "sergeant/" + runID
	}
	return BranchName(workType, changeID)
}
