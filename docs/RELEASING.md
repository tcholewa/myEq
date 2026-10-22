# GitHub setup and releases

## Repository setup

The public repository is [tcholewa/myEq](https://github.com/tcholewa/myEq), with `master` as its default branch. The local `origin` remote points to `https://github.com/tcholewa/myEq.git`. Publication preserves the existing commit history, including author names and emails.

For a separate fork or mirror, create an empty GitHub repository without an auto-generated README, license, or `.gitignore`, then add its URL as a remote and push the intended branch. The build scripts do not create repositories or push source.

Suggested repository description: **Native macOS menu bar equalizer with eight parametric bands and a shared-memory virtual output driver.**

Suggested topics: `macos`, `audio`, `equalizer`, `swift`, `swiftui`, `coreaudio`, `menu-bar`.

When setting up a fork or reviewing the upstream configuration:

1. Enable Issues and [private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository). The issue forms and security policy are already included.
2. Let the **CI / Build and test** workflow finish on the first push. It requires GitHub's hosted `xcode-27` Apple Silicon image. Check the [workflow runs](https://github.com/tcholewa/myEq/actions/workflows/ci.yml) for the upstream status.
3. Use branch protection/rulesets appropriate to the maintainer workflow, with the build/test check required once it has run successfully. Keep Actions permissions read-only by default and require review of workflow changes from outside contributors.
4. Enable available secret scanning and push protection. A local pattern scan is not a substitute for these checks.

The workflow uses a commit-pinned checkout action, read-only repository permissions, and no repository secrets or self-hosted runners. Pull requests run on disposable hosted machines. It builds and checks packages without installing or uploading them.

## Prepare a version

Keep these version fields consistent:

- `Resources/Info.plist`: `CFBundleShortVersionString` and an incremented `CFBundleVersion`.
- `scripts/build-installer.sh`: the `pkgbuild --version` value.
- `Installer/Distribution.xml`: the component package version.

Update user-facing documentation and [verification](VERIFICATION.md) with the actual automated and hardware checks performed. Preserve the [MIT license](../LICENSE) and [DSP notices](../THIRD_PARTY_NOTICES.md).

Follow [CONTRIBUTING.md](../CONTRIBUTING.md#checks), then build and verify the package:

```sh
bash scripts/build-installer.sh
python3 scripts/verify-installer.py
shasum -a 256 dist/myEq.pkg
```

Package verification checks signatures, XPC identities, the recovery launch constraint, versions, icon, license notices, and installation scripts. Commit verified source changes before tagging the corresponding commit. Never commit `build/`, `.build/`, `dist/`, signing credentials, or raw diagnostic evidence.

## Distribution status

Default builds remain ad-hoc signed and unnotarized. Production signing and notarization tooling is implemented, but has not been exercised with Developer ID credentials. Neither the current local package nor a passing source CI run establishes Gatekeeper acceptance or clean-Mac compatibility.

## Signed candidates

Obtain Developer ID Application and Developer ID Installer certificates through the Apple Developer Program. Import their private keys into a protected keychain and store notarization credentials using `xcrun notarytool store-credentials`. Never put credentials or exported keys in the repository.

With the signing keychain available, set these variables to your own identities/profile:

```sh
export MYEQ_APPLICATION_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export MYEQ_INSTALLER_IDENTITY='Developer ID Installer: YOUR NAME (TEAMID)'
export MYEQ_TEAM_ID='TEAMID'
export MYEQ_NOTARY_PROFILE='your-keychain-profile'
# Optional: MYEQ_KEYCHAIN points to the keychain containing that profile.
bash scripts/release.sh
```

The script signs helpers, maintenance utility, driver and app with hardened runtime and secure timestamps; derives component hashes after signing; signs the installer; and verifies Team ID, identifiers, hashes, launch constraints and entitlements. It then submits to Apple's notary service, requires `Accepted`, staples and validates the ticket, runs Gatekeeper assessment, and writes `dist/myEq.pkg.sha256`. Any failed step stops the script. It produces a candidate, not a published release. A local candidate is needed to perform the checks below.

## Clean-Mac release gate

Before publishing a binary, validate the exact source revision on a clean development Mac or VM and on supported audio hardware. Include installation, upgrade, rollback/removal, fast user switching, individual process crashes, sleep/wake, output/rate transitions, hidden/visible CPU and a quarantined download. Record observations, routes, timings, hardware and package SHA-256 as evidence. See [the hardware checklist](VERIFICATION.md#remaining-hardware-acceptance-checks).

Only after those checks pass, create `docs/release-validation.json` with the following fields (this example deliberately cannot pass):

```json
{
  "sourceCommit": "FULL_40_CHARACTER_TESTED_COMMIT",
  "testedBy": "maintainer",
  "testedAt": "ISO-8601 timestamp",
  "macOS": "version and build",
  "hardware": "Mac and tested output devices",
  "evidence": "path or URL to observations and candidate SHA-256",
  "checks": {
    "cleanInstall": false, "upgrade": false, "rollback": false,
    "uninstall": false, "fastUserSwitch": false, "crashRecovery": false,
    "sleepWake": false, "audioMatrix": false, "cpuHidden": false,
    "cpuVisible": false, "quarantinedDownload": false
  }
}
```

Commit the real record and run `python3 scripts/check-release-readiness.py` from a clean checkout. It requires every check to pass and rejects implementation changes since the tested ancestor commit. This is a maintainer attestation, not automated hardware testing or a cryptographic attestation of a rebuilt artifact. Verify the final candidate's checksum and downloaded package before publishing. No validation record is supplied until actual tests are completed.

## GitHub signing environment

The manual **Signed release candidate** workflow runs only on `master`, uses the `release-signing` environment and checks the validation record before accessing credentials. Configure required environment reviewers and a protected branch policy in GitHub. Add environment secrets `SIGNING_P12_BASE64` (both certificates and private keys), `SIGNING_P12_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`, `DEVELOPER_ID_APPLICATION`, and `DEVELOPER_ID_INSTALLER`. The workflow uses a temporary keychain, removes it on exit, and uploads only a verified package and checksum as a short-lived candidate artifact. Its [artifact action](https://github.com/actions/upload-artifact/tree/cf430e030ddbb5b0abf93d22962f4752f3646cd9) is pinned to a full commit.

Normal pull-request CI has no signing secrets. Do not run unreviewed changes in the signing environment. Environment settings and credentials are maintainer setup tasks; checking in the workflow does not configure them. Tagging, pushing, or publishing a GitHub Release remains a separate maintainer action.
