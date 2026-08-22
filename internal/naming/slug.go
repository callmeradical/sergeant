// Package naming produces short, speakable labels for runs.
//
// A run's canonical identity is always its id (sgt-<epoch>). A slug is a display
// and speech label only: something an operator can read off a screen and say out
// loud without spelling out digits.
//
// The form is adverb + adjective + noun, which is the grammatical order: the
// adverb modifies the adjective, and the adjective modifies the noun. So
// "faintly-chrome-samurai" is well formed, while adjective-adverb-noun is not.
//
// Collision space is 32 * 32 * 32 = 32768. Among the 50 runs the dashboard shows
// at once the chance of a duplicate is about 1.9%, and a first duplicate is
// expected somewhere in history after roughly 227 runs. Callers that need a slug
// to be unambiguous while it matters should enforce uniqueness against
// non-terminal runs at creation time and keep the id as the real key.
package naming

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"strings"
)

// Adverbs are plain English, in the flat noir register Gibson writes in. The
// three source works supply slang adjectives and nouns but effectively no
// adverbs, so inventing "preemly" would be a word from none of them.
var adverbs = [32]string{
	"barely", "blankly", "bleakly", "brightly",
	"briskly", "coldly", "darkly", "deeply",
	"densely", "dimly", "dully", "evenly",
	"faintly", "fiercely", "flatly", "gently",
	"grimly", "harshly", "hotly", "keenly",
	"quietly", "sharply", "sleekly", "softly",
	"starkly", "steadily", "sternly", "swiftly",
	"tautly", "tersely", "utterly", "wholly",
}

// Adjectives are slang and coinages from Neuromancer, Snow Crash and
// Cyberpunk 2077, all usable attributively. "preem" and "nova" are the genuine
// CP2077 adjectives for excellent and cool. "vatgrown", "mimetic", "iced",
// "jacked", "razored" and "mirrored" are Gibson's. Past participles take an
// adverb cleanly ("coldly chromed"), as do the noun-derived attributives.
var adjectives = [32]string{
	"augmented", "borged", "burned", "chromed",
	"corpo", "derelict", "encrypted", "feral",
	"flatlined", "glitched", "hardwired", "holographic",
	"iced", "jacked", "kinetic", "mimetic",
	"mirrored", "neural", "nova", "obsolete",
	"offworld", "opaque", "preem", "razored",
	"spectral", "spliced", "static", "synaptic",
	"vatgrown", "virtual", "wired", "zeroed",
}

// Nouns are drawn from the three works:
//
//	Neuromancer  - cowboy, deck, icebreaker, flatline, matrix, sprawl, simstim,
//	               construct, zaibatsu, razorgirl, joeboy, dermatrode
//	Snow Crash   - metaverse, avatar, kourier, burbclave, franchulate, gargoyle,
//	               loglo, deliverator, ratthing, namshub
//	Cyberpunk 2077 - choom, netrunner, ripperdoc, braindance, cyberdeck, fixer,
//	               relic, engram, blackwall, edgerunner
//
// Trademarked corporation names are deliberately excluded.
var nouns = [32]string{
	"avatar", "blackwall", "braindance", "burbclave",
	"choom", "construct", "cowboy", "cyberdeck",
	"deck", "deliverator", "dermatrode", "edgerunner",
	"engram", "fixer", "flatline", "franchulate",
	"gargoyle", "icebreaker", "joeboy", "kourier",
	"loglo", "matrix", "metaverse", "namshub",
	"netrunner", "ratthing", "razorgirl", "relic",
	"ripperdoc", "simstim", "sprawl", "zaibatsu",
}

// Combinations is the size of the slug space.
const Combinations = len(adverbs) * len(adjectives) * len(nouns)

// Slug derives a stable label from seed. The same seed always yields the same
// slug, so no state is needed to render one.
func Slug(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	n := binary.BigEndian.Uint64(sum[:8])

	a := adverbs[n%uint64(len(adverbs))]
	n /= uint64(len(adverbs))
	b := adjectives[n%uint64(len(adjectives))]
	n /= uint64(len(adjectives))
	c := nouns[n%uint64(len(nouns))]

	return a + "-" + b + "-" + c
}

// SlugAttempt derives the attempt-th distinct slug for a seed. Attempt 0 is
// Slug(seed). Callers use later attempts to step off a collision while keeping
// the result deterministic and reproducible.
func SlugAttempt(seed string, attempt int) string {
	if attempt <= 0 {
		return Slug(seed)
	}
	return Slug(fmt.Sprintf("%s#%d", seed, attempt))
}

// Valid reports whether s has the shape this package produces and draws every
// word from the expected bank in the expected position.
func Valid(s string) bool {
	parts := strings.Split(s, "-")
	if len(parts) != 3 {
		return false
	}
	return inBank(adverbs[:], parts[0]) &&
		inBank(adjectives[:], parts[1]) &&
		inBank(nouns[:], parts[2])
}

func inBank(bank []string, w string) bool {
	for _, b := range bank {
		if b == w {
			return true
		}
	}
	return false
}
