---
title: Dependabot cannot rebase under the main ruleset, an Actions bump needs the contract test pin, and v* tags start the release workflow
date: 2026-11-05
status: active
tags: [gotcha, github, dependabot, ci, release, tags]
related_files: [.github/dependabot.yml, .github/workflows/ci.yml, .github/workflows/release.yml, src/lib/sync/release-workflow-contract.test.ts, app-store/README.md]
---

## Gotcha

- The repository ruleset `main` targets `~ALL` branches, not only `main`. Its `update` and `non_fast_forward` rules protect Dependabot's own branches too, so `@dependabot rebase` fails with "Something went wrong" and the PR stays on its old base. A Dependabot PR that was red when it was opened stays red; its failure is inherited from that old base, not necessarily from the bump. Apply the bump by hand on a branch instead.
- `src/lib/sync/release-workflow-contract.test.ts` asserts the exact `actions/setup-node` commit SHA in `release.yml`. A Dependabot bump of that action fails the "Web and sync server" job until the test's SHA is updated in the same commit. Check every pinned SHA against the upstream tag (`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`) before accepting it.
- Any pushed tag that matches `v*` starts `release.yml` ("Release macOS", the Developer ID and notarized DMG channel). Its first job only accepts `vMAJOR.MINOR.PATCH`, so a tag such as `v0.2.0-beta.175` would fail that run on a macOS runner and leave a red run on the Actions tab. `app-store/README.md` already says never to push a `v*` tag as a Mac App Store action.
- `.github/dependabot.yml` ignores semver-major updates for the npm and Docker ecosystems, because the legacy sync service stays on Node 22. Ignore rules apply to version updates only, not to Dependabot security updates.

## Safe practice

- Name TestFlight pre-release tags without the `v` prefix (for example `0.2.0-beta.175`). Keep `v*` for a signed and notarized DMG release.
- When bumping a pinned action, grep the repository for the old SHA (tests and scripts, not only workflows) and update every pin in one commit.
- Do not rely on `gh pr merge` for a Dependabot PR whose checks predate main's current state; re-run CI on a branch that contains the change.
