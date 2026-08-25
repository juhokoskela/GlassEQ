# Alpha Testing

GlassEQ alpha builds are for technical testers on Apple Silicon Macs running macOS 26.

## Before Installing

- The alpha is ad hoc-signed, not Developer ID signed, and not notarized.
- Gatekeeper rejection is expected.
- The app captures system output audio with Core Audio taps so it can apply EQ before playback.
- The app follows the current macOS default output device. It does not expose its own output selector.
- If audio behaves strangely, quit GlassEQ first. If needed, switch the system output device or restart Core Audio.

## Install

Unzip the release artifact and move `GlassEQ.app` to `/Applications`.

If macOS blocks the downloaded app on first launch, go to System Settings > Privacy & Security and allow GlassEQ to open. If you are intentionally testing without Gatekeeper quarantine, remove the quarantine attribute instead:

```sh
xattr -dr com.apple.quarantine /Applications/GlassEQ.app
```

Open the app from Finder. GlassEQ is a menu bar app.

## First Run Permission

The first time GlassEQ starts the Core Audio tap, macOS should ask for system audio capture permission. Allow it.

If the prompt does not appear or audio capture is denied:

1. Open System Settings.
2. Go to Privacy & Security.
3. Find the system audio recording permission entry for GlassEQ.
4. Enable it, then quit and reopen GlassEQ.

## Smoke Test

Run through this checklist with the exact downloaded build:

- Open GlassEQ.
- Grant system audio capture permission.
- Play audio through the current default output.
- Toggle bypass and confirm audio still plays.
- Change a 10-band or 31-band EQ setting and confirm the sound changes.
- Import a small AutoEQ / EqualizerAPO profile if available.
- Import an EqualizerAPO `GraphicEQ:` profile and confirm it opens as a Response Curve with editable frequency/gain points.
- Preview and apply a Response Curve while music is playing. Confirm the old response remains uninterrupted during the roughly 341 ms history warm-up and the transition itself is click-free.
- Start programme-loudness A/B from a Response Curve. Confirm Filters Off retains the profile preamp, matching eventually becomes ready, and returning to EQ is clean.
- Switch the macOS default output device while audio is playing.
- Test sleep/wake if practical.
- Quit and reopen GlassEQ.
- Confirm profile settings persist.

## Hardware Already Covered

The current alpha has been manually tested with:

- Built-in speakers.
- Monitor speakers.
- Three USB audio interfaces.
- One USB DAC.
- Bluetooth / AirPods.
- Wired headphones.

## Diagnostics

From the project checkout, run:

```sh
swift run GlassEQDiagnostics 2
```

For installed-app testing, report the app status text and any visible callback metrics from the GlassEQ UI. If you can reproduce with the checkout diagnostic, include its full output in the bug report.

For a CPU-contention torture test, reset metrics immediately before each run and use the same route, sample rate, buffer size, programme material, and external workload. Run one biquad profile and one Response Curve for long enough to collect well over 10,000 callbacks. Compare Callback Start Late first. If that distribution stays the same but FIR Head, FIR Tail, Total Render, or Completion Late grows, the convolution path is less tolerant of the poisoned deadline. If Callback Start Late itself grows under FIR, the extra DSP or cache footprint is affecting system scheduling. Tail Completion Slack and its miss count distinguish slow execution from an internal tail-scheduling failure.

## Known Alpha Issues

- The app is not notarized, so Gatekeeper blocks it by default.
- Permission behavior may be rough on clean machines because the app is not Developer ID signed or notarized.
- macOS 26 and Apple Silicon are the only supported alpha target.
- Hardware/device-format coverage is incomplete even though common outputs have been tested.
- App icon and About-window polish are early.
- There is no automatic update mechanism.
- There is no crash reporter or telemetry.

## Uninstall

Quit GlassEQ, then remove the app and optional profile data:

```sh
rm -rf /Applications/GlassEQ.app
rm -rf ~/Library/Application\ Support/GlassEQ
rm -rf ~/Library/Containers/com.glasseq.app/Data/Library/Application\ Support/GlassEQ
```
