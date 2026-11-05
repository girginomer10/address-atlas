---
title: TestFlight release signing needs the keychain unlocked in the same shell and a quarantine-free Mac profile
date: 2026-11-05
status: active
tags: [gotcha, release, testflight, signing, keychain, macos, ios, app-store]
related_files: [native/AddressAtlasMac/build-mas-pkg.sh, native/AddressAtlasMac/build-mac-app.sh, native/AddressAtlasMac/upload-mas-build.sh, native/AddressAtlasMac/altool-auth.sh, native/AddressAtlasiOS/build-ios-app.sh, app-store/README.md]
---

## Gotcha

- Signing from an agent or SSH shell fails with `errSecInternalComponent`. The login keychain reports "User interaction is not allowed" and the launchd domain is `Background`, even while the Mac's GUI session is logged in. `security unlock-keychain` (password typed by the owner) works only for the shell session that ran it. Each terminal tab and each agent shell is its own session, so an agent cannot reuse an unlock done elsewhere. Do not try to get around this by launching into the GUI launchd domain; the permission system rejects it.
- The Mac App Store profile downloaded from the developer portal keeps a `com.apple.quarantine` attribute. `build-mac-app.sh` copies the profile into the bundle and then stops with "The app bundle contains a quarantined file" (exit 65). Build from a copy with `xattr -c` applied; leave the original untouched.
- The Mac App Store profile embeds the 3rd Party Mac Developer Application certificate, so the Mac build uses the 3rd Party Mac Developer Application and Installer identities. The iOS distribution profile uses Apple Distribution.
- `build-mas-pkg.sh` and `upload-mas-build.sh` require a clean `main` whose `HEAD` equals the local and live `origin/main`. Commit and push documentation only after both builds are uploaded, or the build is refused.
- The build number is `git rev-list --count HEAD`, so any later commit raises it. Both platforms must be built from the same commit in one run.

## Safe practice

- Run a release as one owner-run script in an interactive terminal: unlock the keychain once, then build, sign, validate and upload both platforms in that shell, and delete the archives, DerivedData, package and IPA afterward. Log with secrets redacted, and skip a platform whose upload the log already records so a rerun does not upload twice. The script used on 2026-11-05 lived only in an agent scratch directory and is not in the repo; recreate it from this note and `docs/handoff/2026-11-05.md` if needed.
- For iOS, archive from a temporary copy of `native/` outside the repo whose app-target Release configuration is set to manual signing with the distribution profile. A global `PROVISIONING_PROFILE_SPECIFIER` also reaches the SwiftPM library and breaks the build. Export with an `ExportOptions.plist` (`app-store-connect`, manual, profile name, `destination: export`), then check the IPA's bundle id, version, build, source commit, signature authority, team and embedded profile before uploading.
- Everything after the upload goes through the App Store Connect REST API with a short-lived ES256 token signed locally. Beta App Review Details cannot be saved (409) until contact first name, last name, phone and email are all supplied. Build "What to Test" entries already exist per locale once the Beta App Localization exists, so PATCH them instead of creating them. `GET /v1/builds/{id}/betaGroups` returns 403, so read membership with `GET /v1/betaGroups/{id}/builds`. Adding a build to an external group does not submit it; Beta App Review needs its own explicit submission.
- Keep contact details, key IDs, issuer IDs and key files out of the repo and its logs.
