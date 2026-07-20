---
title: Server timestamps must preserve Swift canonical date bytes
date: 2026-07-14
status: active
tags: [bugfix, dates, swift, sync, checksum]
related_files: [src/lib/sync/envelope.ts, src/lib/sync/envelope.test.ts, src/lib/sync/native-config.ts, src/lib/sync/native-config.test.ts]
---

## Symptom

JavaScript `Date` accepts some impossible calendar values by normalizing them, such as moving February 30 into March. An accepted encrypted envelope could then be rejected or textually changed by Swift, invalidating the canonical byte size and outer checksum.

## Root cause

Checking only that `new Date(value)` is finite does not prove the parsed UTC calendar components equal the input. Envelope dates also have a narrower contract than general native-config timestamps because Swift's canonical envelope encoder emits whole seconds.

## Fix and invariant

Server timestamp validation must round-trip every captured UTC component. Native endpoint timestamps may use the explicitly tested fractional-second grammar, while encrypted envelope `createdAt` must remain exactly `YYYY-MM-DDTHH:mm:ssZ`. Do not accept normalized dates, `24:00`, leap seconds, or fractional envelope seconds such as `.000Z`; changing the spelling changes the checksum preimage.

## Verification

- Keep invalid-calendar and Swift edge-contract coverage in `envelope.test.ts` and `native-config.test.ts` whenever date parsing or canonical serialization changes.
