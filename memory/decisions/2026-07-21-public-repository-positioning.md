---
title: Public repository claims must match the shipped product boundary
date: 2026-07-21
status: active
tags: [decision, github, documentation, positioning, privacy]
related_files: [README.md, PRIVACY.md, .github/SECURITY.md, docs/assets/github-social-preview.svg, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ChainRegistry.swift, server/sync/README.md]
---

## Context

The original root README led with monorepo and production-operator detail,
described the optional sync service too broadly as zero-knowledge, presented all
exports as identifying, and read as if a signed public release already existed.
GitHub metadata and the social preview were empty, so the public repository did
not communicate the product or its actual trust boundaries.

## Decision

- Lead public copy with the private, local-first macOS portfolio product and the
  "sees what others miss" value: wallets, exchanges, tokens, staking, and rewards.
- `20 active networks` is an exact current claim derived from `ChainRegistry`:
  12 EVM networks, Bitcoin, Solana, TRON, XRP Ledger, and four Cosmos networks.
- Describe sync as optional, self-hostable, client-encrypted or server-blind.
  State the metadata the service sees; do not call it zero-knowledge or claim it
  sees nothing.
- Distinguish recommended share-safer summaries from explicitly disclosed full
  identifying reports. Share-safer output reduces disclosure but is not anonymous.
- Until a signed and notarized GitHub release exists, call the project a
  source-first preview and do not advertise a public download.
- OpenAI Codex may be credited as an engineering collaborator. It is not a
  product feature, and Address Atlas has no OpenAI runtime dependency.
- Keep the GitHub homepage empty until a real Devpost or product URL is public.
  Do not invent a domain or publish a dead link.
- Keep the editable social-card source and its 1280x640 rendered asset under
  `docs/assets/`. Product screenshots must use synthetic data only.

## Consequences

- Update the README, repository description, topics, and social card together
  whenever the product boundary or active registry changes.
- Operational detail belongs in the existing development, operations, release,
  native-app, and sync-service documents rather than ahead of the product story.
- Add a changelog and a real synthetic-data app screenshot with the first public
  release; never substitute a locked screen or real portfolio data.
