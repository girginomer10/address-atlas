---
title: Repo semantic memory is Markdown-first and locally indexed
date: 2026-07-13
status: active
tags: [decision, tooling, agents]
related_files: [AGENTS.md, memory/README.md, scripts/repo-memory.py]
---

## Context

Address Atlas is maintained across multiple coding agents. Chronological handoff logs help resume a session, but they are noisy and do not reliably surface durable architectural lessons.

## Decision

Curated Markdown under `memory/` is the source of truth. A deterministic repository-scoped vector index is stored outside Git and can always be rebuilt. Future agents search memory first for historical context, then inspect current code and treat it as authoritative.

## Consequences

- `docs/handoff/` remains chronological and is not indexed.
- Only high-signal decisions, bug roots, gotchas, file maps, and API assumptions belong in semantic memory.
- The index is local-only, requires no API key, and must never include secrets or raw repository content outside curated notes.
- Sync and reindex validate every curated note before an atomic cache update; an invalid or secret-bearing note cannot partially replace a previously healthy index.
- Namespace identity includes the resolved working-tree root, while stored remotes have credentials removed. Independent clones therefore cannot mix local cache entries.
