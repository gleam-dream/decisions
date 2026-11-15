# Security policy

## Supported versions

This repository holds three packages: `decisions`, `decisions_otp` and
`decisions_postgres`. Security fixes are released for the latest minor version
of each package published on [Hex](https://hex.pm/packages/decisions). Older
versions do not receive patches; upgrade to the latest release to get a fix.
Until a package has its first Hex release, fixes land on the `main` branch.

| Version                     | Supported |
| --------------------------- | --------- |
| Latest minor release on Hex | Yes       |
| Older releases              | No        |

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Email
talktoedgar@gmail.com with a description of the issue, the affected package,
the affected version or commit, and steps to reproduce it.

You can expect an acknowledgement within 7 days. Once the issue is confirmed, a
fix is prepared privately and released, and the report is credited in the
release notes unless you prefer otherwise.
