// Package naming produces short, speakable labels for runs.
//
// A run's canonical identity is always its id (sgt-<epoch>). A slug is a display
// and speech label only: something an operator can read off a screen and say out
// loud without spelling out digits.
//
// The form is colour + animal + place, for example "cobalt-heron-straylight".
// It reads as a name with an apposed place, like "Bengal Tiger Delhi", not as a
// sentence. Concrete, familiar, picturable words are chosen deliberately: recall
// tracks imageability, so an earlier adverb-adjective-noun scheme built from
// genre jargon ("blankly-iced-metaverse") was thematically strong and much
// harder to remember.
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

// Colours carry the genre: gunmetal, chrome, cobalt, neon, rust.
var colours = [32]string{
	"amber", "ash", "bone", "brass",
	"chrome", "coal", "cobalt", "copper",
	"crimson", "ember", "frost", "gold",
	"gunmetal", "indigo", "ivory", "jade",
	"lilac", "magenta", "mint", "neon",
	"ochre", "onyx", "plum", "rust",
	"sable", "scarlet", "silver", "slate",
	"teal", "umber", "violet", "wine",
}

// Animals carry the imageability. Concrete, familiar, one or two syllables, and
// picturable, which is what makes a triple stick. Jargon does the opposite: the
// most flavourful words (zaibatsu, franchulate, dermatrode) were the least
// memorable and the hardest to spell.
var animals = [32]string{
	"badger", "crane", "falcon", "gecko",
	"hare", "heron", "ibis", "jackal",
	"kestrel", "kite", "koi", "lark",
	"lynx", "mantis", "marten", "mole",
	"moth", "newt", "otter", "owl",
	"panther", "quail", "raven", "rook",
	"shrike", "stoat", "tapir", "viper",
	"vole", "wolf", "wren", "yak",
}

// Places are the districts these stories are set in, plus the port cities they
// inhabit. Gibson: chiba, ninsei, freeside, straylight, sprawl. Cyberpunk 2077:
// kabuki, watson, heywood, dogtown. Capped at three syllables so a slug stays
// sayable.
var places = [32]string{
	"busan", "cairo", "chiba", "dalian",
	"dogtown", "freeside", "hanoi", "harbin",
	"heywood", "jakarta", "kabuki", "karachi",
	"kowloon", "kyoto", "lagos", "lima",
	"macau", "manila", "montreal", "murmansk",
	"ninsei", "odessa", "osaka", "penang",
	"seoul", "shibuya", "sprawl", "straylight",
	"taipei", "tangier", "tijuana", "watson",
}

// Combinations is the size of the slug space.
const Combinations = len(colours) * len(animals) * len(places)

// Slug derives a stable label from seed. The same seed always yields the same
// slug, so no state is needed to render one.
func Slug(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	n := binary.BigEndian.Uint64(sum[:8])

	a := colours[n%uint64(len(colours))]
	n /= uint64(len(colours))
	b := animals[n%uint64(len(animals))]
	n /= uint64(len(animals))
	c := places[n%uint64(len(places))]

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
	return inBank(colours[:], parts[0]) &&
		inBank(animals[:], parts[1]) &&
		inBank(places[:], parts[2])
}

func inBank(bank []string, w string) bool {
	for _, b := range bank {
		if b == w {
			return true
		}
	}
	return false
}
