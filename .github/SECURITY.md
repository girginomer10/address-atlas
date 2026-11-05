# Security Policy

## Supported versions

Address Atlas is a preview. There is no signed and notarized public download and
no App Store release. TestFlight beta builds for Mac and for iPhone and iPad
exist (0.2.0, build 175). Security fixes land on `main`. Once public releases begin, only the latest
release on each platform and the currently deployed sync service will receive
fixes; older builds will not be supported after a replacement is published. The
root Next.js service and `server/sync` are legacy code that the apps no longer
use.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability, leaked credential, or
user-data exposure. Use GitHub's private vulnerability-reporting flow for this
repository:

<https://github.com/girginomer10/address-atlas/security/advisories/new>

That private-reporting setting must remain enabled. The release workflow checks
both the live repository setting and this exact repository-specific link and
blocks publication if either side of the reporting contract is unavailable.

Include the affected version or commit, a minimal reproduction, impact, and any
known mitigations. Do not include real wallet inventories, exchange credentials,
passkeys, bearer tokens, recovery material, private keys, or production logs.

The maintainer will acknowledge a complete report, coordinate validation and a
fix privately, and publish an advisory after affected users have a safe upgrade
path. Please avoid public disclosure until that coordination is complete.
