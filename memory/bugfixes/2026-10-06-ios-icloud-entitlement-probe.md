---
title: iOS iCloud entitlement probe must read the code signature
date: 2026-10-06
status: active
tags: [bugfix, ios, icloud, entitlements, codesign, testflight]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasMac/ICloudVaultService.swift, native/AddressAtlasiOS/Sources/AddressAtlasiOS/ICloudScreen.swift]
---

## Symptom

`ICloudVaultService.isConfigured` was false on iOS in every Debug simulator
build ("iCloud isn't available in this build") and, by construction, in App
Store/TestFlight builds, so iCloud save/restore could never start there.

## Root cause

The iOS probe (no SecTask API) only read (1) a `__TEXT,__entitlements` section
from the image found via `dladdr`, and (2) `embedded.mobileprovision`.
- Debug builds run app code from `<App>.debug.dylib`; `dladdr` returns that
  dylib, which has no entitlements section.
- App Store and TestFlight installs carry no embedded provisioning profile
  (Apple TN3125). The exported IPA still has one, so local IPA inspection is
  misleading.
- Device builds have no `__entitlements` section either; their entitlements
  live only in the code signature.

## Fix and invariant

`EmbeddedEntitlements` now checks the entitlements section in both the
`dladdr` image and dyld image 0 (main executable), then the
`CSSLOT_ENTITLEMENTS` blob (magic `0xfade7171`) inside the main executable's
`LC_CODE_SIGNATURE` superblob (`0xfade0cc0`, big-endian), parsed once and
bounds-checked, then the profile as a last resort. Every failure stays fail
closed. The macOS SecTask path is unchanged. Simulator code signatures carry an
empty entitlements dict, so an empty signature result falls through.

## Verification

- Parser run on macOS against the signed TestFlight 0.2.0 (91) executable:
  returned `iCloud.com.addressatlas.mac`, Production, CloudKit.
- Debug simulator: iCloud screen moved from "not available in this build" to
  the real account state ("Sign in to iCloud").
- Still open: a real TestFlight/App Store install with a signed-in Apple
  Account doing save/restore; the `#if !os(macOS)` block is not covered by the
  macOS `swift test` run.
