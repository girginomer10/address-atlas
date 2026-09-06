---
title: Private iCloud copies replace the native hosted-sync product
date: 2026-09-07
status: active
tags: [decision, macos, icloud, cloudkit, encryption, sync]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/ICloudVaultCodec.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ICloudVaultService.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateICloud.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ICloudSyncView.swift, native/AddressAtlasMac/icloud-entitlements.py, docs/ICLOUD.md]
---

The user chose their own iCloud account instead of an Address Atlas account and
developer-operated backups, with no paid API subscription. The native product
now exposes explicit whole-vault save/restore/delete in CloudKit's private
database. Do not call it automatic multi-device merging.

Use a distinct synchronizable Keychain key per cloud account/key UUID. Rewrap
exchange credentials between local and cloud keys; never upload the device's
local vault key. Bind the encrypted document to account and revision. Missing
keys for an existing cloud record fail closed. The local recovery kit does not
recover the separate iCloud key; explain this boundary accurately.

Check the saved revision AND use CloudKit conditional writes. The default zone
does not support multi-record atomic batches, so the single-record conditional
save uses atomically:false. Preserve a local rollback checkpoint before restore
and keep the current iCloud baseline when rolling back local content.

Production AppState disables legacy server config refresh, scan dependencies,
and automatic journal replay. Old interrupted journals require explicit local
migration. Retain server code for migration tests; do not confuse retained code
with a current product dependency or assert existing infrastructure was deleted.

Unsigned builds must check entitlements before constructing CKContainer. Signed
store builds require the exact Production container. Apple profiles may encode
environment grants as an array and services as a wildcard; the signed app still
requests only Production/CloudKit/the exact container.

Real two-Mac transfers, Keychain delivery, Production schema and store signing
remain external verification gates; local tests or screenshots do not prove them.
