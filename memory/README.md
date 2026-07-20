# Address Atlas Repo Semantic Memory

This directory is the version-controlled source of truth for durable Address Atlas project knowledge. It preserves decisions, bug root causes, recurring gotchas, file ownership, and external API assumptions across coding-agent sessions. It does not preserve full conversations and does not replace reading the current code.

## Layout

- `architecture/`: durable system boundaries and component relationships
- `decisions/`: decisions and their rationale
- `bugfixes/`: confirmed root causes and fixes worth remembering
- `gotchas/`: recurring traps and "do not repeat" lessons
- `file-map/`: responsibilities of important files or modules
- `api-notes/`: durable external API and data-contract assumptions
- `templates/`: note templates; templates are not indexed

Chronological work logs remain in `docs/handoff/` and are deliberately excluded from semantic search.

## Commands

```bash
npm run memory:init
npm run memory:add -- bugfixes short-slug
npm run memory:sync
npm run memory:search -- "How does vault sync prevent lost updates?"
npm run memory:reindex
npm run memory:doctor
```

`memory:init` is idempotent. `memory:add` creates a dated note from the matching template. `memory:sync` atomically indexes new or changed active notes and removes deleted or inactive notes; validation failure leaves the previous cache intact. It also rebuilds a stale schema or damaged deterministic chunk/vector cache. If SQLite reports that the disposable database itself is corrupt, sync removes the database and its sidecars and rebuilds the current repository collection from validated Markdown. `memory:reindex` rebuilds the repository collection only after every source note passes validation. `memory:doctor` checks structure, metadata, index integrity, stale file references, and obvious secret patterns.

## Local index

The searchable cache lives outside the repository at `~/.codex-memory/chroma_db/repo-memory.sqlite3`. The repository-specific namespace is derived from the resolved Git root plus a credential-stripped remote URL, so separate clones never overwrite each other. The implementation uses a deterministic local feature-hash vector and SQLite; it needs no cloud service, API key, or repository-content upload. Deleting the database is safe because the curated category notes under `memory/` can rebuild it. If one shared SQLite file is corrupt, recovery discards every cached namespace in that file; the current repository is rebuilt immediately and other repositories rebuild on their next sync. `CODEX_REPO_MEMORY_DB` may select another local path, but the tool refuses cache files inside the repository.

## Adding good memory

Start from a template and keep each note concise. Include a title, date, status, tags, related files, the durable fact, the reason, the decision, and what future agents should not repeat. Prefer one coherent lesson per note.

Use `active`, `needs-review`, `deprecated`, or `superseded` as status values. Search indexes only `active` and `needs-review`; deprecated and superseded notes remain in Git for history but are not returned by default.

## Security

Never place credentials, passwords, tokens, private keys, seed phrases, `.env` contents, raw production logs, binaries, generated outputs, dependency trees, or sensitive user data in this directory. The sync command refuses notes containing common secret patterns, notes larger than 256 KiB, symlinked note/template paths, and `related_files` paths that escape the repository. Keep `related_files` repository-relative. Current code is authoritative whenever a note and implementation disagree.
