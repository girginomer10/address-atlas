# Address Atlas Mac App Store Submission

This directory is the source-controlled submission packet for Address Atlas 0.2.0. It does not prove that a build has been uploaded, accepted, or made available. App Store Connect is authoritative for those states.

## Product record

- Platform: macOS
- Bundle ID: `com.addressatlas.mac`
- App Store Connect Apple ID: `6809515105`; current build and distribution evidence is recorded below
- SKU: `address-atlas-macos-001`
- Version: `0.2.0`
- Primary language: English (U.S.)
- Primary category: Finance
- Price: Free
- Release method: Manual release after approval
- Privacy policy: <https://github.com/girginomer10/address-atlas/blob/main/PRIVACY.md>
- Terms of Use: <https://github.com/girginomer10/address-atlas/blob/main/TERMS.md>
- Support: <https://github.com/girginomer10/address-atlas/blob/main/SUPPORT.md>

The App Store Connect record's numeric Apple ID must be supplied as `ADDRESS_ATLAS_APP_STORE_ID`. Do not invent or reuse an ID from another product.

## Release checkpoint — October 6, 2026

Both release artifacts use source commit `4782ce544e9fbca69f255bb3312e8c392ddbfb01`. No product/UI fixes were made for this release; the findings in [the native review](../docs/NATIVE-UI-REVIEW-2026-10-06.md) remain open.

- **macOS:** `0.2.0 (91)`, App Store Connect record `6809515105`, build/delivery `e206279c-5c82-435c-b83d-1116067ef647`. Processing is `VALID`; internal state is `IN_BETA_TESTING`. The `Internal Testing` group (`a916d6ad-16d5-43d2-99db-f1a38ec90cab`) contains only build 91, has one owner tester in `INVITED` state, and does not automatically distribute all builds. External state is `READY_FOR_BETA_SUBMISSION`; external review/distribution is not claimed. Package SHA-256: `621e3d49f15e32c9a1758576d3a6b1e2a1add7af2f106d113d22e98d20d2afce`.
- **iOS:** App Store Connect record `6819783390`, named `Address Atlas iOS`, bundle `com.addressatlas.ios`. App ID resource `38F5FS52SQ` is associated with the existing `iCloud.com.addressatlas.mac` container. Distribution profile `Q4256KXLR2` (UUID `4300beff-0b0a-453b-829c-ec222820c860`) was created with the shared container, Production environment, and keychain groups. Signed archive and exported IPA were verified without changing repository source. IPA SHA-256: `facde6da2f234d6d395750a47a1e6890497117d9e7082655e88815b255b665ef`. Apple validation passed and upload completed successfully for `0.2.0 (91)`, build/delivery `84674af4-e59e-418e-8686-a5bda9755dbd`. Processing is `VALID`, `usesNonExemptEncryption=false`, and internal state is `IN_BETA_TESTING`. The `Internal Testing` group (`e4e697e6-0d4d-4a72-9d1c-86edd2375014`) contains only build 91, has one sole-account-owner tester in `INVITED` state, and has `hasAccessToAllBuilds=false`. External state is `READY_FOR_BETA_SUBMISSION`; external review/distribution is not claimed. The final iOS readback was verified at 19:03 Europe/Paris.
- Physical-device installation/acceptance, Mac-to-iPhone iCloud restore, App Review approval, and public storefront availability are not established by these release steps.

## iOS product record

The iOS App Store Connect record is separate from the Mac record. Apple rejected reuse of `Address Atlas` for this new record, so its App Store Connect name is `Address Atlas iOS`; the native app's display name remains `Address Atlas`.

- Platform: iOS (iPhone and iPad)
- Bundle ID: `com.addressatlas.ios`
- App Store Connect Apple ID: `6819783390`; do not reuse the Mac record's `6809515105`
- SKU: `address-atlas-ios-001`
- Binary marketing version: `0.2.0`, derived from the same `currentAppVersion` and build number as the Mac app
- App Store distribution draft: Apple created version `1.0` in `Prepare for Submission`; it remains unchanged and unsubmitted. This release task covers TestFlight only.
- Primary language: English (U.S.)

### Planned public-store metadata (not applied or verified in this TestFlight task)

These are proposed submission values, not the live iOS record's configured metadata. The new record's default automatic release setting was left unchanged; category, price, public-store URLs, and privacy answers were not entered or verified in this task.

- Primary category: Finance
- Price: Free
- Release method: Manual release after approval
- Privacy policy, Terms of Use, and Support URLs: the same three links as the macOS record
- Privacy answers: intended parity with the macOS record, subject to the exact signed build and Apple's questionnaire; see `privacy-label.md`

### Remaining iOS release and device gates

