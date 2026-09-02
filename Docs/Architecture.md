# GlassEQ Architecture

## Audio Ownership Model

macOS owns output switching. GlassEQ observes the default output device and follows it. The app never asks the user to choose a physical output inside GlassEQ.

The normal-rate runtime flow is:

1. Discover current default output device and UID.
2. Load the mapped profile for that output UID.
3. Build a private Core Audio tap for the selected physical output stream. The tap excludes GlassEQ itself and mutes the tapped dry output only while an IOProc reads it.
4. Build one private aggregate device containing the tap and physical output.
5. Use the physical output as the aggregate clock source. A complete-composition aggregate requests high-quality drift compensation for the taps; the physical-first attachment path accepts the tap metadata published by `setSubtaps`.
6. Disable every aggregate input stream except the tap stream for GlassEQ's I/O callback.
7. Process tap buffers and write the result to the physical output in one aggregate-device callback.
8. Rebuild the tap and aggregate when macOS changes the selected output device, stream, or nominal sample rate. A same-device rate or stream-format notification first releases the old graph to direct playback, then waits 650 ms before creating replacement taps and an aggregate.

Every cold start uses a physical-first ordering: GlassEQ creates a physical-only aggregate at the incumbent buffer size, creates its IOProc, disables every input stream, and starts output. It then attaches the process taps to that running aggregate with Core Audio's public `setSubtaps` API, enables only the published tap input streams, and requests the preferred callback size from the private aggregate. This establishes GlassEQ's output IO context before HAL installs the tap muter without briefly activating a duplex interface's microphone. If the live attachment or startup qualification fails, GlassEQ tears it down and starts the separate-clock compatibility path without changing the shared output's sample rate or buffer size. Same-route rebuilds remain on that path while promotion is deferred. A changed route also remains on compatibility output when Core Audio's process objects report an external client rendering through it. Only the promotion loop tries the combined aggregate after those clients release the route.

All combined taps use `mutedWhenTapped`. Creating an unattached tap cannot silence an already-playing client before GlassEQ reads it, and direct playback resumes if the reader stops before Core Audio destroys the tap. Complete-composition rebuilds still prepare the full aggregate before starting its IOProc; physical-first startup creates and starts the output side before attaching the taps.

After starting the combined IOProc, GlassEQ keeps its output silent until it observes 32 consecutive callbacks with the frame count HAL applied to the aggregate, valid timestamp slopes, and no missed deadlines. Physical-first startup begins this qualification only after the callback-size request settles. It then fades in and requires another eight clean callbacks. A failed qualification tears down the graph, restores direct playback, retries the requested size once, and finally tries one safer buffer rung without changing the user's saved preference. Redundant default-output notifications with an unchanged physical route and format are ignored instead of rebuilding a healthy graph.

Nominal-rate and stream-format notifications bypass the observer's ordinary 50 ms coalescing delay for the first report. GlassEQ immediately tears down its old aggregate and process taps so HAL does not repeatedly restart that graph under the new physical clock. Direct system playback remains available during the 650 ms settlement window. The replacement process taps must publish the selected physical rate before GlassEQ creates either complete-composition or physical-first aggregate state. A stale tap format is destroyed and retried as a startup-settlement failure.

On an explicit stop or profile bypass, GlassEQ stops the graph and destroys its taps immediately so direct system playback can resume.

Teardown retains ownership of every IOProc, private aggregate, and process tap until Core Audio confirms that it was destroyed or reports that the object is already gone. A failed destruction is kept in a cleanup ledger, retried automatically with bounded backoff, and checked again before another route starts. Tap destruction is attempted independently so direct playback can recover even when a related aggregate or IOProc still needs cleanup. Unresolved handles remain retained for later retry instead of being forgotten while a live callback still owns its runtime.

Bluetooth routes at 24 kHz or below initially use a separate-clock compatibility backend. The tap runs in a tap-only aggregate, the physical output has its own HAL callback, and a bounded ring buffer, occupancy servo, and realtime sample-rate converter bridge the two clocks. A normal-rate output change recreates compatibility capture when the tap runtime was prepared at a different rate. After a low-rate route settles and its physical clock advances at the advertised rate, GlassEQ attempts to replace the bridge with the normal combined aggregate. A failed promotion or later paired timestamp discontinuity returns the route to compatibility mode for the remainder of that output transition.

## Real-Time Rules

The audio render path must not allocate, lock, touch disk, log, parse text, mutate SwiftUI state, or use Combine. UI and import work build and prewarm a complete candidate processor bank outside the callback. Biquad banks receive the normal 20 ms live-input warm-up. A new convolution bank receives 16,383 live frames so its complete impulse history is valid before the same sample-accurate 10 ms smoothstep blend begins. This permits filter-count, profile-type, and channel-mode changes without rebuilding the Core Audio graph or exposing a cold filter tail. Only the newest queued edit is retained, and retired banks are released outside the callback.

