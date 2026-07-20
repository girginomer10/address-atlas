---
title: Production volume discovery must fail closed
date: 2026-07-14
status: active
tags: [gotcha, production, docker, postgres, caddy]
related_files: [server/sync/manage-prod.sh, server/sync/compose.prod.yml, server/sync/.env.production.example, server/sync/README.md, src/lib/sync/deployment.test.ts]
---

## Gotcha

Changing a Compose project name can silently attach fresh PostgreSQL or Caddy volumes. Selecting a volume only by the common logical names `caddy-data` or `caddy-config` can instead attach another stack's ACME state. A configured new empty volume is also unsafe when historical Address Atlas data exists. Conversely, an unrelated stack with one of those logical labels makes ownership ambiguous even on a genuinely clean Address Atlas installation.

## Safe practice

Use the stable explicit global names in `compose.prod.yml`, but run every production `up`, `down`, and `config` through `manage-prod.sh`. Automatic adoption is limited to documented Address Atlas project labels and exact legacy names, and covers PostgreSQL plus both Caddy volumes. Unscoped same-logical-label volumes are detected but never adopted; without an explicit authoritative override they deliberately stop deployment, including when another Caddy stack blocks a clean installation. Inspect the reported state, then select the existing Address Atlas volume or explicitly acknowledge the documented stable name for that role on a confirmed new installation. Never automate volume copying or use destructive volume removal during this migration path.
