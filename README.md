# GlassEQ

A native macOS equalizer that processes your **entire system audio** in real time without installing a virtual audio device, a loopback driver, or a system extension.

[![macOS 26](https://img.shields.io/badge/macOS-26-black)](#supported-target)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)](#supported-target)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/juhokoskela)

**[Download the latest GlassEQ alpha](https://github.com/juhokoskela/GlassEQ/releases/latest)** for macOS 26 and Apple Silicon. See the installation notes below.

## What makes GlassEQ different

Most system-wide equalizers on macOS work by installing a **virtual output device** that you have to select and manage yourself, e.g. eqMac, or loopback drivers in the Soundflower / BlackHole family. Your real output gets hidden behind a fake one, and routing breaks every time you switch headphones or unplug.

GlassEQ takes a different route. It uses **Core Audio process taps**, Apple's modern system-audio-capture API to read the system mix directly, apply EQ to it, and replay the processed audio to the output you're already using.

- **No virtual device, no driver, no system extension.** GlassEQ's tap and its aggregate device are both private, so nothing new ever shows up in your Sound settings. It's an ordinary sandboxed app that asks for one thing: audio-capture permission.
- **macOS stays in charge of routing.** GlassEQ observes the default output and follows it. You never pick an output inside the app.
- **Per-output profiles.** Each device gets its own EQ curve, matched automatically by its Core Audio UID. Plug in your studio monitors and the monitor profile loads, switch to AirPods and their profile takes over.
- **Light and real-time-safe.** The DSP is a hand-written biquad cascade (no FFT, no convolution), so the resident footprint stays around **25–30 MB**. The audio render path never allocates, locks, or touches disk, and profile edits hot-swap without dropping a sample.
- **Native to macOS 26.** A menu bar app built on the system's Liquid Glass styling with a separate settings window for editing.

![GlassEQ menu bar popover, showing the active output and its mapped profile](Docs/Screenshots/menu-bar.png)

*GlassEQ lives in the menu bar and follows whatever output macOS is using.*

## Download & install

Grab `GlassEQ-alpha-0.9-macos26-arm64.zip` from the [alpha-0.9 release](https://github.com/juhokoskela/GlassEQ/releases/tag/alpha-0.9), then:

1. Unzip it.
2. Move `GlassEQ.app` to `/Applications`.
3. Open it from Finder.

The alpha is ad hoc-signed and not yet notarized ([you can help change that](#support-the-project)), so macOS asks you to confirm the first launch: open **System Settings → Privacy & Security**, find the GlassEQ notice, and click **Open Anyway**. It opens normally after that.

On first run GlassEQ asks for **system audio capture permission** — that's what lets it read and equalize the system mix. Grant it and you're set.

### About this alpha

GlassEQ is an early alpha: Apple Silicon only, tested on macOS 26, with no automatic updates or crash reporting yet. Expect the occasional rough edge, and please report any hardware-specific audio issues you run into. See [Docs/AlphaTesting.md](Docs/AlphaTesting.md), [Docs/Distribution.md](Docs/Distribution.md), and [Docs/ReleaseNotes-alpha-0.9.md](Docs/ReleaseNotes-alpha-0.9.md) before installing a build.

## How it works

1. GlassEQ opens a **private, muted process tap** for the current physical output stream. The tap excludes GlassEQ itself, pulling the dry system mix out of that route without creating a feedback loop.
2. On normal-rate routes, GlassEQ places that tap and the physical output in one private aggregate device. One Core Audio callback applies EQ and writes directly to the output on the same clock.
3. Low-rate Bluetooth headset modes begin on a separate-clock compatibility path with a bounded ring buffer, drift servo, and realtime sample-rate conversion. Once the route's clock settles, GlassEQ tests the normal low-latency aggregate and returns to compatibility mode if its timing becomes unstable.
4. GlassEQ switches backend automatically when the output device, stream, or headset sample rate changes.

The normal fast path has low, predictable latency without a separate playback queue. The built-in diagnostics report tap-to-output latency from Core Audio's I/O timestamps alongside frame delivery, callback sizes, underruns, dropped input, and saturation. Headset mode reports its bridge occupancy, clock correction, sample-rate conversion, and output timing separately.

The current low-latency path requires the output's preferred pair to occupy one native mono or stereo hardware stream. Audio routed to a different device or a distinct system-alert output is outside that tap.

![GlassEQ settings — Output tab, showing current output, profile mapping, engine status, and live diagnostics](Docs/Screenshots/output.png)

## Features

- **Three EQ modes:** parametric, 10-band graphic, and 31-band graphic.
- **Linked or independent stereo** channels, with a per-profile preamp and a headroom indicator.
- **Live frequency-response graph** and instant preview while you edit.
- **Profile import** from AutoEQ / EqualizerAPO and REW text, allowing you to paste a headphone-correction curve straight in.
- **Per-output profile mapping** by Core Audio device UID, with a fallback profile for unmapped devices.
- **Soft-clip saturation** that tames overshoot instead of hard-clipping.
- **Built-in diagnostics** for frame delivery, underruns, dropped input, callback sizes, saturation, latency, clock correction, and fallback buffering.

![GlassEQ settings — Editor tab, with the frequency-response graph and parametric filters](Docs/Screenshots/editor.png)

### Memory footprint

During normal listening GlassEQ is just a menu bar app and the audio engine, consuming around 25-30 MB of memory. The EQ editor runs as a **separate helper process** that's launched only while the settings window is open and terminated when you close it, so the SwiftUI interface never weighs on the always-on audio path.

### Security & privacy

- Sandboxed: requests only the audio-capture permission it needs to function.
- The settings helper must be inside the app bundle and pass code-signature integrity plus signing-identifier checks before launch and again after launch. Developer ID builds also require the same signing team; ad hoc alpha builds rely on bundle containment, identifier checks, and the private token-authenticated pipe. There is no networking or shared profile storage.
- No telemetry, no analytics, no cloud sync. Diagnostics run locally and print device details only to your terminal.

## Known limitations

- **AirPlay outputs are not yet supported.** The DSP engine currently fails to start on AirPlay receivers and GlassEQ stops processing that route; macOS keeps routing normal system audio to the AirPlay device. Switching to any other output (built-in, USB, Bluetooth, HDMI) restores processing cleanly.
- **Stereo processing.** GlassEQ processes a stereo stream. On multi-channel interfaces it plays to the device's preferred stereo pair (configurable in Audio MIDI Setup → Configure Speakers) and writes silence to the remaining channels — the same routing macOS uses for system audio. There is no surround/per-channel EQ, and preferred-pair changes apply on the next output switch.
- **Bluetooth** headset modes initially use a higher-latency separate-clock compatibility path to avoid periodic combined-aggregate timestamp faults while the route settles. Promotion to the low-latency path is experimental; please report the device model, macOS version, and steps if a route still produces jitter.
- No automatic updates, no crash reporting, no x86_64 build.

<a id="supported-target"></a>
**Supported target:** macOS 26.0 or newer, Apple Silicon / arm64 only.

## Support the project

GlassEQ is free and MIT-licensed. The biggest thing standing between the current alpha and a build that opens without the Gatekeeper workaround is an Apple Developer Program membership ($99/year), which is required to ship a **Developer ID-signed, notarized** app.

If you'd like to help get there, the **Sponsor** button at the top of this repository goes directly toward that cost. Every bit helps move GlassEQ from "ad hoc-signed alpha" to "double-click to open."

## Build from source

### Pinned toolchain

- Xcode: 26.5, build 17F42.
- SDK: macOS 26.5.
- Swift: Xcode-bundled Swift 6.3 / local Swift 6.3.1 command-line toolchain.
- SwiftPM: `// swift-tools-version: 6.3`.
- Deployment target: macOS 26.0.

### Setup

After installing Xcode, accept the license:

```sh
sudo xcodebuild -license
```

Then verify, test, and run:

```sh
xcodebuild -version
swift --version
swift test
swift run GlassEQ
swift run GlassEQDiagnostics 2
```

`GlassEQDiagnostics` runs a short smoke test against the current default output and prints local device details plus capture/playback metrics.

### Creating an alpha build

```sh
./Scripts/build-release-app.sh
```

The script builds a release app bundle, embeds the app icon, ad hoc-signs the bundle, and writes a zip under `.build/dist/`.

Gatekeeper assessment is *expected to fail* because the alpha is not Developer ID signed or notarized:

```sh
codesign -d --entitlements :- .build/release-app/GlassEQ.app
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
```

The entitlements output should include `com.apple.security.app-sandbox` and `com.apple.security.device.audio-input`, both set to `true`.

## Architecture

macOS owns output switching, GlassEQ follows it. Normal-rate routes use a muted device-scoped tap and physical output in one aggregate callback and clock. Bluetooth routes at 24 kHz or below start on a separate capture/playback clock bridge, then attempt the combined path after the device clock settles; a timing failure returns them to the bridge for that output transition. GlassEQ disables unused physical input streams and never records the microphone. The render path stays free of allocation, locks, disk, logging, and SwiftUI state. The Core Audio bridge is isolated under `GlassEQAudio` so device-format and hardware work can be hardened without disturbing the UI and profile code.

See [Docs/Architecture.md](Docs/Architecture.md) for the full ownership model and runtime flow.

## What GlassEQ doesn't do

GlassEQ intentionally does not implement per-app routing, a virtual output selector, plugin hosting, microphone recording, telemetry, or cloud sync.

## License

GlassEQ is released under the MIT License.

Copyright (c) 2026 Juho Koskela.
