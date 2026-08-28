package main

import (
	"encoding/json"
	"strings"
)

// extractJSONRPCID returns the "id" field of a JSON-RPC line, if it has one.
// A JSON-RPC notification (no id, or an explicit null id) has no response to
// correlate, so callers use ok=false to distinguish "nothing to reply to"
// from "reply with this id".
func extractJSONRPCID(line string) (json.RawMessage, bool) {
	var msg struct {
		ID json.RawMessage `json:"id"`
	}
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		return nil, false
	}
	if len(msg.ID) == 0 || string(msg.ID) == "null" {
		return nil, false
	}
	return msg.ID, true
}

// parseSSEData extracts the payload of every "data:" line in a
// text/event-stream body. Each MCP SSE event carries one complete JSON-RPC
// message per data line (no multi-line continuation in practice for this
// server's responses), so each returned string is one message ready to write
// to stdout as-is.
func parseSSEData(body []byte) []string {
	var out []string
	s := string(body)
	for len(s) > 0 {
		var line string
		idx := strings.IndexByte(s, '\n')
		if idx >= 0 {
			line = s[:idx]
			s = s[idx+1:]
		} else {
			line = s
			s = ""
		}

		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}

		if data, ok := strings.CutPrefix(line, "data:"); ok {
			trimmed := strings.TrimSpace(data)
			if trimmed != "" {
				out = append(out, trimmed)
			}
		}
	}
	return out
}