Convolution profiles compile log-frequency, linear-dB magnitude points into a 16,384-tap minimum-phase impulse. The compiler constructs the full even log-magnitude spectrum, performs the exact even-length real-cepstrum lift, and persists a synthesis version with the source points; generated samples are not stored. Rendering uses a 512-tap vectorized direct head and 62 vectorized 256-frame tail partitions with 512-point real FFTs. Tail work is scheduled against absolute sample-frame deadlines rather than callback count, so irregular and 480-frame callback sequences can cross internal block boundaries safely. Every Accelerate path and mutable buffer is exercised and detached before publication to the callback.

Imported WAV impulse responses use the same prepared renderer without minimum-phase reconstruction or normalization. GlassEQ persists the supplied mono or stereo samples and source rate so a valid response can remain in the library even when the current route differs. Preview, Apply, programme A/B, and current-output mapping reject a mismatch against the active DSP processing rate before mutating active state. That rate can differ from the physical output rate while the separate-clock backend converts low-rate playback. If a stored impulse response is selected before a separate-clock route has reported its DSP rate, GlassEQ leaves direct system playback unprocessed until a non-impulse-response profile establishes that rate. If an existing mapping becomes incompatible after a route-rate change, GlassEQ retains the mapping, stops its tap so normal dry playback continues, and reports the required and active rates. Imports remain limited to 16,384 taps per channel so they retain the realtime budget already verified for generated curves; responses are never truncated, resampled, or retimed silently.

The guided importer can also combine two linked text profiles or two mono WAV files as separate left and right channels. It shows the assignment before import and can swap the channels without reparsing the source files. The two files must use the same source kind and produce the same profile type.

The direct head produces tap zero immediately, while the partitioned tail is computed before the corresponding output frames become due. Convolution processing therefore adds computation but no fixed buffering or tap-to-output latency. The fixed tap count provides 2.93 Hz bins and 341 ms support at 48 kHz, 5.86 Hz and 171 ms at 96 kHz, and 11.72 Hz and 85 ms at 192 kHz. The last case is an explicit bass-resolution limit for future room-correction work.

A watchdog observes render progress outside the callback. One three-second steady-state stall stops the engine before rebuilding it once. Another stall within 60 seconds leaves GlassEQ stopped, restoring direct system audio until the user explicitly retries.

The render callback also counts callbacks that arrive or finish at least one complete callback period late. After the route has settled, three misses within one second form a deadline burst. Automatic mode continues to use its persisted route-specific reliability policy. Three clean sessions retry the next lower persisted request and stop once that request reaches 16 frames, regardless of the frame size Core Audio applies. A fixed mode rebuilds once at the selected size, then temporarily climbs through 32 and 64 frames if bursts recur within 60 seconds. The fixed preference is never overwritten. The temporary rung lasts until the route session ends or the user retries the fixed size. Another burst at 64 frames stops processing.

Programme-loudness A/B comparison is another transient render mode, not a profile mutation. The renderer runs the draft profile and a filters-off reference in parallel; the reference retains the same linked or per-channel preamp gains. “Filters off” removes either the biquad bank or the convolution curve. Both branches pass through BS.1770 K-weighting and a shared three-second rolling gate so they are measured over the same programme passages. GlassEQ attenuates only the louder branch, smooths match changes over 500 ms, and crossfades A/B selection over 10 ms. Starting and stopping the comparison reuse the whole-bank warm-up and transition path, including a gain restoration before returning to the saved active profile. The measured gains, selected branch, and filters-off reference are never persisted.

## Current Implementation Status

This repository contains the SwiftPM project, biquad and minimum-phase convolution DSP engines, guided EqualizerAPO, AutoEq, REW text, and WAV impulse-response import, native search of AutoEq's recommended results, profile persistence, menu bar shell, the combined Core Audio tap/output fast path, the transitional separate-clock Bluetooth headset backend, and the protocol-level client licensing module. The Core Audio bridge is intentionally isolated under `GlassEQAudio` so device-format support and hardware QA can be hardened without disturbing UI/profile code.

## Clocking And Routing

On normal-rate routes, the selected physical output is the aggregate's main subdevice and therefore owns the render clock. The process tap captures the device stream containing the output's preferred stereo pair. The aggregate created with its complete composition requests high-quality drift compensation for both taps. The physical-first path uses `setSubtaps` instead, and macOS 26.6 published only tap UIDs after that call, with no drift-enable or quality fields. GlassEQ validates membership and order but does not rewrite the composition or claim a drift-compensation setting for this path. The engine has one `AudioDeviceIOProcID`: each callback receives the tapped system mix, runs the active biquad or convolution bank, and writes directly to the physical output buffers. There is no application-level queue or asynchronous sample-rate converter on this path.

