# Releasing

Releases are cut by running the `release` workflow against a ref. It builds and verifies
first, then leaves a draft for review. The git tag is only created when that draft is
published. Signing happens in a separate job that waits for approval in the `release`
environment, which holds the certificate and the notary key. If anything is missing, it
fails with the exact `gh secret set` command.

The version is chosen when the workflow is dispatched, and nothing in the source names it.
Give it `X.Y.Z` and a `kind`. `release` tags `X.Y.Z` itself, while `beta`, `rc` and
`unsigned` add the next `-beta.N`, `-rc.N` or `-unsigned.N`, counting drafts.

```sh
gh workflow run release.yml -f version=1.1.0 -f kind=beta      # 1.1.0-beta.1, then .2, ...
gh workflow run release.yml -f version=1.1.0 -f kind=release   # 1.1.0
```

It refuses:

- a version that already exists, or isn't newer than the latest release
- a beta once an `rc` of the same version exists
- anything past the next patch, minor or major, unless that version already has a
  prerelease or `allow_jump` is set. Once published, the tap never moves backwards, so a
  typo would strand it.

A ref from before this scheme can only be released at the `baseVersion` in its own
`Version.swift`. Anything else fails in the build job.

Betas are signed and notarised the same as releases. Publishing one moves the
`wallspan@beta` cask to it. A stable release moves `wallspan@beta` too when it is newer
than the latest beta, so it never falls behind the stable cask. Unsigned prereleases never
reach the tap.

## Versions

A [snapshot or dev build](../README.md#releases) counts as a prerelease of the next patch after the last stable
release, or of a later version that already has a prerelease. So a snapshot sorts above
the release and that version's betas and rcs, and a dev build above its betas. A plain
`swift build` reports `0.0.0-local` and channel `local`.
