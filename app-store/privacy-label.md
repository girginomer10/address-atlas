# App Privacy answers — iCloud build

These answers replace the retired hosted-sync packet. Verify them against the
exact signed build and current Apple questionnaire before submission.

- Tracking: No. Advertising and analytics SDKs: none.
- Local vault contents remain encrypted on the Mac.
- Optional portfolio copies go to the user's CloudKit private database, encrypted
  before upload. A separate key travels through iCloud Keychain. Address Atlas
  operates no backup database, passkey accounts, session service, usage quota
  logger, or server diagnostics collector for this build.
- Do not carry over the old hosted-service User ID, Other Usage Data, or Other
  Diagnostic Data answers merely because legacy server source remains in the repo.
- Third-party RPC/exchange requests still carry public addresses, authenticated
  balance requests, and inherent network metadata. Conservatively disclose Other
  Financial Info and Other Data Types for App Functionality, linked, not tracking,
  where those providers retain data beyond serving the real-time request.
- Confirm Apple's treatment of the private CloudKit storage path in the final
  questionnaire. Do not infer “no data collected” for the entire app from using
  private iCloud: provider requests remain a separate boundary.

No app-created cloud account is required. **iCloud → Delete iCloud copy** removes
this app's private snapshot and preserves local vaults; Apple controls underlying
service retention. Old externally hosted data is not deleted by this update.
See [PRIVACY.md](../PRIVACY.md) and [iCloud setup](../docs/ICLOUD.md).
