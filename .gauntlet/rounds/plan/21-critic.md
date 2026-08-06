# Plan critic — round 21

## Winner

Quality bar. Existing-work disposition could revert shipped main.

## Largest gap

Branches 270-366 commits behind main carried 27k+ net deletions and could delete
shipped tests while every disposition gate passed. No merge-base, behind count
or intended deletion scope was recorded.

## Exact challenge

Refuse merge until a branch is rebased onto current integration SHA and every
deletion belongs to its owning intent. The known 270-commits-behind branch must
fail naming removed tests. Recompute every remaining branch after each merge and
finish disposition before test migration.
