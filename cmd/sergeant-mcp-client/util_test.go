package main

import "testing"

func TestExtractJSONRPCIDPresent(t *testing.T) {
	id, ok := extractJSONRPCID(`{"jsonrpc":"2.0","id":7,"method":"tools/call"}`)
	if !ok {
		t.Fatal("extractJSONRPCID() ok = false, want true")
	}
	if string(id) != "7" {
		t.Fatalf("extractJSONRPCID() id = %s, want 7", id)
	}
}

func TestExtractJSONRPCIDStringForm(t *testing.T) {
	id, ok := extractJSONRPCID(`{"jsonrpc":"2.0","id":"abc-123","method":"tools/call"}`)
	if !ok {
		t.Fatal("extractJSONRPCID() ok = false, want true")
	}
	if string(id) != `"abc-123"` {
		t.Fatalf("extractJSONRPCID() id = %s, want \"abc-123\"", id)
	}
}

func TestExtractJSONRPCIDAbsentIsNotification(t *testing.T) {
	_, ok := extractJSONRPCID(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if ok {
		t.Fatal("extractJSONRPCID() ok = true for a notification with no id, want false")
	}
}

func TestExtractJSONRPCIDNullIsNotification(t *testing.T) {
	_, ok := extractJSONRPCID(`{"jsonrpc":"2.0","id":null,"method":"notifications/initialized"}`)
	if ok {
		t.Fatal("extractJSONRPCID() ok = true for a null id, want false")
	}
}

func TestExtractJSONRPCIDMalformedLine(t *testing.T) {
	_, ok := extractJSONRPCID(`not json`)
	if ok {
		t.Fatal("extractJSONRPCID() ok = true for malformed input, want false")
	}
}

func TestParseSSEDataSingleEvent(t *testing.T) {
	body := []byte("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n")
	got := parseSSEData(body)
	if len(got) != 1 {
		t.Fatalf("parseSSEData() = %v, want 1 entry", got)
	}
	if got[0] != `{"jsonrpc":"2.0","id":1,"result":{}}` {
		t.Fatalf("parseSSEData()[0] = %q", got[0])
	}
}

func TestParseSSEDataMultipleEvents(t *testing.T) {
	body := []byte("data: {\"a\":1}\n\ndata: {\"a\":2}\n\n")
	got := parseSSEData(body)
	if len(got) != 2 || got[0] != `{"a":1}` || got[1] != `{"a":2}` {
		t.Fatalf("parseSSEData() = %v", got)
	}
}

func TestParseSSEDataNoEvents(t *testing.T) {
	got := parseSSEData([]byte("application/json body, not sse"))
	if len(got) != 0 {
		t.Fatalf("parseSSEData() = %v, want empty", got)
	}
}
