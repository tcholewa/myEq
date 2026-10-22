# Contributing to myEq

myEq focuses on a native menu bar experience and an eight-band parametric EQ for the system stereo mix. Changes should preserve low audio latency, modest CPU use, and reliable recovery to the physical output. Per-app mixing, recording, and network audio are outside the current scope.

## Report a bug or suggest a feature

Use the repository's issue forms. For bugs, include the app version or commit, macOS version, Mac architecture, physical output device/connection, sample rate when relevant, and exact reproduction steps. State whether ordinary playback works with EQ bypassed. Share a minimal log excerpt rather than an entire system log; remove personal paths, device identifiers, and unrelated activity.

Use [private security reporting](SECURITY.md) for vulnerabilities. Keep discussion respectful and focused on reproducible behavior. For a substantial feature or architecture change, describe the proposed behavior in an issue before investing in implementation.

## Development setup

Follow the [installation guide](docs/INSTALLATION.md) for Apple Silicon, macOS 27+, and Xcode 27+ prerequisites. There are no external package dependencies. Read the [architecture](docs/ARCHITECTURE.md) before changing audio, IPC, or recovery.

Open `myEq.xcodeproj` for app work. Run a development build with `--preview` to edit the UI without activating audio, registering helpers, or writing presets. For real playback, build and install the complete package; do not replace the installed app alone. A package build does not install or restart Core Audio.

When adding or removing files in `Sources/MyEqApp`, run `python3 scripts/generate-project.py` and commit the updated Xcode project/scheme along with the source.

## Checks

Run the checks relevant to the change from the repository root:

```sh
python3 scripts/check-repository.py
swift test
bash scripts/test-native.sh
bash scripts/test-native.sh asan
xcrun swift-format lint --strict -r Sources/MyEqCore Sources/MyEqApp Tests/MyEqCoreTests
bash scripts/build-installer.sh
python3 scripts/verify-installer.py
python3 scripts/test-installer-security.py
python3 scripts/analyze-native.py
```

Native tests exercise shared-memory concurrency, real Apple AUVarispeed rendering, driver properties, and mocked recovery/bridge behavior without installing a driver or changing the default output. Audio Unit and anonymous XPC tests need access to macOS services; restrictive process sandboxes can prevent them from running. The sanitizer mode enables both AddressSanitizer and UndefinedBehaviorSanitizer. Installer fixtures compile the maintenance code with a private test root and suppressed service operations; they never install a driver or run root maintenance. Run them after building the package.

For UI changes, also run `bash scripts/render-design.sh`. It renders synthetic editor/menu fixtures and checks visibility/focus behavior in never-shown windows. It currently depends on Xcode 27's SwiftPM product layout. Visually inspect the generated PNGs under `build/artifacts.noindex/design-preview`; these checks do not replace interaction testing in an installed window.

GitHub Actions runs the repository checks, Swift tests, native tests (including AddressSanitizer and UndefinedBehaviorSanitizer), formatting, and installer build/verification on the hosted `xcode-27` Apple Silicon image with Xcode 27.1. It does not install the package, publish binaries, or run hardware acceptance tests. The runner is a [GitHub preview image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md); image availability can affect CI independently of the source.

## Hardware checks

Only run installed-system checks on a development Mac when audio interruptions are acceptable. Follow the outstanding cases in [VERIFICATION.md](docs/VERIFICATION.md#remaining-hardware-acceptance-checks).

- `bash scripts/test-native.sh installed-ipc` checks bridge authentication without changing routing.
- With EQ already enabled, `bash scripts/test-native.sh installed-playback` runs fresh silent AudioQueue clients at 44.1/48/96 kHz. It does not enable EQ or change the default output and exits with status 78 when myEq is not active.

Record hardware, sample rate, visible/hidden state, and the commands used for performance claims. Separate DSP timing from app/driver/helper CPU, and measured latency from design targets.

## Pull requests

Keep changes focused. Explain the observed problem, resulting behavior, and checks performed. Update documentation for user-visible or architectural changes, and include screenshots for UI changes. Add meaningful tests for new behavior; documentation-only changes do not need an audio test run.

Audio callbacks must remain free of allocation, locks, logging, file/network IO, Swift calls, and IPC. Keep code-signing checks, user/session boundaries, and restoration of manually selected outputs intact when changing helpers or routing.

Contributions are provided under the project's [MIT License](LICENSE). Retain existing notices and add provenance/license notices for any new third-party material. Do not commit build products, credentials, signing keys, or private diagnostic logs.
