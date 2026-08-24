# Hardware QA gate

Complete this checklist before relying on MonitorKontrol as the only display-control utility in ordinary daily use.

## Mutation test

The automated external mutation is locked to the observed LG identity `1E6D:5B55`; it must not select an arbitrary connected monitor.

1. Record MacBook brightness and every readable LG value.
2. Change LG brightness by five hardware points.
3. Confirm the LG's physical OSD/readback changed, then restore the original value.
4. Change MacBook brightness by 5%, confirm macOS stays synchronized, then restore it.
5. Test LG volume at a safe audio level and restore it.
6. Keep input switching disabled until there is another active input and the monitor's physical buttons are within reach.

Every mutation must restore its captured baseline even when verification fails.

The brightness portion is automated but opt-in so an ordinary unit-test run can never change a real display:

First ensure `xcode-select -p` points to the `Contents/Developer` directory of
the Xcode installation you want to use. The hardware test launches the app test
host, so select **Sign to Run Locally** or your own development team in Xcode.

```sh
xcodebuild -project MonitorKontrol.xcodeproj \
  -scheme 'MonitorKontrol Hardware QA' \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MonitorKontrolTests/HardwareIntegrationTests \
  test
```

## Stability test

- 10 disconnect/reconnect cycles.
- 5 sleep/wake cycles.
- Lid open and closed.
- LG as main and secondary display.
- Resolution or refresh-rate change.
- MonitorKontrol restart with settings preserved and no automatic display write.
- Hardware DDC remains available throughout repeated adjustments.
- Software fallback works when explicitly enabled and is removed when MonitorKontrol quits.

The replacement gate is no stale sliders, unexpected brightness jumps, lost inputs, hangs, or settings loss across these cases and normal daily use.