- Verify the signed artifact uses `com.addressatlas.ios`, team `VWW3GZL279`, and the created iOS profile's CloudKit/Production/shared-keychain grants. The Mac App Store profile, `ADDRESS_ATLAS_PROVISIONING_PROFILE`, `ADDRESS_ATLAS_APP_STORE_ID`, and the Mac numeric Apple ID must not be reused.
- Install and accept the distributed build on a physical iPhone or iPad. Prove a Mac→iPhone encrypted restore with iCloud Passwords & Keychain enabled; the simulator cannot sync iCloud Keychain. Kraken connections need a separate read-only key per device.
- Produce App Store iPhone and iPad screenshots with fictional data; the local review captures are not a submission screenshot set.
- The iOS `Info.plist` still leaves `AddressAtlasUpdateURL` at the generic `https://apps.apple.com` storefront. Configuring a verified product-page destination remains a separate task; TestFlight distribution does not establish public storefront availability.

The `native:mas:*` scripts are Mac-only. There is no iOS packaging, validation, or upload script yet; see `docs/RELEASE_CHECKLIST.md` and `docs/ICLOUD.md` for the iOS gates.

## Local release sequence

1. Run `npm run native:mas:screenshots` and inspect all five fictional-data JPEGs.
2. Run the full repository and native verification listed in `docs/RELEASE_CHECKLIST.md`.
3. Install the Apple Distribution (or Mac App Distribution) and Mac Installer Distribution identities. Download a matching **Mac App Store Connect** distribution provisioning profile for `com.addressatlas.mac` and provide it through `ADDRESS_ATLAS_PROVISIONING_PROFILE`. The profile is mandatory because the App ID entitlement authorizes Data Protection Keychain.
4. From a clean `main` checkout whose `HEAD` matches `origin/main`, run `npm run native:mas:package` with the signing identity names and numeric Apple ID in the documented environment variables. The builder writes the source commit into the signed app and a read-only provenance record binding that commit to the package SHA-256, version, bundle, team, and App Store record.
5. Run `npm run native:mas:validate` with one of the supported least-privilege App Store Connect authentication methods below.
6. After metadata, privacy, contracts, data-source licensing, review contact, and clean-Mac smoke gates are complete, run `npm run native:mas:upload`.
7. Re-read App Store Connect processing and submission state. Upload/processing is not App Review approval or storefront availability.

Never push a `v*` tag as a Mac App Store action. The existing tag workflow publishes the separate Developer ID/notarized DMG channel.

Xcode's upload command supports two authentication modes. For a team API key, set `ADDRESS_ATLAS_ASC_API_KEY`, the issuer UUID in `ADDRESS_ATLAS_ASC_API_ISSUER`, and an explicit owner-private absolute `ADDRESS_ATLAS_ASC_P8_PATH`; implicit key discovery is disabled. For an individual account, create an app-specific password, store it in Keychain with Xcode's `altool --store-password-in-keychain-item` operation, and set `ADDRESS_ATLAS_ASC_USERNAME` plus the item name in `ADDRESS_ATLAS_ASC_PASSWORD_KEYCHAIN_ITEM`. Never put the password itself in an environment variable, command file, or the repository. The obsolete issuer-less `ADDRESS_ATLAS_ASC_API_KEY_SUBJECT=user` route is rejected because Xcode 26.6 does not accept it for validation or upload. Before both validation and upload, the script re-checks the clean current `main` commit against live `origin/main` and proves that commit matches the signed app inside the exact package and its read-only provenance digest.

## External gates that must be true before App Review submission

- Apple Developer Program agreements are active and the App Store Connect user has permission to create/submit the record. Have the exact `TERMS.md` text legally reviewed, then enter it as the custom EULA for the selected territories so the published agreement matches the in-app link.
- The explicit App ID and product record use `com.addressatlas.mac` exactly.
- Xcode's App Store delivery components pass `xcrun altool --help`; a broken or incomplete Xcode installation is a release blocker.
- A real reviewer phone number is saved in App Store Connect.
- EU DSA trader/non-trader status, storefront availability, tax category, and age-rating questionnaire are complete.
- CoinGecko usage is covered by a plan/license suitable for a public-facing product, with the in-app attribution retained. Public endpoint accessibility alone is not license evidence.
- Every other price, RPC, REST, exchange, explorer, and brand integration remains within its current terms; any requested authorization evidence is available.
- Enable the CloudKit container and deploy its Production schema as described in `docs/ICLOUD.md`. Verify manual encrypted transfers and iCloud Keychain delivery between two signed Macs. The app no longer uses the legacy hosted sync service.
- A clean macOS account proves first launch, sandbox network access, recovery export/restore, container migration, Data Protection Keychain migration, and confirmed deletion of the private iCloud copy. Verify account switching and stale-save conflict handling.