GlassEQ measures tap-to-output latency as the host-time difference between the first tapped input frame acquired for an I/O cycle and the first rendered output frame scheduled for hardware. Diagnostics report the observed average and range. This does not include latency before the system tap or after the output reaches the hardware.

On duplex interfaces, Core Audio exposes the physical input channels before the process-tap channels in the aggregate input layout. GlassEQ requires the tap to occupy complete input streams, disables every physical input stream for its I/O callback, and verifies the applied stream-usage mask. The physical-first path first verifies an all-disabled mask before starting its physical-only IOProc, then verifies the tap-only mask after attachment. The callback still understands the aggregate channel offsets because disabled streams remain present as null buffers. GlassEQ fails startup if Core Audio cannot isolate the tap this way.

The device-scoped tap deliberately follows one output stream rather than all system routes. Audio explicitly routed to another device, including a distinct system-alert output, is outside GlassEQ's processing path. The low-latency path currently requires the preferred pair to occupy one native mono or stereo hardware stream. A pair that spans streams cannot be captured by one device tap, while asking Core Audio to mix down a multichannel stream reintroduces the deep input latency this design avoids. Output or nominal-rate switching requires recreating the muted tap after macOS reports the new route, and a nominal-rate rebuild validates the tap's actual format before aggregate creation. D10s-to-Scarlett with a separate client pinned to the destination, AirPods-to-Scarlett, and Scarlett-to-AirPods switches passed on macOS 26.6, but switch handoff behavior across other drivers remains a hardware soak-test requirement.

AirPods headset transitions exposed periodic, matching input and output timestamp discontinuities in the combined aggregate at 24 kHz. A timestamp probe showed that HAL could advertise 24 kHz while advancing `mSampleTime` on the old 48 kHz scale, then reset the timeline after several seconds. A combined aggregate created after the headset route had settled ran cleanly, but larger aggregate buffers, drift-compensation changes, and tap mixdown did not make the transition safe. For Bluetooth routes at 24 kHz or below, GlassEQ first uses a tap-only aggregate and drives the physical output separately. A preallocated ring buffer carries processed samples between callbacks, an occupancy servo corrects clock drift, and the realtime converter handles the tap and device sample-rate difference. After six seconds, GlassEQ measures the physical device's sample-time slope for 500 ms. If it agrees with the nominal rate, GlassEQ tries the combined path and rejects it if a paired timestamp discontinuity appears during a 750 ms validation window. One later qualifying paired jump also returns the route to the bridge, with no second promotion attempt until the output changes. Returning to a normal-rate route disposes either headset backend and restores the combined fast path.

See [Aggregate clock experiment: findings](AggregateClockExperiment.md) for the measurements and experiments behind this design.

GlassEQ requests a 16-frame callback only from the private combined aggregate and leaves the physical output's shared buffer-frame property unchanged. While the separate-clock headset backend is active, Core Audio owns the physical output's low-rate callback size while tap capture uses its own aggregate quantum. EQ coefficients use the active processing rate. Parametric and graphic filters above the output route's usable-frequency ceiling receive identity coefficients. Convolution curves preserve their interpolated gain at the ceiling; each later control point through Nyquist is synthesized at unity so the response transitions continuously into that region without an unrealizable brick-wall boundary.

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
- Render callbacks that missed at least one complete callback period.
- Callback-start lateness, total render time, and completion lateness at p99.99 and maximum. Start lateness compares callback entry with the previous callback's expected period. Completion lateness adds render time to that delay and reports the amount beyond the next period.
- Convolution-only direct-head and scheduled-tail work at p99.99 and maximum.
- The smallest sample-frame margin observed when a 256-frame tail job completed, plus any tail jobs that missed their internal due frame.
- Average and range of tap-to-output latency from Core Audio's I/O timestamps.
- Samples that reached the soft clipper.

The timing percentiles come from fixed, callback-owned histograms. Normal timings use 0.25 microsecond buckets, timings above 64 microseconds use 4 microsecond buckets, and maxima remain exact. Each bounded scan publishes p50, p99, p99.9, p99.99, and maximum roughly every 1,024 callbacks. GlassEQ staggers the five scans so the measurement work does not land in one callback. Resetting metrics changes a generation counter; it does not clear histogram storage on the realtime thread.

The separate-clock fallback reports its additional bridge diagnostics instead: buffered frames, occupancy-derived bridge latency, clock correction, output timing gaps, sample-rate conversion, and reservoir target. Its bridge-latency number is not the same measurement as the combined path's timestamp-derived tap-to-output latency.

