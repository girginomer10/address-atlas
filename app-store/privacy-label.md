# App Privacy answers

Use these as the conservative basis for App Store Connect, then re-check them against the exact production sync deployment and every dependency before submission.

## Tracking

- Data used to track users: **No**
- Third-party advertising: **No**

## Local-only data

Wallet addresses, balances, labels, exchange credentials, and scan history that remain only in the local encrypted vault are processed on device and are not collected by the developer. Network requests needed to scan a source are handled separately below.

## Final App Store Connect disclosures

Use the following conservative answers for every user, even though sync and exchange connections are optional:

- **User ID — linked — App Functionality — not tracking:** the opaque optional-sync account identifier and passkey public credential metadata.
- **Other Financial Info — linked — App Functionality — not tracking:** the optional encrypted portfolio snapshot and public wallet/portfolio identifiers sent to selected RPC or exchange services. Address Atlas sends provider requests to obtain balances in real time; this disclosure conservatively covers providers that may retain service or security logs beyond the immediate response.
- **Other User Content — linked — App Functionality — not tracking:** user-created labels and portfolio content inside the optional encrypted sync snapshot.
- **Other Data Types — linked — App Functionality — not tracking:** optional-sync version, size, session/security metadata and the masked network prefix retained in bounded service access logs, plus read-only exchange authentication or provider request metadata if a selected provider retains it beyond the immediate request.
- **Other Usage Data — linked — App Functionality — not tracking:** per-account daily sync write count and byte count used to enforce service limits.
- **Other Diagnostic Data — linked — App Functionality — not tracking:** bounded service access records such as request status and duration, retained for availability, security, and incident diagnosis. Headers, URI, exact IP addresses, and authentication material are removed before logging; the conservative linked answer avoids claiming that retained service activity is irreversibly unlinkable.

Do **not** select Contact Info, Location, Device ID, Purchases, Product Interaction, Advertising Data, Crash Data, Performance Data, Advertising, Analytics, Product Personalization, or Tracking for the reviewed 0.2.0 build. Under Usage Data select only **Other Usage Data**; under Diagnostics select only **Other Diagnostic Data**. Revisit the answers before submission if the production sync deployment, provider set, logging, SDKs, or diagnostics behavior changes.

## Optional sync detail

- **User ID**: opaque sync account identifier; linked to the sync account; not used for tracking.
- **Other User Content / Other Financial Info**: opaque encrypted vault snapshot; linked to the sync account; not used for tracking. Although the operator cannot decrypt it, it is transmitted and retained, so this packet does not claim it is purely on-device.
- **Other Data**: snapshot version/size, passkey public credential metadata, session/security metadata, masked network prefix, and provider metadata; linked conservatively for service operation; not used for tracking.
- **Other Usage Data**: per-account sync write count and byte count retained by date to enforce bounded service usage; linked; not used for tracking.
- **Other Diagnostic Data**: bounded server access status and duration records used for service operation and incident diagnosis; linked conservatively; not used for tracking. Separately, the app's user-facing privacy-safe diagnostics are copied locally and are not automatically transmitted.

## Sensitive material explicitly not collected by sync

- Seed phrases, wallet private keys, signing material, raw recovery codes, raw vault keys, and plaintext exchange credentials are not sent to the Address Atlas sync service.

## Retention and deletion

The in-app **Delete sync account** control removes linked live account data. Encrypted operational backups may retain records for up to 30 days. A permanent one-way deletion-operation digest contains no account identifier or portfolio content and exists only for safe idempotent retries.
