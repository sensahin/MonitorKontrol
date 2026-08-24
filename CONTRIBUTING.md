# Contributing to MonitorKontrol

Thanks for helping improve MonitorKontrol. Bug reports, monitor compatibility
results, documentation fixes, and focused pull requests are welcome.

## Before changing code

- Search existing issues before opening a new one.
- Open an issue before a large behavior or architecture change so the safety
  and compatibility tradeoffs can be discussed first.
- Never include credentials, signing certificates, serial numbers, or private
  diagnostic data in an issue or pull request.

## Build and test

MonitorKontrol requires macOS 14 or newer and Xcode 26 or newer.
Before using the command line, ensure `xcode-select -p` points to the
`Contents/Developer` directory of the Xcode installation you want to use.

```sh
xcodebuild -project MonitorKontrol.xcodeproj \
  -scheme MonitorKontrol \
  -destination 'platform=macOS' \
  test
```

The repository deliberately contains no developer-team identifier. Use
**Sign to Run Locally** or select your own team for launch and UI tests. For an
unsigned compile-only check, add `CODE_SIGNING_ALLOWED=NO` and replace `test`
with `build`.

Ordinary tests must not write to real display hardware. Hardware mutation is
opt-in and identity-gated; see [docs/HARDWARE_QA.md](docs/HARDWARE_QA.md).

## Safety rules

- Discovery must remain read-only. Do not write a display value on launch,
  wake, reconnect, or capability probing.
- Keep DDC traffic serialized and cancellable.
- Resolve private Apple display APIs at runtime and fail safely when they are
  unavailable.
- Keep input switching disabled until a monitor-specific mapping and recovery
  path are proven.
- Restore every captured baseline in hardware tests, including failure paths.

## Pull requests

Keep changes focused, remove superseded code, and include tests proportional to
the risk. Explain the user-visible behavior, affected hardware, validation
performed, and any remaining limitation.
