# GlassEQ Architecture

## Audio Ownership Model

macOS owns output switching. GlassEQ observes the default output device and follows it. The app never asks the user to choose a physical output inside GlassEQ.

The normal-rate runtime flow is:

1. Discover current default output device and UID.
2. Load the mapped profile for that output UID.
3. Start a private global muted tap on a tap-only aggregate. Its silent IOProc keeps direct playback suppressed. Create separate device-scoped taps for the selected output and system sounds.
4. Build one private aggregate device containing the tap and physical output.
5. Use the physical output as the aggregate clock source. A complete-composition aggregate requests high-quality drift compensation for the taps; the physical-first attachment path accepts the tap metadata published by `setSubtaps`.
6. Disable every aggregate input stream except the tap stream for GlassEQ's I/O callback.
7. Process tap buffers and write the result to the physical output in one aggregate-device callback.
8. Retain the global tap across route changes and retries. Rebuild the renderer for the selected output and its mapped profile.

Normal-rate cold starts use physical-first ordering. GlassEQ starts a physical-only private aggregate at the incumbent buffer size with all inputs disabled. It attaches the device-scoped taps using `setSubtaps`, enables only their input streams and requests the preferred callback size on the private aggregate.

Both the global guard and the device-scoped taps use `mutedWhenTapped` and exclude GlassEQ itself. The guard produces no programme audio. The device-scoped taps feed the only playback renderer. Audio pinned to another device can be silenced while processing is enabled.

GlassEQ holds output muted through callback qualification and probation. Before activating the prepared bank it rechecks cancellation and the default device ID, UID, channel count and rate. A failed attempt tears down the renderer; the global guard stays active through bounded retries and terminal failure. The menu offers Retry and explicit handback.

Nominal-rate and stream-format notifications bypass ordinary coalescing. The app suspends the renderer during format settlement. Replacement taps must publish the selected rate before startup can succeed.

The Equalizer switch controls every output. Turning it off releases capture and restores direct system playback. The app keeps following the macOS output while bypassed, so profiles and assignments can change before processing resumes. The menu and Settings share this switch. Its value is stored in local preferences and excluded from portable profile libraries. On upgrade, the first observed output supplies the initial switch state from its previously saved profile. Importing a library never changes the switch.

Teardown retains ownership of every IOProc, private aggregate, and process tap until Core Audio confirms that it was destroyed or reports that the object is already gone. A failed destruction is kept in a cleanup ledger, retried automatically with bounded backoff, and checked again before another route starts. Tap destruction is attempted independently so direct playback can recover even when a related aggregate or IOProc still needs cleanup. Unresolved handles remain retained for later retry instead of being forgotten while a live callback still owns its runtime.

Bluetooth headset routes at 24 kHz or below run a temporary silent output IOProc with physical inputs disabled and verified. Half-second measurements must confirm the advertised clock slope within eight seconds. GlassEQ keeps that clock running through aggregate qualification and checks the combined timeline for a further 750 ms before unmuting. A qualifying timing interruption on the active headset suspends playback until retry.

Older beta builds could change the shared buffer size or sample rate. At launch GlassEQ reads any pending device restoration records, looks up the device by UID, and clears each setting only after verifying its original value. While a record remains, GlassEQ watches for the device to reconnect, even if another output is selected. It snapshots the device list before waiting for graph work, so a removal it observes permits another write even if the device returns with the same object ID. If HAL coalesces the changes and GlassEQ never sees the device leave, it keeps the one-write limit for that attachment. It retries outstanding settings on a confirmed reconnect before starting a renderer on that device. If the restored rate differs from the one used to select the profile, startup leaves the output muted while the app resolves the settled route and checks profile compatibility again. If a write has yet to appear in HAL, GlassEQ checks again shortly afterward without rewriting the setting. The observer follows physical format changes during recovery and GlassEQ removes the device-list listener once all settings are restored.

## Real-Time Rules

The audio render path must not allocate, lock, touch disk, log, parse text, mutate SwiftUI state, or use Combine. UI and import work build and prewarm a complete candidate processor bank outside the callback. Biquad banks receive the normal 20 ms live-input warm-up. A new convolution bank receives 16,383 live frames so its complete impulse history is valid before the same sample-accurate 10 ms smoothstep blend begins. This permits filter-count, profile-type, and channel-mode changes without rebuilding the Core Audio graph or exposing a cold filter tail. Only the newest queued edit is retained, and retired banks are released outside the callback.

