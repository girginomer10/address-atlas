# Address Atlas Mac App Store Submission

This directory is the source-controlled submission packet for Address Atlas 0.2.0. It does not prove that a build has been uploaded, accepted, or made available. App Store Connect is authoritative for those states.

## Product record

- Platform: macOS
- Bundle ID: `com.addressatlas.mac`
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
- The production sync service is either independently healthy and reviewable or the optional self-hosted scope is explained accurately in Review Notes. No unavailable service may be represented as working.
- A clean macOS account proves first launch, sandbox network access, recovery export/restore, container migration from a legacy install, Data Protection Keychain migration, and account deletion if sync is exercised.
