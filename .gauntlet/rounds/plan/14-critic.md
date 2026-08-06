# Plan critic — round 14

## Winner

Quality bar. The inventory omitted non-origin commit stores.

## Largest gap

The no-mistakes bare remote held 82 refs and 124 non-merge commits reachable
from no local branch or origin ref; a gate ref held two more. Twenty-seven refs
contained unique work. Origin-only inventory could discard them as nonexistent.

A configured remote URL also embedded a credential. Copying it into fixtures or
evidence would leak it.

## Exact challenge

Inventory every configured remote/ref with trust class and owner. Fail while any
unique commit lacks one. Record only sanitized host/path plus URL digest.
Credential-bearing fixture URLs must fail without printing the secret; untrusted
fork refs need provenance before becoming mergeable.
