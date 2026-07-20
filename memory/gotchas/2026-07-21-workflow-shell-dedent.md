---
title: Embedded workflow shell must be checked after YAML dedent
date: 2026-07-21
status: active
tags: [gotcha, ci, github-actions, bash, yaml]
related_files: [.github/workflows/ci.yml, src/lib/sync/ci-recovery-workflow-contract.test.ts]
---

## Durable fact

A GitHub Actions workflow can be valid YAML while a multiline `run: |` scalar
is invalid shell. This is especially easy to miss in an exported Bash function:
quoted heredoc terminators must reach column zero after YAML removes the block's
common indentation, and the function body is reparsed when a child Bash imports
the export.

## Rule

- Align heredoc terminators with the `run: |` content indentation, not with the
  surrounding shell function body.
- Keep a repository test that extracts the recovery step's run scalar, removes
  the YAML content indentation, and passes the resulting script to `bash -n`.
- Pin the expected heredoc opening and closing counts so a moved or deleted
  delimiter cannot silently weaken the syntax check.
- YAML parsing and shell parsing are separate required checks.
