# Plan critic — round 13

## Winner

Quality bar. The adopted substrate was not inert or separable.

## Largest gap

`feat/epic-durable-condition-evaluation-for-wa` adds its isolation test inside a
4-commit, 13-file, +2683/-131 product change to drain/wake behavior. The test
sources branch-local drain code and requires branch-local tests. Shipping it as
substrate would bypass disposition and Phase 4/6 critics.

## Exact challenge

Use a new-file-only substrate requiring no production change; keep existing
lifecycle branches in Phase -0B. Use fake tmux liveness for ownership mutations
rather than touching ambient panes.
