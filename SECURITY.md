# Security policy

## Supported versions

Security fixes target the [latest stable release](https://github.com/talha90a1/framelift/releases/latest).

## Reporting a vulnerability

[Report a vulnerability privately](https://github.com/talha90a1/framelift/security/advisories/new). Include the affected version, steps to reproduce, and impact. Remove pairing keys, PINs, account IDs and tokens from attachments.

## Scope

In scope:

- Handling of pairing data: the Remote Play registration key, the morning key and the PSN account ID, how they are stored on disk, and anything that could expose them.
- The PlayStation sign-in flow in the app, including how the authorization code and token are handled.
- Parsing of network data from the console or the local network: discovery replies, registration responses, and the Takion stream (video, audio, controller feedback, haptics), in chiaki-ng, in the patches in `scripts/patches/`, and in the Framelift core in `Sources/FrameliftCore/`.
- Log redaction: any way for keys, credentials or personal data to reach the debug logs or the Export Logs zip.
- Memory safety bugs in the C and C++ code that a device on the local network could trigger.

Out of scope:

- Bugs in chiaki-ng that also exist upstream without our patches. Report these to [chiaki-ng](https://github.com/streetpea/chiaki-ng) as well.
- Bugs in macOS, Apple frameworks, the PS5 firmware or PlayStation Network.
- Attacks that need an attacker who already controls your Mac or your user account.
- The lack of notarization or a Developer ID signature on builds you make yourself.

## What to expect

- We aim to acknowledge a report within 7 days.
- We will confirm whether the issue is valid, keep you informed while we work on a fix, and tell you when it is fixed.
- We will credit you in the fix's release notes unless you ask us not to.
- Please give us a reasonable time to fix the issue before you disclose it publicly. We aim to fix confirmed issues within 90 days.
