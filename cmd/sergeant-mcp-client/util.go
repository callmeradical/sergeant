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
	// ⚡ Bolt optimization: manual iteration with bytes.IndexByte to avoid allocating
	// an intermediate slice and a full string copy of the payload stream.
	for len(body) > 0 {
		var lineBytes []byte
		if i := bytes.IndexByte(body, '\n'); i >= 0 {
			lineBytes = body[:i]
			body = body[i+1:]
		} else {
			lineBytes = body
			body = nil
		}

		if len(lineBytes) > 0 && lineBytes[len(lineBytes)-1] == '\r' {
			lineBytes = lineBytes[:len(lineBytes)-1]
		}

		if bytes.HasPrefix(lineBytes, []byte("data:")) {
			dataBytes := lineBytes[5:]
			trimmed := bytes.TrimSpace(dataBytes)
			if len(trimmed) > 0 {
				out = append(out, string(trimmed))
			}
		}
	}
	return out
}
