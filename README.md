# MonitorKontrol

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/sensahin/MonitorKontrol/actions/workflows/ci.yml/badge.svg)](https://github.com/sensahin/MonitorKontrol/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-supported-brightgreen)

MonitorKontrol is a native macOS menu-bar utility for controlling a MacBook
display and external monitors from one place.

The first release is deliberately focused on reliable daily control:

- Native MacBook backlight brightness.
- Hardware DDC/CI brightness, contrast, and volume when each capability answers a read-only probe.
- Clearly labeled click-through software dimming when hardware DDC is unavailable.
- One slider for all displays plus independent per-display controls.
- Hot-plug and wake rediscovery without writing saved values on launch.
- Per-display persistence, quick levels, and saved multi-display scenes. Displays without a real serial number follow their connection route, so moving one to another port creates a new saved identity.
- Optional launch at login and menu-bar visibility only while an external display is connected.
- Diagnostics showing the actual backend and last error.

## Requirements

- macOS 14 or newer.
- Apple Silicon for the current hardware DDC/CI backend. Native MacBook
  brightness uses macOS DisplayServices when that service is available.
- DDC/CI enabled in the external monitor's settings for hardware control.

Adapters, docks, and individual monitor models vary. MonitorKontrol probes each
capability without changing it and shows the backend actually in use.

## Install

The source is the supported public distribution today. The local 1.0 build is
not Developer ID signed or notarized, so it is intentionally not published as
a misleading public binary. A notarized download can be added when a Developer
ID Application certificate is available.

Clone the repository, open `MonitorKontrol.xcodeproj` in Xcode 26 or newer,
select the `MonitorKontrol` scheme and **My Mac**, then Run.

The project does not contain a developer-team identifier. Xcode can use
**Sign to Run Locally**, or you can select your own team under **Signing &
Capabilities** if your Mac requires one.

## Safety model

MonitorKontrol does not change a display during capability detection. A value is written only after an explicit slider, scene, or settings action. Input switching is intentionally hidden until a monitor-specific mapping has been safely verified, because a wrong input command can remove the Mac's own display route.

Software dimming is never applied automatically at launch.

For a terminal build, first make sure `xcode-select -p` points to the
`Contents/Developer` directory of your installed Xcode. Select Xcode under
**Xcode › Settings › Locations › Command Line Tools** if it does not. The
commands then use that active installation without assuming Xcode is installed
at a particular path.

An unsigned build-only check is suitable for automation:

```sh
xcodebuild -project MonitorKontrol.xcodeproj \
  -scheme MonitorKontrol \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Privacy

MonitorKontrol has no account, analytics, telemetry, or network service. Display
preferences and scenes stay in the current user's macOS preferences. The app is
unsandboxed because its hardware backends require local private display APIs.

## Distribution boundary

Apple-silicon DDC and native built-in brightness require private local display services. The full app is therefore unsandboxed and intended for signed, notarized direct distribution, not the Mac App Store. Private display APIs can change after a macOS update, so MonitorKontrol resolves/probes capabilities at runtime and falls back without crashing.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for transport research and attribution.

## Testing

The ordinary test suite is read-only with respect to display hardware:

```sh
xcodebuild -project MonitorKontrol.xcodeproj \
  -scheme MonitorKontrol \
  -destination 'platform=macOS' \
  test
```

Launch and UI tests need a local signature. Use Xcode's **Sign to Run Locally**
or select your own development team; CI intentionally runs only the
hardware-free unit tests.

Real brightness mutation is separately gated by monitor identity and explicit
opt-in. See [docs/HARDWARE_QA.md](docs/HARDWARE_QA.md).

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Report
sensitive vulnerabilities through the process in [SECURITY.md](SECURITY.md).
Release history is recorded in [CHANGELOG.md](CHANGELOG.md).

## License

MonitorKontrol is available under the [MIT License](LICENSE). Adapted transport
work retains its upstream notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
