# Cross-Agent Handoff And Repo Memory

The user often moves between Codex, Claude, and other coding agents. After making meaningful repository changes, leave a concise repo-local handoff note so the next agent can continue without reconstructing the whole session.

## Version Control Defaults

Unless the user explicitly says otherwise, after every meaningful repository change:

- Commit all intended git-visible changes.
- Push the commit to `origin/main`.
- Use `main` as the default target branch.
- Run the relevant available verification before committing when feasible.
- Do not commit ignored/generated/local-only artifacts, secrets, credentials, `.env` contents, private keys, tokens, or data that upstream terms say should remain local.
- Do not force-push, rewrite history, or reset user work unless the user explicitly asks for that exact operation.

Use two layers:

1. Handoff log: chronological, lightweight, useful for "what changed in this session?"
2. Repo semantic memory: curated, high-signal, useful for "what should future agents remember across sessions?"

Do not dump every terminal output, raw transcript, or temporary failure into semantic memory. Semantic memory should only receive durable decisions, bug root causes, gotchas, conventions, file responsibility changes, API/data-model notes, and "do not repeat this" lessons.

When finishing meaningful file changes:

- Prefer an existing repo-local log/handoff location if one already exists, such as `logs/`, `log/`, `.ai/logs/`, `.claude/logs/`, `memory/handoff/`, or `docs/logs/`.
- If repo semantic memory is installed and no other log location exists, use `memory/handoff/YYYY-MM-DD.md` for handoff entries.
- If no memory system or existing log location exists, ask before creating a new log directory unless the user explicitly requested logging.
- Keep each entry short: date/time, agent name, task summary, files touched, commands/tests run, result, open risks, and next steps.
- Never log secrets, credentials, API keys, tokens, `.env` contents, private keys, raw production logs, or sensitive user data.
- If the change produced a durable lesson, also add or update a curated note under `memory/decisions/`, `memory/bugfixes/`, `memory/gotchas/`, `memory/file-map/`, or `memory/api-notes/`.
- If memory conflicts with current code, treat current code as authoritative and mark the memory note for review instead of trusting it silently.

Good handoff entry shape:

```markdown
## YYYY-MM-DD HH:MM - Codex

- Task: one-line summary.
- Changed: short list of files or areas.
- Verified: commands/tests run, or "not run" with reason.
- Memory: note added/updated, or "none; no durable lesson."
- Next: open follow-ups, risks, or handoff pointers.
```

<!-- repo-semantic-memory:start -->
## Repo Semantic Memory

- Before architecture, debugging, refactoring, API, workflow, or data-model work, run `npm run memory:search -- "<query>"` and then inspect the current code.
- Treat `memory/**/*.md` as the curated source of truth and the local index as a rebuildable cache.
- Run `npm run memory:sync` after changing curated memory notes and `npm run memory:doctor` before handing work off.
- Add or update concise notes after durable decisions, bug fixes, recurring gotchas, file responsibility changes, or external API assumptions.
- Keep chronological session details in `docs/handoff/`; do not index raw handoff logs as semantic memory.
- If a memory note conflicts with code, follow the code and mark the note `needs-review` rather than silently trusting it.
- Never store secrets, credentials, tokens, private keys, `.env` contents, raw production logs, or sensitive user data in memory.
- Keep all searches and notes scoped to this repository.
<!-- repo-semantic-memory:end -->
