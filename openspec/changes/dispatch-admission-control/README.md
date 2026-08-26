Dispatch checks a machine-wide live-worker census and system load/memory
before spawning a new worker pane, queues durably (FIFO, reorderable,
indefinite wait) instead of refusing or oversubscribing when over budget,
and gains one independent two-tier hard-stop command — because two
coordinators on one machine already drove it past 40 live panes with no
warning and no backpressure.
