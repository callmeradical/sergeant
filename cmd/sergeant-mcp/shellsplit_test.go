package main

import (
	"reflect"
	"testing"
)

func TestShellSplit(t *testing.T) {
	tests := []struct {
		input    string
		expected []string
	}{
		{"", nil},
		{"hello", []string{"hello"}},
		{"hello world", []string{"hello", "world"}},
		{"hello  \t  world", []string{"hello", "world"}},
		{`hello "world of" test 'single quoted'`, []string{"hello", "world of", "test", "single quoted"}},
		{`  leading and trailing  `, []string{"leading", "and", "trailing"}},
		{`"unclosed double`, []string{"unclosed double"}},
		{`'unclosed single`, []string{"unclosed single"}},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := shellSplit(tt.input)
			if !reflect.DeepEqual(got, tt.expected) {
				t.Errorf("shellSplit(%q) = %v; want %v", tt.input, got, tt.expected)
			}
		})
	}
}
