package ui

import (
	"net/http"

	"github.com/callmeradical/sergeant/internal/store"
)

// handleListArtifacts answers a run-scoped view of captured artifacts (the
// dashboard's substrate for the pipeline-artifacts "Artifacts" section),
// following the same shape as handleDeliveryHistory. run_id is required for
// the same reason: an empty result set for a missing id must not be
// indistinguishable from "this run truly has no artifacts".
func (srv *Server) handleListArtifacts(w http.ResponseWriter, r *http.Request) {
	runID := r.URL.Query().Get("run_id")
	if runID == "" {
		http.Error(w, "missing run_id", http.StatusBadRequest)
		return
	}

	artifacts, err := srv.Store.ListArtifactsForRun(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if artifacts == nil {
		artifacts = []*store.ArtifactRecord{}
	}
	writeJSON(w, http.StatusOK, artifacts)
}

// handleArtifactContent serves one captured artifact's raw bytes with its
// recorded content type, for inline image rendering in the dashboard. 404
// covers both an unknown id and an id whose file is gone (past its retention
// horizon per the separate data-retention-and-rotation change, or never
// captured) — a caller cannot tell those apart, and should not need to.
func (srv *Server) handleArtifactContent(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	a, ok, err := srv.Store.GetArtifact(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !ok || a.Path == "" {
		http.Error(w, "artifact not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", a.ContentType)
	http.ServeFile(w, r, a.Path)
}