Convolution profiles compile log-frequency, linear-dB magnitude points into a 16,384-tap minimum-phase impulse. The compiler constructs the full even log-magnitude spectrum, performs the exact even-length real-cepstrum lift, and persists a synthesis version with the source points; generated samples are not stored. Rendering uses a 512-tap vectorized direct head and 62 vectorized 256-frame tail partitions with 512-point real FFTs. Tail work is scheduled against absolute sample-frame deadlines rather than callback count, so irregular and 480-frame callback sequences can cross internal block boundaries safely. Every Accelerate path and mutable buffer is exercised before publication to the callback.

`EQRenderConfiguration` contains immutable coefficients, kernels, and paired Accelerate setups. Constructing an `EQProcessor` allocates and prewarms independent mutable state on the publishing thread. Each convolver owns one fixed scratch allocation divided into ten nonoverlapping regions; the direct history, tail input, overlap, and output ring remain inline. Inline capacities are checked during construction. The two spectrum histories stay on the heap so moving a processor does not move their sample contents.

`EQProcessor`, its convolver storage, `RealtimeEQTransition`, and the ownership-bearing render result are noncopyable. A convolution processor owns fixed storage for its channel histories. A biquad or bypass processor allocates no convolver storage. On adoption the renderer takes the prepared processor from its publication box. Rejection leaves it there for off-thread reclamation. After a successful transition the renderer moves the retired processor into the same box. The renderer queues it for reclamation off the callback. Shutdown releases remaining owners only after callbacks stop. Prepared configurations can be shared across processors, but their mutable histories cannot.

The forward and inverse DFT setups share Accelerate storage and remain owned together by the prepared kernel. Concurrent execution uses independent input and output buffers. Neither setup is created or destroyed while another sharing setup executes; the last kernel owner releases both outside rendering.

Imported WAV impulse responses reuse the prepared renderer without minimum-phase reconstruction or normalization. GlassEQ retains the original samples, rate and output mapping. Apply and A/B validate the processing rate. An incompatible destination profile holds the output muted until the user selects a compatible profile or disables processing. Imports are limited to 16,384 taps per channel.

The guided importer can also combine two linked text profiles or two mono WAV files as separate left and right channels. It shows the assignment before import and can swap the channels without reparsing the source files. The two files must use the same source kind and produce the same profile type.

The direct head produces tap zero immediately, while the partitioned tail is computed before the corresponding output frames become due. Convolution processing therefore adds computation but no fixed buffering or tap-to-output latency. The fixed tap count provides 2.93 Hz bins and 341 ms support at 48 kHz, 5.86 Hz and 171 ms at 96 kHz, and 11.72 Hz and 85 ms at 192 kHz. The last case is an explicit bass-resolution limit for future room-correction work.

A watchdog observes render progress outside the callback. One three-second steady-state stall suspends the renderer and rebuilds it once. Another stall within 60 seconds retains the mute and offers retry. When the watchdog, headset timing check, fixed-buffer recovery, or wake retries reach a terminal failure, the app keeps observing the selected output. Route and wake notifications cannot restart the renderer. Retry resolves the current default and its mapped profile. Disable releases the mute.

Automatic buffering starts at 64 frames for Bluetooth and Bluetooth LE outputs, and 16 frames for other transports. The policy applies this minimum to previously learned Automatic requests as well. Fixed choices of 16, 32, 64, or 128 frames override the transport default and remain saved per device, native output stream, and sample rate. The first successful Bluetooth connection after onboarding requests a one-time, silent notification explaining the default and offering Open Output Settings. The notice uses the existing notification permission and is marked as sent only after successful submission to Notification Center.

The render callback also counts callbacks that arrive or finish at least one complete callback period late. After the route has settled, three misses within one second form a deadline burst. Automatic mode uses its persisted route-specific reliability policy, increasing one rung after two qualifying interruptions within five minutes, up to 128 frames. Three clean sessions retry the next lower persisted request down to the transport default, regardless of the frame size Core Audio applies. The manual Automatic retry also returns to that default. A fixed mode rebuilds once at the selected size, then temporarily climbs through the larger available sizes up to 128 frames if bursts recur within 60 seconds. The fixed preference is never overwritten. The temporary rung lasts until the route session ends or the user retries the fixed size. Another burst at 128 frames stops processing.

