# GlassEQ Architecture

## Audio Ownership Model

macOS owns output switching. GlassEQ observes the default output device and follows it. The app never asks the user to choose a physical output inside GlassEQ.

The normal-rate runtime flow is:

1. Discover current default output device and UID.
2. Load the mapped profile for that output UID.
3. Build a private Core Audio tap for the selected physical output stream. The tap excludes GlassEQ itself and mutes the tapped dry output.
4. Build one private aggregate device containing the tap and physical output.
5. Use the physical output as the aggregate clock source and enable Core Audio drift compensation for the tap.
6. Disable every aggregate input stream except the tap stream for GlassEQ's I/O callback.
7. Process tap buffers and write the result to the physical output in one aggregate-device callback.
8. Rebuild the tap and aggregate when macOS changes the selected output device or stream.

On an explicit stop or profile bypass, GlassEQ changes the tap to mute its source only while the tap is being read, then stops the IOProc and destroys the graph. Direct system playback can resume when the read ends instead of waiting for each active client to recover after an always-muted tap disappears. Route handoffs keep the tap continuously muted until the replacement path is active.

Bluetooth routes at 24 kHz or below initially use a separate-clock compatibility backend. The tap runs in a tap-only aggregate, the physical output has its own HAL callback, and a bounded ring buffer, occupancy servo, and realtime sample-rate converter bridge the two clocks. After the route settles and its physical clock advances at the advertised rate, GlassEQ attempts to replace the bridge with the normal combined aggregate. A failed promotion or later paired timestamp discontinuity returns the route to compatibility mode for the remainder of that output transition.

## Real-Time Rules

The audio render path must not allocate, lock, touch disk, log, parse text, mutate SwiftUI state, or use Combine. UI and import work build a complete candidate processor bank outside the callback. The callback warms that bank for 20 ms, then blends from the active bank with a sample-accurate 10 ms smoothstep ramp. This permits filter-count, mode, and channel-mode changes without rebuilding the Core Audio graph. Only the newest queued edit is retained, and retired banks are released outside the callback.

A watchdog observes render progress outside the callback. One three-second steady-state stall stops the engine before rebuilding it once. Another stall within 60 seconds leaves GlassEQ stopped, restoring direct system audio until the user explicitly retries.

## Current Implementation Status

This repository contains the SwiftPM project, DSP engine, importers, profile persistence, menu bar shell, the combined Core Audio tap/output fast path, and the transitional separate-clock Bluetooth headset backend. The Core Audio bridge is intentionally isolated under `GlassEQAudio` so device-format support and hardware QA can be hardened without disturbing UI/profile code.

## Clocking And Routing

On normal-rate routes, the selected physical output is the aggregate's main subdevice and therefore owns the render clock. The process tap captures the device stream containing the output's preferred stereo pair and is an aggregate subtap with high-quality Core Audio drift compensation enabled. The engine has one `AudioDeviceIOProcID`: each callback receives the tapped system mix, runs the biquad cascade, and writes directly to the physical output buffers. There is no application-level queue or asynchronous sample-rate converter on this path.

GlassEQ measures tap-to-output latency as the host-time difference between the first tapped input frame acquired for an I/O cycle and the first rendered output frame scheduled for hardware. Diagnostics report the observed average and range. This does not include latency before the system tap or after the output reaches the hardware.

On duplex interfaces, Core Audio exposes the physical input channels before the process-tap channels in the aggregate input layout. GlassEQ requires the tap to occupy complete input streams, disables every physical input stream for its I/O callback, and verifies the applied stream-usage mask before starting. The callback still understands the aggregate channel offsets because disabled streams remain present as null buffers. GlassEQ fails startup if Core Audio cannot isolate the tap this way.

The device-scoped tap deliberately follows one output stream rather than all system routes. Audio explicitly routed to another device, including a distinct system-alert output, is outside GlassEQ's processing path. The low-latency path currently requires the preferred pair to occupy one native mono or stereo hardware stream. A pair that spans streams cannot be captured by one device tap, while asking Core Audio to mix down a multichannel stream reintroduces the deep input latency this design avoids. Output switching also requires recreating the muted tap after macOS reports the new route; switch handoff behavior remains a hardware soak-test requirement.

AirPods headset transitions exposed periodic, matching input and output timestamp discontinuities in the combined aggregate at 24 kHz. A timestamp probe showed that HAL could advertise 24 kHz while advancing `mSampleTime` on the old 48 kHz scale, then reset the timeline after several seconds. A combined aggregate created after the headset route had settled ran cleanly, but larger aggregate buffers, drift-compensation changes, and tap mixdown did not make the transition safe. For Bluetooth routes at 24 kHz or below, GlassEQ first uses a tap-only aggregate and drives the physical output separately. A preallocated ring buffer carries processed samples between callbacks, an occupancy servo corrects clock drift, and the realtime converter handles the tap and device sample-rate difference. After six seconds, GlassEQ measures the physical device's sample-time slope for 500 ms. If it agrees with the nominal rate, GlassEQ tries the combined path and rejects it if a paired timestamp discontinuity appears during a 750 ms validation window. One later qualifying paired jump also returns the route to the bridge, with no second promotion attempt until the output changes. Returning to a normal-rate route disposes either headset backend and restores the combined fast path.

See [Aggregate clock experiment: findings](AggregateClockExperiment.md) for the measurements and experiments behind this design.

GlassEQ requests a 16-frame callback only from the private combined aggregate and leaves the physical output's shared buffer-frame property unchanged. While the separate-clock headset backend is active, Core Audio owns the physical output's low-rate callback size while tap capture uses its own aggregate quantum. EQ coefficients use the active processing rate; filters above the output route's usable-frequency ceiling receive identity coefficients so runtime behavior matches the editor warning.

## Diagnostics

Run a short smoke test against the current macOS default output:

```sh
swift run GlassEQDiagnostics 2
```

The command prints output device metadata and post-run callback metrics:

- Captured frames from the private Core Audio tap.
- Played frames written to the default output device.
- Playback underrun frames.
- Input frames dropped because a callback exposed more input than output capacity.
- Peak capture and output callback sizes.
- Average and range of tap-to-output latency from Core Audio's I/O timestamps.
- Samples that reached the soft clipper.

The separate-clock fallback reports its additional bridge diagnostics instead: buffered frames, occupancy-derived bridge latency, clock correction, output timing gaps, sample-rate conversion, and reservoir target. Its bridge-latency number is not the same measurement as the combined path's timestamp-derived tap-to-output latency.

The diagnostic follows the current macOS output device and does not switch outputs itself.

Diagnostics print full local device names, UIDs, and transport identifiers:

```sh
swift run GlassEQDiagnostics 2
```

`--intentional-crash-after-start` is reserved for crash-reporting and cleanup validation. It starts the engine, prints that the crash-test path was requested, flushes stdout, and aborts deliberately.

## Profile Storage And Settings Helper

Profile data belongs to the main app sandbox and is migrated by the main app through `container-migration.plist`. The settings helper does not share profile storage and does not need an app-group entitlement; it receives snapshots and sends commands over the private stdin/stdout IPC session launched by GlassEQ.

## Backlog

- Support preferred stereo pairs inside native output streams wider than two channels without enabling Core Audio tap mixdown. The first version should still process only the preferred pair, preserve the device-scoped native stream format, map the tapped channels and aggregate buffers explicitly, keep physical inputs disabled, and verify that the wider stream does not restore the 43.5 ms mixdown latency.
