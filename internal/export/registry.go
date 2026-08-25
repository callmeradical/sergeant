package export

import "github.com/callmeradical/sergeant/internal/config"

// Constructor builds a Target for one project's export configuration.
type Constructor func(cfg config.Export) (Target, error)

// Backends is the process-wide registry of named export backend
// constructors, keyed by config.Export.Backend. It starts empty — no
// Target implementation exists yet, which docs/prd-task-tracking-export.md
// already decided is correctly out of scope until a concrete external
// tracker is chosen. A future backend registers into this map from its own
// package (an init(), or an explicit call before cmd/sergeant/main.go's
// startExportRunners runs), so adding a backend never requires editing
// startExportRunners again.
var Backends = map[string]Constructor{}