Programme-loudness A/B comparison is another transient render mode, not a profile mutation. In Settings, **Compare** starts the current draft against the same draft with its filters removed and its preamp kept. The bottom bar then offers **Filters off** and **Filters on**; “filters off” removes either the biquad bank or the convolution curve. Settings locks profile selection and editing before dispatching Compare and keeps them locked through comparison; a failed start unlocks the editor. **Done**, closing Settings, and losing the helper connection all return playback to the saved active profile. **Apply** saves and activates the auditioned draft. A newly imported profile can be applied without editing it. Apply remains disabled while the start command is pending. The renderer applies the draft’s per-channel preamp to the original programme for Filters off. It measures both signals over the same passages with BS.1770 K-weighting and a shared three-second rolling gate. GlassEQ attenuates only the louder branch, smooths match changes over 500 ms, and crossfades selection over 10 ms. Starting and stopping the comparison reuse the whole-bank warm-up and transition path, including gain restoration on exit. Gains stay inside the renderer; comparison snapshots publish only activity, readiness, and selection. None of the comparison state is persisted.

## Clocking And Routing

On normal-rate routes, the selected physical output is the aggregate's main subdevice and therefore owns the render clock. The process tap captures the device stream containing the output's preferred stereo pair. The aggregate created with its complete composition requests high-quality drift compensation for both taps. The physical-first path uses `setSubtaps` instead, and macOS 26.6 published only tap UIDs after that call, with no drift-enable or quality fields. GlassEQ validates membership and order but does not rewrite the composition or claim a drift-compensation setting for this path. The engine has one `AudioDeviceIOProcID`: each callback receives the tapped system mix, runs the active biquad or convolution bank, and writes directly to the physical output buffers. There is no application-level queue or asynchronous sample-rate converter on this path.

GlassEQ measures tap-to-output latency as the host-time difference between the first tapped input frame acquired for an I/O cycle and the first rendered output frame scheduled for hardware. Diagnostics report the observed average and range. This does not include latency before the system tap or after the output reaches the hardware.

On duplex interfaces, Core Audio exposes the physical input channels before the process-tap channels in the aggregate input layout. GlassEQ requires the tap to occupy complete input streams, disables every physical input stream for its I/O callback, and verifies the applied stream-usage mask. The physical-first path first verifies an all-disabled mask before starting its physical-only IOProc, then verifies the tap-only mask after attachment. The callback still understands the aggregate channel offsets because disabled streams remain present as null buffers. GlassEQ fails startup if Core Audio cannot isolate the tap this way.

The device-scoped tap follows the output stream containing the selected stereo pair. The global guard suppresses direct playback while a renderer is active or a replacement is being qualified. Explicit stop releases both owners.

AirPods headset transitions can advertise 24 kHz while the physical clock still advances on its old 48 kHz timeline. The app measures the clock before starting the low-rate aggregate.

See [Aggregate clock experiment: findings](AggregateClockExperiment.md) for the measurements and experiments behind this design.

GlassEQ requests the selected callback size only from the private combined aggregate and leaves the physical output's shared buffer-frame property unchanged. EQ coefficients use the active processing rate. Parametric and graphic filters above the output route's usable-frequency ceiling receive identity coefficients. Convolution curves preserve their interpolated gain at the ceiling; each later control point through Nyquist is synthesized at unity so the response transitions continuously into that region without an unrealizable brick-wall boundary.

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

The Settings Output tab keeps the normal view to route health, output, active profile, selected and active buffer, measured added latency, and underrun events. Its collapsed **Stats for nerds** section exposes the timing percentiles, FIR head and tail timing, tail deadline margin, reliability counters, callback-size histograms, timestamp deltas, current route metadata, stream layouts, and device and aggregate safety offsets. App-owned observation, rebuild, recovery, and buffer escalation history survives runtime replacement; callback timing and frame counters describe only the current engine runtime. Resetting metrics starts both contexts at one visible timestamp.

