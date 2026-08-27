---
title: Mac App Store release boundary and evidence chain
date: 2026-08-27
status: active
tags: [decision, macos, app-store, sandbox, signing, release]
related_files: [native/AddressAtlasMac/build-mac-app.sh, native/AddressAtlasMac/build-mas-pkg.sh, native/AddressAtlasMac/validate-mas-artifact.sh, native/AddressAtlasMac/upload-mas-build.sh, native/AddressAtlasMac/altool-auth.sh, app-store/README.md, docs/RELEASE_CHECKLIST.md]
---

## Context

Address Atlas needs a Mac App Store channel without weakening or conflating the
existing Developer ID/GitHub channel. A successful local build, upload command,
processed App Store Connect build, App Review approval, and storefront release
are separate states and require different evidence.

## Decision

- Keep `direct` and `app-store` as explicit distribution channels. App Store
  builds use bundle ID `com.addressatlas.mac`, the App Store product URL, App
  Sandbox, Data Protection Keychain, a container-migration manifest, and only
  outgoing-network plus user-selected read/write file entitlements.
- Require a Mac App Store distribution profile whose App ID, Team ID, expiry,
  device scope, and sole authorized certificate match the final app signature.
  Require a same-team Mac Installer Distribution signature for the package.
- Embed the Git source commit in the app's `Info.plist` before signing. Expand
  the final installer and verify its actual payload. The read-only provenance
  record must bind that signed commit, package SHA-256, app/store identifiers,
  versions, and signing team; upload additionally requires the same clean commit
  to be live at `origin/main`.
- Support only authentication modes accepted by current Xcode `altool`: a team
  API key with issuer and explicit owner-private P8 file, or an Apple ID with an
  app-specific password referenced from Keychain. Reject plaintext password
  variables, mixed/incomplete modes, implicit P8 discovery, and the unsupported
  issuer-less individual-key subject route.
- Keep App Store privacy answers, screenshots, metadata, provider attribution,
  and review notes in the source-controlled `app-store/` packet. Screenshots use
  deterministic fictional data only.
- Do not push a `v*` tag during App Store work; it belongs to the separate
  Developer ID release workflow.

## Consequences

- Do not call the app uploaded, submitted, approved, or live without re-reading
  that exact downstream state in App Store Connect.
- Repository readiness does not authorize accepting Apple legal agreements or
  creating persistent account credentials. Before upload, the Account Holder
  must explicitly approve those actions; the App ID, record, certificates,
  profile, numeric Apple ID, and supported upload credential must exist.
- Before submission, resolve the public-data licensing evidence, legally review
  the custom EULA, choose and prove a reviewable hosted-sync path or remove that
  marketed scope from the App Store build, and complete a clean-account sandbox
  and migration smoke test.
