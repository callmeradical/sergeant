package main

import (
	"bytes"
	"encoding/json"
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
	// Performance optimization: manually iterate over body using bytes.IndexByte
	// to avoid allocating an intermediate string slice.
	for len(body) > 0 {
		var line []byte
		if i := bytes.IndexByte(body, '\n'); i >= 0 {
			line = body[:i]
			body = body[i+1:]
		} else {
			line = body
			body = nil
		}

		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}

		if bytes.HasPrefix(line, []byte("data:")) {
			trimmed := bytes.TrimSpace(line[5:])
			if len(trimmed) > 0 {
				out = append(out, string(trimmed))
			}
		}
	}
	return out
}
