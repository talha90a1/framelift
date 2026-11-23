# Security policy

## Supported versions

Framelift has no stable releases yet. Only the latest commit on `main` gets security fixes.

| Version | Supported |
| --- | --- |
| Latest `main` | Yes |
| Older commits | No |

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue, discussion or pull request for them.

1. Open this repository's **Security** tab.
2. Click **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers can see the report.
3. Describe the problem, the affected commit, how to reproduce it, and the impact you expect.

Do not include real pairing keys, PINs, PSN account IDs or tokens in the report. If logs are needed, remove that data first.

## Scope

In scope:

- Handling of pairing data: the Remote Play registration key, the morning key and the PSN account ID, how they are stored in the Keychain, and anything that could expose them.
- The PlayStation sign-in flow in the app, including how the authorization code and token are handled.
- Parsing of network data from the console or the local network: discovery replies, registration responses, and the Takion stream (video, audio, controller feedback, haptics), in chiaki-ng, in the patches in `scripts/patches/`, and in the Veyra core in `Sources/VeyraCore/`.
- Log redaction: any way for keys, credentials or personal data to reach the debug logs or the Export Logs zip.
- Memory safety bugs in the C and C++ code that a device on the local network could trigger.

Out of scope:

- Bugs in chiaki-ng that also exist upstream without our patches. Please report those to [chiaki-ng](https://github.com/streetpea/chiaki-ng) as well. We still want to know about them.
- Bugs in macOS, Apple frameworks, the PS5 firmware or PlayStation Network.
- Attacks that need an attacker who already controls your Mac or your user account.
- The lack of notarization or a Developer ID signature on builds you make yourself.

## What to expect

- We aim to acknowledge a report within 7 days.
- We will confirm whether the issue is valid, keep you informed while we work on a fix, and tell you when it is fixed.
- We will credit you in the fix's release notes unless you ask us not to.
- Please give us a reasonable time to fix the issue before you disclose it publicly. We aim to fix confirmed issues within 90 days.

This is a volunteer project, so these times are goals, not guarantees.
