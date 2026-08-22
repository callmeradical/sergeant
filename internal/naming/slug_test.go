package naming

import (
	"strings"
	"testing"
)

func TestSlugShapeIsAdverbAdjectiveNoun(t *testing.T) {
	s := Slug("sgt-1787421263")
	parts := strings.Split(s, "-")
	if len(parts) != 3 {
		t.Fatalf("slug %q should have 3 words, got %d", s, len(parts))
	}
	if !inBank(adverbs[:], parts[0]) {
		t.Errorf("first word %q is not an adverb", parts[0])
	}
	if !inBank(adjectives[:], parts[1]) {
		t.Errorf("second word %q is not an adjective", parts[1])
	}
	if !inBank(nouns[:], parts[2]) {
		t.Errorf("third word %q is not a noun", parts[2])
	}
	if !Valid(s) {
		t.Errorf("Valid rejected its own output: %q", s)
	}
}

// The same run must always render the same label, so no state is needed.
func TestSlugIsDeterministic(t *testing.T) {
	for _, seed := range []string{"sgt-1", "sgt-1787421263", ""} {
		if a, b := Slug(seed), Slug(seed); a != b {
			t.Errorf("seed %q produced %q then %q", seed, a, b)
		}
	}
}

func TestSlugAttemptStepsOffACollision(t *testing.T) {
	seed := "sgt-1787421263"
	base := SlugAttempt(seed, 0)
	if base != Slug(seed) {
		t.Errorf("attempt 0 should equal Slug: %q vs %q", base, Slug(seed))
	}
	seen := map[string]bool{base: true}
	for i := 1; i <= 8; i++ {
		s := SlugAttempt(seed, i)
		if !Valid(s) {
			t.Errorf("attempt %d produced an invalid slug %q", i, s)
		}
		if seen[s] {
			t.Errorf("attempt %d repeated an earlier slug %q", i, s)
		}
		seen[s] = true
	}
}

func TestBanksAreCleanAndFullSize(t *testing.T) {
	if Combinations != 32*32*32 {
		t.Errorf("Combinations = %d, want %d", Combinations, 32*32*32)
	}
	for name, bank := range map[string][]string{
		"adverbs":    adverbs[:],
		"adjectives": adjectives[:],
		"nouns":      nouns[:],
	} {
		if len(bank) != 32 {
			t.Errorf("%s has %d entries, want 32", name, len(bank))
		}
		seen := map[string]bool{}
		for _, w := range bank {
			if seen[w] {
				t.Errorf("%s repeats %q", name, w)
			}
			seen[w] = true
			if w != strings.ToLower(w) || strings.ContainsAny(w, " -_") {
				t.Errorf("%s entry %q must be lowercase with no separators", name, w)
			}
		}
	}
	// Every adverb must end in -ly so it reads as an adverb modifying the adjective.
	for _, a := range adverbs {
		if !strings.HasSuffix(a, "ly") {
			t.Errorf("adverb %q does not end in -ly", a)
		}
	}
}

func TestValidRejectsMalformed(t *testing.T) {
	bad := []string{
		"",
		"chrome",
		"chrome-samurai",
		"faintly-chrome-samurai-extra",
		"samurai-chrome-faintly", // right words, wrong order
		"loudly-chrome-samurai",  // adverb not in bank
	}
	for _, s := range bad {
		if Valid(s) {
			t.Errorf("Valid accepted %q", s)
		}
	}
}

// Spread check: distinct seeds should not pile onto one label.
func TestSlugSpread(t *testing.T) {
	seen := map[string]int{}
	const n = 2000
	for i := 0; i < n; i++ {
		seen[Slug(string(rune('a'+i%26))+string(rune(i)))]++
	}
	if len(seen) < n*7/10 {
		t.Errorf("only %d distinct slugs from %d seeds; distribution looks poor", len(seen), n)
	}
}
