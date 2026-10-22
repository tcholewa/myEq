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

The current tooling produces ad-hoc-signed local builds. It does not implement Developer ID signing or notarization. Public source availability does not make these packages notarized distribution builds; do not label a package as notarized or promise Gatekeeper acceptance without implementing and verifying that release path.

For an initial source release, publish release notes with the macOS/architecture requirements, build instructions, known limitations, and the installer's Core Audio interruption. A general-audience binary release needs a separate signing/notarization change covering the app, driver, helpers, installer, and the trust hashes connecting them. Credentials belong in the release environment, never the repository.

Tagging, pushing, uploading a package, or publishing a release is a separate maintainer action. The checked-in CI workflow does none of those automatically.