On macOS 27, the Audio Buffer card shows an inline notice for Bluetooth and Bluetooth LE outputs that macOS may apply a larger buffer than selected. The main app supplies Bluetooth transport metadata independently of its localized transport label; older IPC payloads without that optional field do not show the notice. A fixed/active size mismatch reports the actual size and saved preference without inferring an instability event. The notice does not change buffer selection or recovery policy. See the [macOS 27 measurements and Apple feedback reference](AggregateClockExperiment.md#macos-27-airpods-buffer-clamp).

The diagnostic follows the current macOS output device and does not switch outputs itself.

The release DSP benchmark accepts an optional EqualizerAPO GraphicEQ file so the convolution path can be measured with a real response:

```sh
swift run -c release GlassEQDiagnostics dsp-benchmark /path/to/GraphicEQ.txt
```

The benchmark feeds independent, preallocated stereo buffers through the render path. Workloads cover 128 active biquads per channel at 192 kHz, 16,384-tap FIR at 48, 96 and 192 kHz, repeated profile edits, and Filters Off comparison. The irregular FIR sequence includes 1, 17, 255, 257 and 480 frames. Each case reports mean, p99.9, p99.99 and maximum DSP duration, minimum time left in the frame budget, and over-budget renders. FIR cases also report minimum tail-job slack and missed jobs. Input refill, bank construction, result consumption and retirement fall outside the timer. Each render’s budget use is its elapsed time divided by its own frame period. The optional `--check` fails when overall mean use reaches 50% or p99.99 use exceeds 100%. The default command reports both values. These offline wall-clock timings include descheduling on an ordinary thread. Callback-start and completion lateness require the live route metrics above.

Diagnostics print full local device names, UIDs, and transport identifiers:

```sh
swift run GlassEQDiagnostics 2
```

`--intentional-crash-after-start` is reserved for crash-reporting and cleanup validation. It starts the engine, prints that the crash-test path was requested, flushes stdout, and aborts deliberately.

## Profile Storage And Settings Helper

When recovery of a damaged profile library reports a backup failure, the main app opens it read-only and skips the save on quit. Relaunch retries recovery. An explicit reset backs up the original bytes before replacing the library.

Profile data belongs to the main app sandbox and is migrated by the main app through `container-migration.plist`. The settings helper does not share profile storage and does not need an app-group entitlement; it receives snapshots and sends commands over the private stdin/stdout IPC session launched by GlassEQ. `GlassEQCore` owns bounded text-file reading, format detection, EqualizerAPO, AutoEq, and REW parsing, and stereo text pairing. The package-internal `GlassEQProfileImport` target owns WAV decoding, AutoEq catalogue access, and the loader that selects the appropriate core or WAV importer without depending on UI frameworks. AutoEq downloads run in whichever process hosts the settings UI: normally the bundled settings helper, or the main app when it presents the fallback settings window. For local imports, the main app presents the open panel, reads and parses the selected files, and returns a bounded preview payload to Settings over the same IPC channel. Cancelling the import request or ending the Settings session cancels the main-app command and dismisses its open panel. The helper inherits the main app's static sandbox rights and must be signed with exactly `com.apple.security.app-sandbox` and `com.apple.security.inherit`; adding another App Sandbox entitlement causes `libsystem_secinit` to abort the child process before launch.

The helper receives the library when it connects. After the ready acknowledgment, the main app sends any changes since that snapshot. Library changes travel in order on the event stream. Structural changes send the updated profiles, and smaller changes send patches. A successful command acknowledges the change without resending the library. Settings can apply a saved version of the active profile when its contents differ from the bank GlassEQ last applied. The menu and buffer notifications both open the bundled helper. If the helper cannot start, the main app hosts the editor until its window closes, then releases it and cancels any open file picker.

Before committing an edit, the main app validates the candidate library and encodes it at the current schema version. The debounced writer saves those checked bytes atomically. Each edit or rollback gets a new generation, so a delayed write cannot replace a newer one. The app releases the encoded bytes after the write and synchronizes the latest generation before quitting.

The library export includes profiles, output assignments, the fallback profile and explicit buffer choices. Learned buffer sizes and failure history stay on this Mac. Add preserves existing choices and the editor draft. Replace writes a backup of the outgoing library before committing the new store in a single rename. Both operations preserve an explicit Stop. The app keeps the original store file beside the migrated store when upgrading its schema.

After launch, the main app compares the helper bundle and executable by filesystem device and inode so symlink aliases identify the same files. Missing or different files fail validation. Bundle containment and bundle, executable, and running-process signature checks remain required.

The Settings window owns a bounded frequency-analysis cache. It warms stored profiles with at most two jobs, prioritizes the selected draft, and retains stored results while the draft changes. Selection reads matching cached results synchronously. A cold analysis publishes its response curve before computing headroom; headroom actions require a result matching the current draft and processing rate. Profile edits and route changes supersede obsolete work, and closing the window cancels pending jobs. The editor reuses its common controls across selections and ties text-edit sessions to the profile, channel, filter, and revert generation so delayed focus events cannot change another value.

## First Launch

The main app records setup completion in `UserDefaults` under `onboarding.completedVersion`. Until that key is set, `GlassEQApp` constructs its model with `autoStart` disabled and presents the onboarding window at launch with a regular activation policy, so a fresh install shows a Dock icon and a foreground window instead of only a menu bar item. In builds that embed entitlement public keys, an activation step precedes the permission step because a tap start refuses to run while unlicensed; source builds omit that step. The step calls `activateLicense(key:)` on `GlassEQAppModel`, which forwards to the licensing owner and keeps only the operation in flight and the last failure's localized copy, never the key. `LicenseRecovery` turns a non-permitting snapshot into the one action the user can take, and both the step and the menu bar status read it, so neither names an action the controller would refuse. A record that needs removal is released through the same seam after a confirmation; a record that needs a newer app is left alone. Graceful termination gives an in-flight request a grace period before the licensing checkpoint, then cancels it and waits for the controller to observe the cancellation; nothing new starts once termination has begun, and the controller refuses operations after shutdown. The engine starts when the guide's permission step asks for it, which is what triggers the system audio capture prompt. `GlassEQAppModel` owns the guide's audio-capture state and publishes explicit idle, pending, running, permission-denied, failed, and bypassed states. Closing the window at any step marks setup complete, starts audio if it has not started, and only then requests notification authorization. The Settings helper reopens the guide through the `showSetupGuide` command, and the main app raises it with the same generation-counter pattern used for the in-process settings window.

## Licensing

`GlassEQLicensing` owns the client side of the entitlement protocol in `Docs/EntitlementProtocol.md`. `EntitlementVerifier` is the trust boundary: it verifies compact Ed25519 JWS values against embedded public keys, decodes only the exact claim set for the signed plan, checks the installation identity and entitlement revision, and validates the signed timeline. `LicensingController` is the actor that owns the two device-only Keychain records, trusted time, activation and refresh requests through `LicenseServiceClient`, scheduling, and immutable `LicenseSnapshot` publication. The activation record carries a required schema version so an older build leaves state written by a newer schema intact. A user-requested activation or deactivation may clear a malformed current-schema record. Every snapshot carries an `ActivationAvailability` decided where the record is loaded and verified: activation is available, a verified record exists, a verified record has lost its service access and can only be removed once it stops permitting processing, a tombstone is still releasing its slot, the Keychain is unreadable, the record needs a newer app because its schema, signing key, header, or claims are unknown, or the record cannot be used on this Mac and needs removal. A malformed identity record never discards the activation record, whose token is what releases the server slot. Verified entitlements are cached with the loaded activation so repeated snapshot evaluation does not redo signature verification. It never touches audio.

Enforcement lives in `GlassEQAppModel` and is active only when the app bundle embeds entitlement public keys. A bundle without the key dictionary is a source build and runs unrestricted; a dictionary that is present but unusable fails closed. Every tap start passes one gate, so a non-permitting snapshot never starts the observer or the engine. When a monthly entitlement reaches its signed expiry while processing, the model publishes the active profile as a bypassed bank, which renders as identity filters with unity preamp. That publication returns an immutable transition ID; the model waits for the render thread to report the same ID complete before it stops the tap. `stop()` does not fade, so this ordering is what keeps the return to dry playback click-free. A transition that never completes is stopped after a bounded timeout because restoring dry playback outranks the fade. Renewal uses the ordinary startup path while processing is requested. If GlassEQ was already offering Retry after a startup or recovery failure and expiry handed playback back to macOS, renewal leaves playback direct. The app observes the current output and offers Retry. Explicit Retry selects that output’s profile and acquires the mute again. Wake follows the same rule.

A released activation slot revokes service access but never the signed offline authority; a local deactivation tombstones the record before the request so the installation fails closed. If the server creates an activation that the client cannot verify or persist, the controller stores a cleanup-only tombstone before attempting deactivation and retries both storage and server cleanup. The Settings helper never receives credentials or Keychain access. Onboarding activation talks to the controller through the typed `LicensingProviding` seam in the main app and maps every `LicensingError` to fixed copy, so server text is never displayed. Settings license DTOs and Sparkle download authorization are not implemented yet.

## Backlog

- Support preferred stereo pairs inside native output streams wider than two channels without enabling Core Audio tap mixdown. The first version should still process only the preferred pair, preserve the device-scoped native stream format, map the tapped channels and aggregate buffers explicitly, keep physical inputs disabled, and verify that the wider stream does not restore the 43.5 ms mixdown latency.
