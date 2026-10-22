# Security reporting

## Report a vulnerability

Use [GitHub's private vulnerability reporting form](https://github.com/tcholewa/myEq/security/advisories/new) to contact the maintainer privately. You can also find it under **Security → Advisories → Report a vulnerability**. Do not include exploit details, credentials, or private logs in a public issue.

If that option is unavailable, open an issue asking for a private reporting channel without disclosing the vulnerability. Private vulnerability reporting is enabled for `tcholewa/myEq`; forks must enable it separately in their own repository settings.

Include the affected version/commit, macOS version, required access, reproduction steps, expected/actual behavior, and impact. For audio/helper issues, identify the relevant driver, app, bridge, or recovery component. Share only the minimum information needed to reproduce the problem.

## Supported code

Security fixes are developed against the current default branch and latest release. Older builds do not have a separate backport commitment. This is an early project without a guaranteed response time.

## Relevant boundaries

The installer uses administrator authorization to install system components. At runtime, the bridge runs as an unprivileged service; the app/recovery helper run in the logged-in user's session. The design authenticates XPC peers and restricts session ownership. Shared memory carries audio locally. See [architecture](docs/ARCHITECTURE.md) for details and [verification](docs/VERIFICATION.md) for test coverage and known limits.

Test on a development Mac. Installation, removal, and driver reloads can interrupt audio system-wide.
