package store

import (
	"fmt"
	"strings"
)

// RenderIntentBrief renders the canonical brief for one bullet of an
// intent: the intent's statement, the bullet's repo/position/status (and
// blocked reason, if blocked), the OpenSpec change it resolved to, and the
// gate names the caller supplies. It performs no write and reads nothing
// beyond the given intent's own rows — it is the one rendering both
// dispatch paths (D1) must call, so they cannot describe the same work
// differently.
func (s *Store) RenderIntentBrief(intentID, repo string, gates []string) (string, error) {
	intent, err := s.GetIntent(intentID)
	if err != nil {
		return "", fmt.Errorf("loading intent %q for brief: %w", intentID, err)
	}
	bullets, err := s.ListBulletsForIntent(intentID)
	if err != nil {
		return "", err
	}
	var bullet *BulletRecord
	for i := range bullets {
		if bullets[i].Repo == repo {
			bullet = &bullets[i]
			break
		}
	}
	if bullet == nil {
		return "", fmt.Errorf("no bullet found for repo %q on intent %q", repo, intentID)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "# Intent\n\n%s\n\n", intent.Statement)
	fmt.Fprintf(&b, "# Bullet\n\nRepo: %s\nPosition: %d of %d\nStatus: %s\n",
		bullet.Repo, bullet.Position, len(bullets), bullet.Status)
	if bullet.Status == "blocked" && bullet.BlockedReason != "" {
		fmt.Fprintf(&b, "Blocked reason: %s\n", bullet.BlockedReason)
	}
	if intent.ChangeID != "" {
		fmt.Fprintf(&b, "\n# OpenSpec change\n\n%s", intent.ChangeID)
		if intent.ChangeRepo != "" {
			fmt.Fprintf(&b, " (%s)", intent.ChangeRepo)
		}
		b.WriteString("\n")
	}
	if len(gates) > 0 {
		fmt.Fprintf(&b, "\n# Gates\n\n%s\n", strings.Join(gates, ", "))
	}
	return b.String(), nil
}