The Settings Output tab keeps the normal view to route health, route mode, output, active profile, selected and active buffer, measured added latency, and underrun events. Its collapsed **Stats for nerds** section exposes the timing percentiles, FIR head and tail timing, tail deadline margin, reliability counters, callback-size histograms, timestamp deltas, current route metadata, stream layouts, and device and aggregate safety offsets. App-owned observation, rebuild, recovery, escalation, and headset-fallback context survives runtime replacement; callback timing and frame counters describe only the current engine runtime. Resetting metrics starts both contexts at one visible timestamp.

The diagnostic follows the current macOS output device and does not switch outputs itself.

The release DSP benchmark accepts an optional EqualizerAPO GraphicEQ file so the convolution path can be measured with a real response:

```sh
swift run -c release GlassEQDiagnostics dsp-benchmark /path/to/GraphicEQ.txt
```

It reports average, p99.9, p99.99, and maximum callback work for the 16,384-tap cases at 48, 96, and 192 kHz, plus dual-bank transition cost. It measures DSP execution only, not Core Audio latency.

Diagnostics print full local device names, UIDs, and transport identifiers:

```sh
swift run GlassEQDiagnostics 2
```

`--intentional-crash-after-start` is reserved for crash-reporting and cleanup validation. It starts the engine, prints that the crash-test path was requested, flushes stdout, and aborts deliberately.

## Profile Storage And Settings Helper

Profile data belongs to the main app sandbox and is migrated by the main app through `container-migration.plist`. The settings helper does not share profile storage and does not need an app-group entitlement; it receives snapshots and sends commands over the private stdin/stdout IPC session launched by GlassEQ. `GlassEQCore` owns bounded text-file reading, format detection, EqualizerAPO, AutoEq, and REW parsing, and stereo text pairing. The package-internal `GlassEQProfileImport` target owns WAV decoding, AutoEq catalogue access, and the loader that selects the appropriate core or WAV importer without depending on UI frameworks. AutoEq downloads run in whichever process hosts the settings UI: normally the bundled settings helper, or the main app when it presents the fallback settings window. For local imports, the main app presents the open panel, reads and parses the selected files, and returns a bounded preview payload to Settings over the same IPC channel. Cancelling the import request or ending the Settings session cancels the main-app command and dismisses its open panel. The helper inherits the main app's static sandbox rights and must be signed with exactly `com.apple.security.app-sandbox` and `com.apple.security.inherit`; adding another App Sandbox entitlement causes `libsystem_secinit` to abort the child process before launch.

## First Launch

The main app records setup completion in `UserDefaults` under `onboarding.completedVersion`. Until that key is set, `GlassEQApp` constructs its model with `autoStart` disabled and presents the onboarding window at launch with a regular activation policy, so a fresh install shows a Dock icon and a foreground window instead of only a menu bar item. The engine starts when the guide's permission step asks for it, which is what triggers the system audio capture prompt. `GlassEQAppModel` owns the guide's audio-capture state and publishes explicit idle, pending, running, permission-denied, failed, and bypassed states. Closing the window at any step marks setup complete, starts audio if it has not started, and only then requests notification authorization. The Settings helper reopens the guide through the `showSetupGuide` command, and the main app raises it with the same generation-counter pattern used for the in-process settings window.

## Licensing

`GlassEQLicensing` owns the client side of the entitlement protocol in `Docs/EntitlementProtocol.md`. `EntitlementVerifier` is the trust boundary: it verifies compact Ed25519 JWS values against embedded public keys, rejects unknown or duplicate claims, checks the installation identity and entitlement revision, and validates the signed timeline. `LicensingController` is an actor that owns everything derived from that: the two device-only Keychain records, the trusted-time floor, activation and refresh requests through `LicenseServiceClient`, the refresh schedule, and the immutable `LicenseSnapshot` values it publishes. It never touches audio.

Enforcement lives in `GlassEQAppModel` and is active only when the app bundle embeds entitlement public keys. A bundle without the key dictionary is a source build and runs unrestricted; a dictionary that is present but unusable fails closed. Every tap start passes one gate, so a non-permitting snapshot never starts the observer or the engine. When a monthly entitlement reaches its signed expiry while processing, the model publishes the active profile as a bypassed bank, which renders as identity filters with unity preamp, waits for the render thread's DSP transition counters to report that exact transition complete, and only then stops the tap. `stop()` does not fade, so this ordering is what keeps the return to dry playback click-free. A transition that never completes is stopped after a bounded timeout because restoring dry playback outranks the fade. Renewal resumes through the ordinary startup path, never from the licensing callback.

The Settings helper never receives credentials or Keychain access. Settings license DTOs, the activation UI, and Sparkle download authorization are not implemented yet.

## Backlog

- Support preferred stereo pairs inside native output streams wider than two channels without enabling Core Audio tap mixdown. The first version should still process only the preferred pair, preserve the device-scoped native stream format, map the tapped channels and aggregate buffers explicitly, keep physical inputs disabled, and verify that the wider stream does not restore the 43.5 ms mixdown latency.
