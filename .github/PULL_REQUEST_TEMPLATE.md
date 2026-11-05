## Summary

<!-- What changed? Keep this focused on the user or system outcome. -->

## Why

<!-- What problem does this solve? Link the issue when one exists. -->

## Verification

<!-- List the exact checks run and their results. Explain any check not run. -->

- [ ] Tests added or updated where behavior changed
- [ ] Relevant local checks pass
- [ ] `git diff --check` passes
- [ ] Shared Swift files still build for macOS and iOS (`npm run native:ios:build:unsigned`) when they changed
- [ ] `python3 scripts/check-secret-artifacts.py` passes

## Trust-boundary review

- [ ] The change preserves read-only, zero-custody behavior
- [ ] No seed phrase, private key, signing, trading, transfer, or withdrawal permission is introduced
- [ ] Plaintext portfolio data and exchange credentials stay on the device; iCloud copies and any service see only encrypted data
- [ ] New provider requests are bounded, validated, and fail visibly
- [ ] Persistence, migration, export, recovery, and iCloud copy compatibility were considered where relevant
- [ ] Screenshots and fixtures use synthetic data only
- [ ] No credential, token, recovery material, `.env` content, private key, or production data is included

## User-facing evidence

<!-- Add synthetic-data screenshots for UI changes or concise before/after evidence for behavior changes. -->

## Release and operations impact

<!-- Note configuration, deployment, backup, migration, notarization, or rollback changes. Write "None" when unaffected. -->
