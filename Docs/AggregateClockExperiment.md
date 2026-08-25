# Aggregate clock experiment: findings

## Experiment

I tested replacing GlassEQ's separate capture and playback paths with one private Core Audio aggregate containing both the process tap and the physical output.

The aggregate architecture worked remarkably well on normal-rate routes. It survived output switching, Bluetooth switching, sleep and wake, notifications, and both the D10s and Scarlett Solo. Capture and playback callbacks remained small, I observed no underruns, and the release app used roughly 1 to 2 percent CPU.

It also removed a substantial amount of application complexity:

- Separate capture and playback clocks
- Ring-buffer occupancy control
- Drift servo
- Hermite resampler
- Priming and underrun recovery logic

Core Audio's drift compensation handled the tap clock cleanly on those routes. Disabling it did not change the latency of the first aggregate design.

The latency result initially appeared to rule out the architecture. A later change to the tap itself reversed that conclusion.

This file is deliberately a workbook rather than a polished final report. It retains failed hypotheses, superseded implementations, live hardware observations, and the reasoning that connected them. Later sections record changes built on top of the aggregate architecture, especially where they expose another realtime limit.

## What the latency figures measure

The figures below measure tap-to-output latency. The input timestamp marks the first process-tap frame available to GlassEQ, and the output timestamp marks when the first processed frame is scheduled for the physical output.

They do not include latency before the process tap or after the output reaches the hardware. The DAC, amplifier, speaker, and acoustic path are outside the measurement.

## First result: global tap in the combined aggregate

The first combined aggregate used GlassEQ's existing global stereo tap. On the Scarlett Solo at 48 kHz with 64-frame callbacks, it was slower than the reference architecture:

| Measurement | Global-tap combined aggregate | Reference GlassEQ design |
| --- | ---: | ---: |
| Input age when processing begins | 21.114 ms | 22.655 ms |
| Application bridge and reservoir | None | 2.054 ms |
| Output scheduling lead | 22.386 ms | 1.635 ms |
| Total tap-to-output latency | 43.500 ms | 26.345 ms |

The reference design was about 17.2 ms faster. The same 43.5 ms combined-aggregate result appeared on the D10s, which ruled out the Scarlett as the cause.

### Why the first aggregate was slower

The 64-frame callback size controls callback cadence. At 48 kHz, each callback represents 1.333 ms. It does not determine the complete pipeline depth.

Core Audio reported these relevant latency margins:

| Path | Reported margin |
| --- | ---: |
| Global-tap combined aggregate input | 74 frames of input latency plus a 950-frame safety offset, totalling 1,024 frames |
| Global-tap combined aggregate output | 14 frames of output latency plus a 1,010-frame safety offset, totalling 1,024 frames |
| Tap-only aggregate input | 1,024-frame safety offset |
| Physical Scarlett output | 14 frames of output latency |

The callback timestamps aligned with the active safety margin plus one callback block:

- Combined input: `(950 + 64) / 48,000 = 21.125 ms`
- Combined output: `(1,010 + 64) / 48,000 = 22.375 ms`
- Reference capture: `(1,024 + 64) / 48,000 = 22.667 ms`
- Reference output: `(14 + 64) / 48,000 = 1.625 ms`

Core Audio appeared to align both sides of the combined aggregate with the global process tap's 1,024-frame latency budget. On the output side, it preserved the Scarlett's 14-frame device latency and raised the aggregate safety offset to 1,010 frames.

The reference architecture kept the tap in its own aggregate but drove the physical output directly. It still paid the process tap's large capture margin, then crossed into the physical output's much smaller scheduling margin. Its ring buffer, servo, and resampler cost about 2 ms, but they avoided roughly 21 ms of aggregate output lead.

At this point, the reference design's complexity looked justified. That conclusion was correct for a global tap, but the global tap turned out to be the wrong comparison.

## The breakthrough: bind the tap to the output stream

Core Audio can create a process tap for one selected stream on one selected output device. Replacing the global stereo tap with this device-scoped tap changed the timing completely.

On the same Scarlett Solo route, still at 48 kHz with 64-frame callbacks:

| Measurement | Device-scoped combined aggregate | Global-tap combined aggregate | Reference GlassEQ design |
| --- | ---: | ---: | ---: |
| Input age when processing begins | 2.864 ms | 21.114 ms | 22.655 ms |
| Application bridge and reservoir | None | None | 2.054 ms |
| Output scheduling lead | 1.636 ms | 22.386 ms | 1.635 ms |
| Total tap-to-output latency | 4.500 ms | 43.500 ms | 26.345 ms |

The device-scoped aggregate reported 74 input safety frames and 14 output safety frames. With one 64-frame callback on each side, those values predict the measured result closely:

- Input: `(74 + 64) / 48,000 = 2.875 ms`
- Output: `(14 + 64) / 48,000 = 1.625 ms`
- Total: `(74 + 64 + 14 + 64) / 48,000 = 4.500 ms`

The application bridge disappeared, and Core Audio stopped imposing the global tap's 1,024-frame budget on both halves of the aggregate. The combined architecture became about 21.8 ms faster than the reference GlassEQ design and 39 ms faster than the first aggregate.

The physical-output lead remained effectively identical to the reference design, 1.636 ms versus 1.635 ms. The entire gain came from reducing the age of the tapped input and removing the application-managed bridge.

## A 32-frame aggregate can sit on a 512-frame physical device

The first 32-frame experiment exposed an important distinction between the physical output device and the private aggregate.

While the release app was running on the Scarlett, a separate read-only Core Audio query reported:

- Physical Scarlett object: 512 buffer frames
- GlassEQ capture callback peak: 32 frames
- GlassEQ output callback peak: 32 frames
- Tap-to-output latency: 3.17 ms
- Captured and played: 9,154,720 frames each
- Underruns, dropped input, and saturated samples: zero

The callback timing matches the same latency model with 32-frame quanta:

`(74 + 32 + 14 + 32) / 48,000 = 3.167 ms`

This is not a cosmetic 32-frame setting. The aggregate IOProc was receiving and producing 32-frame callbacks even though `kAudioDevicePropertyBufferFrameSize` on the physical Scarlett reported 512 frames to another process.

The Output pane's Buffer field alone does not prove the active callback size. GlassEQ caches that value from the engine's output metadata. The capture and output callback peaks are the direct runtime evidence.

The practical lesson is that the physical subdevice's buffer-frame property is not a reliable proxy for a private aggregate's IOProc quantum. Diagnostics must query the aggregate from its owning process or measure the frames delivered to its callbacks. Private aggregate devices are not visible to an external Core Audio device enumeration.

## The first 16-frame failure was not a 16-frame limit

The first Scarlett run at 16 frames crackled badly and produced a brief high-pitched tone when GlassEQ started and stopped. GlassEQ still reported 16-frame capture and output callbacks, 2.500 ms tap-to-output latency, and zero underruns, dropped input frames, or saturated samples.

Reducing the callback size therefore looked like the cause, but returning to 32 frames did not fix the crackle. That run also reported clean application counters despite audible corruption. The failure was outside the parts of the path those counters observe.

The startup timing in Core Audio's log distinguished the bad and good runs:

- A previously clean 32-frame aggregate began its IO work loop about 36 ms after activation.
- The crackling 32-frame aggregate took about 1.28 seconds and coincided with an audio I/O overload on Music's 512-frame USB route.
- After a verified device-idle reset, a clean 32-frame aggregate started in about 28 ms with no startup overload.

We then repeated the 16-frame test after the same reset. It ran cleanly with 16-frame capture and output callback peaks, fixed 2.500 ms tap-to-output latency, 1,888,608 frames captured and played, and zero application counters. This result strongly suggests that the initial 16-frame run inherited a bad route state. It does not prove that 16 frames will be reliable on every startup or output device.

## The 74-frame term belongs to the output device, not its input topology

The Scarlett result initially suggested that its physical input caused the aggregate's 74-frame input-side margin. A route comparison disproved that hypothesis.

GlassEQ now samples the host clock at callback entry and splits the tap-to-output timestamp interval into input age and output scheduling lead. At 48 kHz with 16-frame aggregate callbacks, the results were:

| Physical output | Physical input streams | Input safety | Output safety | Measured input age | Measured output lead | Tap to output |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| D10s | None | 74 frames | 14 frames | 90.023 frames | 29.978 frames | 120 frames / 2.500 ms |
| Scarlett Solo | 2 channels | 74 frames | 14 frames | 89.938 frames | 30.061 frames | 120 frames / 2.500 ms |
| MacBook Pro Speakers | None | 36 frames | 48 frames | 51.593 frames | 64.407 frames | 116 frames / 2.417 ms |
| LEN Y27q-20 DisplayPort | None | 0 frames | 320 frames | 15.576 frames | 336.423 frames | 352 frames / 7.333 ms |

The physical device and private aggregate reported the same safety offsets on every route. The callback timings followed:

`input safety + one input quantum + output safety + one output quantum`

The separate device-latency properties were not added to this timestamp interval. This is clearest on the built-in speakers, which reported 21 frames of input latency and 60 frames of output latency but measured exactly the safety-offset model.

The D10s is the decisive case. It is an output-only device with no physical input streams, but it still publishes a 74-frame input-scoped safety offset. The private aggregate inherits that value from the D10s as its main subdevice. The Scarlett microphone topology therefore caused the microphone indicator, but it did not cause the 74-frame scheduling term.

Both safety-offset properties were read-only on the D10s and its aggregate. An isolated aggregate-description test also assigned `-74` frames of extra input latency to the D10s subdevice. Core Audio accepted the description but left both the reported offsets and measured 90/30-frame timing unchanged. The earlier negative sub-tap latency test made the aggregate unusable.

There is no supported direct override left to try. Removing the D10s's 74-frame term would require changing which device supplies the aggregate's timing metadata, probably through another clock-master or virtual-device layer. That would reintroduce another clock domain or a custom Core Audio driver to save 1.542 ms, with no evidence that the resulting path would remain stable. The practical floor is therefore device-specific: GlassEQ can minimize its callback quanta, but the main output device supplies the fixed safety margins.

### The deeper 74-frame investigation

The follow-up investigation in [AggregateSafetyOffsetInvestigation.md](AggregateSafetyOffsetInvestigation.md) tested the remaining supported aggregate controls and several useful negative controls.

Three USB audio devices, including two output-only engines, all reported an input safety offset of exactly 74 frames. Their output offsets differed. Built-in and DisplayPort outputs published different input margins, and a third-party aggregate mirrored its main subdevice's values even when another USB subdevice was present. The common 74-frame value is therefore a policy of Apple's USB audio driver family, not a measurement of a microphone path.

The aggregate experiments narrowed the model further:

- Single-subdevice aggregates mirrored the main subdevice.
- Setting `channels-in` to zero did not change the offset. HAL could also restore the physical input channels in the composition readback.
- A stacked aggregate suppressed the phantom Scarlett input channels, but retained the 74-frame input safety offset.
- Adding subdevices never reduced the main device's margin. It could only raise the other scope.
- A TimeSync clock doubled the Scarlett margins from 74/14 to 148/28 and made the physical output a drift-corrected member.
- Negative extra-latency values clamped at zero. Positive values raised the aggregate safety offset exactly.
- Aggregate buffer sizes of 16, 512, and 4,096 frames did not change either safety offset.
- The aggregate safety-offset property was not writable.

The last genuinely supported candidate was `AudioHardwareAggregateDevice.setClockSource(_:)`. Apple permits a device, clock, or tap as the requested clock source, so a device-scoped tap looked like a possible way to retain the physical output stream without importing the whole device's input margin.

It did not work. On both the Scarlett and D10s, asking for the tap before I/O, during I/O, or through the aggregate composition still published the backing physical device as the clock source and retained 74/14. A tap-only aggregate published no clock source but kept the same margins. Neither USB device exposed a separate `AudioHardwareClock` object. The device-scoped tap carries its backing device's timing margins with it.

This closes the supported app-level design space. The aggregate's tap-to-output scheduling cost is:

`input safety offset + one callback + output safety offset + one callback`

GlassEQ controls the callback size. The physical output driver controls both safety offsets. Removing the USB driver's 74 frames would require a custom audio driver or system extension, which would add installation, approval, maintenance, and probably another clock domain to recover 1.542 ms at 48 kHz. That is not a sensible product trade.

## Silent Core Audio clients can prevent a route reset

Stopping GlassEQ and pausing Music did not make the Scarlett idle. `kAudioDevicePropertyDeviceIsRunningSomewhere` remained set for more than 40 seconds.

A query of Core Audio's process objects identified Firefox as a running output client. Firefox was not producing audible sound, but it still claimed the default output route. After Firefox quit, the Scarlett immediately became idle. We held that state for five seconds, then started GlassEQ. Both the 32-frame and subsequent 16-frame runs were clean.

This is useful diagnostic evidence, but it is not an acceptable startup constraint. GlassEQ cannot require users to close browsers, media players, or other silent clients before it starts.

### Aggregate-only buffer tuning fixes the shared-device startup problem

The most suspicious shared-state mutation was GlassEQ's physical-device buffer tuning. The first startup path wrote the preferred frame count to the physical output before creating the aggregate, then applied the resulting size to the private aggregate as well. Changing the physical device could disturb every client using the route.

The Scarlett measurements showed that this coupling was unnecessary. The physical device continued to report a 512-frame buffer while GlassEQ's private aggregate delivered stable 32-frame and 16-frame callbacks.

GlassEQ now leaves the physical device's buffer-frame property alone and requests 16 frames only on its private aggregate. This passed the cases that had previously exposed the bad route state:

- The physical Scarlett remained at 512 frames while the aggregate delivered 16-frame callbacks.
- The physical AirPods route remained at its Core Audio-owned size while the aggregate delivered 16-frame callbacks.
- GlassEQ no longer waits for the physical device to become idle or requires a silent Firefox client to release it.
- Normal playback, restarts, and output switching remained clean.

HAL still owns any internal work needed to connect the aggregate to its subdevice, but GlassEQ no longer mutates shared physical-device state. Waiting for `DeviceIsRunningSomewhere == 0` remains a diagnostic reset procedure, not product behavior.

## AirPods also accept 16-frame aggregate callbacks

We removed the Bluetooth-specific 64-frame preference and started the release app on an active AirPods Pro route at 48 kHz. Core Audio accepted the request rather than clamping it:

- Capture callback peak: 16 frames
- Output callback peak: 16 frames
- Tap-to-output latency: 0.667 ms
- Captured and played: 3,288,864 frames each
- Underruns, dropped input, and saturated samples: zero
- Subjective playback: clean, with no crackle heard

The latency number ends at the Bluetooth output timestamp. It does not include the AirPods codec, radio, or internal playback buffering, so it is not an estimate of acoustic latency. The result does show that GlassEQ can feed the Bluetooth route in 16-frame aggregate callbacks without adding a larger application-visible scheduling quantum.

## Headset mode exposes a combined-aggregate clock failure

Normal 48 kHz AirPods playback remained clean at 16 frames. When a conferencing app switched the same device into its bidirectional 24 kHz headset mode, the combined aggregate produced an audible timing disturbance about every 60 ms.

The failure did not look like ordinary starvation:

- Audio kept playing rather than dropping out completely.
- Capture and output callbacks continued at their expected sizes.
- Underrun, dropped-frame, and saturation counters remained at zero.
- Input and output timestamp-discontinuity counters accumulated together.
- Leaving headset mode immediately restored clean 48 kHz playback without a persistent fault.

Increasing the aggregate target, disabling tap drift compensation, and enabling tap mixdown did not fix the disturbance. Mixdown also carries the severe latency penalty described above. Aggregate-only buffer tuning kept the physical headset route at its Core Audio-owned 480-frame buffer and the private aggregate at 16 frames, but the periodic timestamp jumps remained.

The preserved separate-clock GlassEQ implementation was clean on the same 24 kHz route. In that run it used 64-frame tap capture, a 480-frame physical-output callback, 48-to-24 kHz conversion, about -1.4 ppm of clock correction, and a 2,047-to-2,048-frame reservoir. Its occupancy-derived bridge latency was about 42.65 ms.

This points to a route-specific combined-aggregate timeline problem, not a general inability to run the device or process its low-rate format. The application-managed bridge is slower, but it prevents the aggregate's input and output timestamp jumps from reaching the physical output as audible jitter.

GlassEQ therefore starts Bluetooth routes at 24 kHz or below on the separate-clock backend. Entering headset mode switches to that backend; leaving it restores the normal combined aggregate. The original hybrid release switched both ways without a relaunch, and subjective playback in headset mode was clean.

### Timestamp probe confirms a transitional HAL clock mismatch

A forced-combined diagnostic recorded the raw input and output `AudioTimeStamp` values for every discontinuity. The callback wrote into a preallocated 64-record circular buffer and copied it only after Core Audio stopped.

The first run began on the 48 kHz AirPods route and captured the switch into 24 kHz headset mode. The next run started while the physical device and combined aggregate both reported 24 kHz. During the broken period it recorded:

- 95 input jumps and 95 output jumps, paired in the same callbacks
- A repeating jump cadence of approximately 50 ms, 50 ms, and 60 ms
- 16-frame input and output callbacks throughout
- Zero underruns and dropped frames
- Identical sample-time and host-time errors on input and output
- `mRateScalar` fixed at `1.0`
- `mFlags` fixed at `0x7`, marking sample time, host time, and rate scalar as valid

The raw timestamps exposed the inconsistency. Between jump records, `mSampleTime` advanced at 48,000 units per second even though both devices advertised 24 kHz. At each discontinuity, the callback arrived 11.667 to 18.333 ms later than its 16-frame cadence predicted, and `mSampleTime` skipped the corresponding interval on the same 48 kHz scale. The recurring positive sample-time errors were 576, 736, and 896 frames.

After roughly five seconds, Core Audio issued one large negative sample-time reset of 238,828 frames. The periodic jumps then stopped. A later forced-combined run started only after Teams headset mode had fully settled. Both the physical device and aggregate reported 24 kHz, 239,584 frames passed in ten seconds, and the probe recorded no timestamp discontinuities.

The headset failure is therefore transitional rather than an inherent inability to run a combined aggregate at 24 kHz. HAL can publish the new nominal rate before the aggregate timeline has stopped advancing on the old 48 kHz scale. It reports the timestamps as valid and keeps `mRateScalar` at `1.0`, so the application receives no metadata warning. Since the aggregate presents one input/output callback, the same clock correction reaches both sides and becomes audible.

The separate-clock fallback remains the safe behavior during the transition. The experimental policy now uses it while the headset route settles, verifies the physical device clock, and only then tries the combined aggregate. The clean steady-state test makes that plausible, but repeated hardware transition testing is still required before treating it as proven product behavior.

### Experimental transitional headset promotion

The first implementation keeps the compatibility backend running for six seconds after a low-rate Bluetooth route starts. It then samples the physical device clock for another 500 ms and requires `mSampleTime` to advance within two percent of the advertised sample rate. A valid `mRateScalar` must also remain within two percent of `1.0`.

If the clock agrees, GlassEQ creates the combined aggregate and watches its paired input/output timestamp-discontinuity counter for 750 ms before accepting it. A failed clock check or an immediate aggregate jump restores the already-proven separate-clock backend. GlassEQ makes only one promotion attempt per output transition, so a rejection cannot create a rebuild loop.

After promotion, the normal settled-route timestamp monitor remains active. One qualifying paired input/output discontinuity returns that route to compatibility mode for the rest of the output generation. This failure is deliberately kept out of the ordinary 16-to-32-to-64 aggregate-buffer ladder: the headset fault is a clock-domain transition problem, not evidence that the callback quantum is too small.

This policy avoids maintaining the bridge as the permanent low-rate playback path while retaining it as a bounded transition and recovery mechanism. It is covered by lifecycle and clock-slope tests. A real AirPods and Teams test confirmed that the route can settle in compatibility mode and promote to the combined aggregate. The first handoff caused a small playback jump, but steady combined playback was clean. The refined handoff now prepares the replacement output before quiescing the old backend; the remaining transition artifact stays on the hardware soak checklist.

### Teams can publish its own output route

Teams did not always switch the existing physical device into another format. With the Scarlett active, it exposed a separate `Microsoft Teams Audio` output with UID `MSLoopbackDriverDevice_UID`. Core Audio reported one channel at 48 kHz, GlassEQ obtained 32-frame capture and output callbacks, and tap-to-output measured 1.33 ms with clean counters.

GlassEQ treated it as an ordinary output device and used the fallback profile because it had its own UID. This is the right behavior. Conferencing mode should follow the actual Core Audio route, transport, format, and clock evidence. An application denylist would miss virtual devices like this and would disable working routes for no technical reason.

## The `isMixdown` trap

The device-scoped tap must use the selected hardware stream's native format. Setting `CATapDescription.isMixdown` to `true` looked like a reasonable way to retain support for multichannel streams, but it restored the old 43.500 ms latency on the Scarlett.

Removing `isMixdown` immediately restored 4.500 ms under otherwise identical conditions.

This was the decisive variable. The low latency does not come merely from naming a device in the tap description. It requires all of the following:

- A device-scoped tap
- One selected output stream
- The stream's native format
- No Core Audio tap mixdown

The current implementation therefore accepts native mono and stereo output streams and rejects wider streams. It does not silently fall back to the high-latency mixdown path.

## Scarlett microphone indicator

The combined aggregate exposed the Scarlett's physical input before the process-tap input, even though the aggregate description requested zero physical input channels. Its 74-frame input-side margin happened to match the Scarlett input metadata, which initially made the two look causally related. The output-only D10s later reported and imposed the same 74 frames.

The initial device-scoped experiment caused macOS to show the microphone-use indicator. This was a real input activation, not merely a misleading icon.

GlassEQ now configures `kAudioDevicePropertyIOProcStreamUsage` for its aggregate IOProc. On the Scarlett, the input usage mask is `[0, 1]`: the physical input stream is off and the process-tap stream is on. GlassEQ reads the property back and refuses to start unless Core Audio applied the requested mask.

Disabling the physical stream did not change the 4.500 ms latency. It removed the microphone indicator, retained 64-frame callbacks, and produced null data for the disabled physical-input buffer. The callback skips that buffer and reads the following tap stream.

An audible test also passed. Both test phrases reached the Scarlett output with the physical input disabled.

## Experiments that did not explain the result

Several plausible explanations turned out to be wrong:

- Disabling aggregate drift compensation did not change the original 43.500 ms result.
- The Scarlett's physical input explained the microphone indicator, but not the 74-frame scheduling term. The output-only D10s imposed the same term, and disabling the Scarlett input did not change latency.
- The sub-tap runtime latency property was absent or not writable.
- Adding 64 frames to the aggregate composition's sub-tap latency was retained in metadata but did not change callback timing.
- A negative sub-tap latency made the aggregate unusable. It exposed no valid latency metadata and delivered no callbacks.

The scope and format of the process tap were what mattered.

## Ad hoc builds can lose capture permission until relaunched

The first launch of the hybrid release produced one saturated sample, then complete silence, at the same time macOS displayed a new permission prompt. System Settings showed that the prompt was for System Audio Recording, not microphone access. GlassEQ was enabled there and was absent from the Microphone permission list.

The newly ad hoc-signed bundle had received permission while the process was already running. Its callbacks continued, but the process tap delivered silence. Relaunching the same build after the grant restored clean audio. The saturated sample did not cause the silence.

Development builds have a code-directory-hash designated requirement, so rebuilding an ad hoc app can make macOS treat it as a new capture identity. A stable Developer ID signature should avoid this per-build identity churn. During development, a new system-audio prompt means the running process must be relaunched before audio results are meaningful.

## System alerts need a separate low-latency path

The preference-based scheme in this section was the first working mitigation. The later two-tap experiment superseded it, but the intermediate result remains useful because it established how `systemsoundserverd`, direct I/O, and the Alert volume preference behave.

At 16 frames, a sound played by `systemsoundserverd` could open a second direct I/O context on the physical output. Some of those starts caused a Core Audio safety violation and a paired aggregate timestamp jump. The same registered alert was clean when GlassEQ excluded the daemon's Core Audio process object from its tap. Repeated tests then produced direct system-alert I/O with no aggregate overloads or timestamp discontinuities.

A later screenshot on the D10s advanced the input and output timestamp-jump counters together by one. The screenshot produced no notification sound, and a three-minute unified-log window contained no matching public Core Audio overload or safety-violation message. This still has the signature of one aggregate-timeline discontinuity rather than independent capture and playback faults, but its trigger remains unproven. It is a transient route event, separate from the steady safety offsets measured above.

Excluding the daemon means alerts no longer pass through the profile preamp. That is unsafe with a large negative preamp because a listener may compensate downstream, making an unprocessed notification much louder than the music.

macOS stores the user-facing Alert volume slider in the global `com.apple.sound.beep.volume` preference. A live experiment changed the value from `1.0` to `0.501187`, played the same alert, and observed `systemsoundserverd` use `user vol 0.501187` immediately. No daemon restart was required. The already-open System Settings pane also moved its Alert volume slider from 100 percent to about 31 percent. The slider uses a nonlinear perceptual mapping, while the preference and daemon log use the audio gain scalar. Restoring the preference to `1.0` updated both the next alert and the visible slider.

The experimental build applied the active profile's negative preamp to that Alert volume while the combined aggregate was running:

`adjusted alert volume = original alert volume * 10^(min(preamp dB, 0) / 20)`

Stereo profiles used the more negative channel preamp. Positive preamp never raised the alert volume. The original value was restored on bypass, backend changes, normal stop, sleep, and termination.

The adjustment had its own atomic restoration record. On launch, GlassEQ restored an interrupted session only when the current preference still matched a value GlassEQ wrote. While processing was active, GlassEQ checked the preference twice per second. A value other than the last compensated value had to remain stable for two checks before it became the user's new base volume, so GlassEQ did not fight an in-progress slider drag. GlassEQ then reapplied the current preamp from that base. Stopping restored the newest base rather than the value from before the manual change. If GlassEQ stopped before it observed a manual change, it left the different current value alone. A live owner process also prevented another GlassEQ process from taking over the same setting.

App Sandbox blocked real changes to the global preference unless the signed app had the shared-preference read-write exception for both `.GlobalPreferences` and `kCFPreferencesAnyApplication`. Granting only `.GlobalPreferences` was deceptive: Core Foundation updated its process-local cache and read back the adjusted value, but synchronization returned `false` and the stored preference stayed unchanged. A sandboxed probe with both domains successfully applied and restored a different value. The experimental build therefore required the complete entitlement pair. The final two-tap implementation removes both the preference writer and those exceptions.

This preference key is not a documented app-facing macOS API. The experimental implementation kept it isolated and verified every write by reading the value back. Removing it also removes that compatibility risk.

## Two device-scoped taps remove the preference workaround

The alert-volume experiment solved the immediate loudness mismatch, but it changed a global user preference and covered only sounds that honor `com.apple.sound.beep.volume`. The screenshot sound exposed that limitation.

A read-only Core Audio process trace showed that both the Settings "Boop" alert and the screenshot sound come from `systemsoundserverd`. They do not share the same upstream volume behavior:

- Boop responds to the macOS Alert volume slider.
- The screenshot sound does not respond to that slider.
- `Screen Capture.aif` is also intrinsically quieter than `Tink.aiff`: its measured peak was -13.89 dBFS rather than -8.77 dBFS, and its RMS level was -34.66 dBFS rather than -28.70 dBFS.

One global preference therefore cannot match every system sound to GlassEQ's gain. The daemon itself is the useful boundary.

GlassEQ now creates two private, muted, device-scoped, non-mixdown taps for the selected output stream:

| Tap | Included audio | Processing |
| --- | --- | --- |
| Main tap | Every process except GlassEQ and `systemsoundserverd` | Profile preamp and filters |
| System-sound tap | Only `systemsoundserverd` | Profile preamp only |

Both taps belong to the same private aggregate and arrive in the same IOProc callback. GlassEQ processes the main samples, adds the preamp-adjusted system-sound samples, applies the existing output fade, and writes the result to the physical output. The mix needs no ring buffer, extra callback, or additional scheduling quantum.

This keeps notifications out of the profile filters without allowing them to bypass the profile preamp. Muting the tap removes the daemon's dry system-sound output from the final mix, but it does not prevent `systemsoundserverd` from starting its own physical-output AudioUnit and I/O context. The source still has to render before Core Audio can supply samples to the tap.

The release test passed audibly for both Boop and screenshots. The macOS Alert preference remained at its restored user value, `0.6535`, after GlassEQ launched. The listener also reported that alerts were no longer drowned out in a setup with macOS output and Apple Music both at 100 percent and volume controlled on the amplifier.

The two-tap route did not eliminate every timestamp correction. A screenshot taken after several minutes without a system sound still produced a one-frame input jump and a matching one-frame output jump. Screenshots taken soon afterward did not.

A focused Core Audio trace caught the cold event. `systemsoundserverd` started a fresh D10s I/O context when it began rendering the screenshot sound. Core Audio then reported `SafetyViolationOccurred` against GlassEQ with an I/O buffer size of 16 frames, `lateness: 14`, and a safety-violation time gap of 0.000375 seconds. At 48 kHz, that 0.375 ms gap is about 18 frames and slightly exceeds one 16-frame callback budget. A warm system sound 17 seconds later started the same context without an overload.

This connects the paired one-frame correction to cold Core Audio graph startup, not accumulated clock drift. The tap removes the dry playback, but it cannot stop the source process from opening the physical-output graph it needs in order to render. The exact event produced a diagnostic correction; no audible crack was reported during that test.

### Topology hardening

The first implementation resolved the current Core Audio process object IDs when it built the taps. That leaves a daemon-restart risk because a new `systemsoundserverd` instance may receive a new process object.

macOS 26 adds `CATapDescription.isProcessRestoreEnabled`. Both taps now enable it, allowing Core Audio to restore matching processes by bundle ID when they restart.

A later cold launch exposed a related startup flaw. `systemsoundserverd` was running as a daemon but had not yet published a Core Audio process object, so resolving its transient object ID made the whole audio engine fail. macOS 26 also lets a tap description include or exclude `bundleIDs` directly. GlassEQ now names `systemsoundserverd` that way in both tap descriptions. The system-sound tap can therefore be created while the daemon is dormant, and Core Audio attaches the daemon when its audio process appears. GlassEQ still excludes its own live process object explicitly.

GlassEQ also reads the aggregate composition back before starting I/O. It requires exactly the two expected tap UIDs and their requested drift settings. The returned UID order determines the input channel offsets. If HAL returns the taps in the opposite order, GlassEQ follows that order. If a tap is missing, duplicated, unknown, or has the wrong drift setting, startup fails rather than applying the wrong processing to either stream.

A focused build disabled drift compensation only for the normally dormant system-sound tap while leaving the main tap unchanged. The same cold screenshot still produced one input jump and one output jump. Secondary-tap drift compensation is therefore not the cause of the re-anchor, and both taps retain high-quality drift compensation in the final configuration.

The final mix has one remaining gain-stage risk. Music processed by the main path can already approach full scale before a system sound is added. GlassEQ uses the same smooth saturation curve as the EQ path for samples that overload during this addition and increments the saturated-sample counter. This prevents hard clipping, but repeated saturation can still make a loud notification over loud music sound compressed. It needs deliberate soak testing with hot profiles and positive preamp values.

## Resulting hybrid architecture

The normal-rate fast path uses this design:

1. Find the default output and its preferred stereo pair.
2. Select the native mono or stereo hardware stream containing that pair.
3. Create a private muted main tap bound to the output UID and stream. Exclude GlassEQ itself and `systemsoundserverd`.
4. Create a second private muted tap for only `systemsoundserverd`, bound to the same output UID and stream.
5. Enable process restoration on both taps so Core Audio can follow daemon restarts by bundle ID.
6. Create one private aggregate containing both taps and the physical output.
7. Make the physical output the aggregate's main subdevice and retain high-quality drift compensation for both taps.
8. Read the composition back, validate both tap UIDs and drift settings, and derive their input channel offsets from HAL's returned order.
9. Create one IOProc for the aggregate.
10. Disable every aggregate physical-input stream, enable both process-tap streams, and verify the readback.
11. Apply the full profile to the main tap, apply only the active preamp to the system-sound tap, and mix them in the same callback.
12. Recreate both taps and the aggregate when the selected output UID or stream changes.

There is no application-owned audio queue, clock servo, resampler, or priming state on this path. GlassEQ requests 16 frames only from the private aggregate and does not tune the physical device.

Bluetooth routes at 24 kHz or below start on the separate-clock fallback:

1. Keep the muted process tap in a tap-only private aggregate.
2. Capture at the tap's rate and feed a preallocated stereo ring buffer.
3. Drive the physical output with a separate HAL callback at its device-owned rate and callback size.
4. Use the occupancy servo and realtime PCM conversion to bridge the two clock domains.
5. After the route settles, verify the physical clock slope and attempt promotion to the combined fast path.
6. Return to compatibility mode for the rest of that output generation if validation or a later paired discontinuity fails.

This retains the old complexity only as a transition and recovery path where the combined clock domain has been shown to fail audibly.

## Soak-test results so far

The release implementation has passed the edge cases exercised so far:

- D10s and Scarlett Solo
- Output-device switching
- Bluetooth switching
- Entering and leaving Teams headset mode without a relaunch
- Sleep and wake
- Notifications
- Repeated start and stop
- Verified 64-frame baseline runs on normal-rate routes
- Clean 32-frame and 16-frame Scarlett listening runs, including 16 frames without physical-device buffer tuning
- Clean 16-frame AirPods Pro playback with 0.667 ms tap-to-output scheduling
- Clean AirPods Pro headset-mode playback through the automatic separate-clock fallback
- No observed underruns or dropped input frames
- No microphone indicator with the physical-input stream disabled
- Roughly 1 to 2 percent CPU use in the release app
- Audible Boop and screenshot tests through the dedicated system-sound tap
- No change to the user's Alert volume preference after the two-tap build launched

The verified Scarlett latency results are 4.500 ms at 64 frames, 3.167 ms at 32 frames, and 2.500 ms at 16 frames. Normal 48 kHz AirPods playback measured 0.667 ms to the Bluetooth output timestamp at 16 frames. The unsettled headset interval uses the slower bridge by design; its diagnostic figure is bridge occupancy, not a directly comparable tap-to-output timestamp measurement. A promoted steady headset route returns to the aggregate measurement.

## Remaining constraints

The architecture is much simpler, but it is not universal:

- The fast path currently supports native mono and stereo hardware streams. A multichannel stream would require broader native-stream handling. Core Audio's tap mixdown is not an acceptable fallback because it restored 43.5 ms on the Scarlett.
- A device-scoped tap captures only the selected device and stream. Audio explicitly routed to another device, including a distinct system-alert output, is outside GlassEQ's path.
- Output switching requires rebuilding the muted tap after macOS reports the new route. No dry-audio leak has been observed, but handoff behavior remains part of soak testing.
- Virtual devices, multi-output devices, and unusual stream layouts need explicit hardware testing. GlassEQ fails closed if it cannot isolate the tap from physical inputs.
- The separate-clock headset fallback restores the ring buffer, servo, resampler, priming, and recovery machinery on that route. It also adds roughly 42.65 ms of buffered bridge time in the tested AirPods mode.
- The current fallback policy is intentionally narrow: Bluetooth transport at 24 kHz or below. Other devices that exhibit the same combined-timeline failure will need evidence-based classification.
- The dedicated system-sound path depends on macOS continuing to publish these sounds through `systemsoundserverd`. A future daemon split would need another classification rule.
- A cold `systemsoundserverd` graph start can still cause one paired one-frame timestamp correction at a 16-frame buffer. The captured event was a Core Audio safety violation during physical-output I/O startup, not a drift-compensation failure. Warm sounds did not reproduce it.
- System-sound handling is not yet equivalent in the separate-clock headset backend. That path still captures the full system mix through one global tap and applies the full profile.
- Adding system sounds after the main DSP can exhaust output headroom. The smooth limiter prevents hard clipping, but the saturation counter must remain part of soak testing.
- The second tap's effect on release CPU, safety offsets, and callback timing still needs a recorded before-and-after measurement. The initial listening test proves routing and gain behavior, not long-term timing stability.

## Architecture decision

The criticism of the original separate-clock design was legitimate. Its ring buffer, occupancy controller, servo, resampler, and recovery logic solve real clock-domain problems, but Core Audio can remove those problems when GlassEQ uses the right tap topology on a stable route.

The first aggregate experiment did not prove that a combined aggregate was inherently slow. It proved that a global or mixed-down tap carries a large latency budget into the aggregate.

For the normal-rate native mono and stereo routes tested here, the device-scoped combined aggregate is the preferred architecture. It is simpler than the reference design and reduces measured tap-to-output latency from 26.345 ms to 4.500 ms at 64 frames, 3.167 ms at 32 frames, and 2.500 ms at 16 frames on the Scarlett.

The dedicated `systemsoundserverd` tap closes the largest behavioral gap in that architecture. System sounds now share the aggregate clock and profile preamp without passing through the profile filters or requiring GlassEQ to edit the global Alert volume preference.

The 24 kHz AirPods headset transition is the counterexample. A combined aggregate created before HAL's timeline settles has periodic input and output timestamp jumps that remain audible even with clean application counters. The separate-clock design is slower but clean during that interval. Once the physical sample-time slope agrees with the advertised rate, the combined aggregate can take over again.

The resulting decision is hybrid rather than ideological: use the single-clock aggregate wherever it behaves correctly, and retain the application-managed bridge for low-rate Bluetooth transition and recovery where it has demonstrated a concrete advantage. This preserves the latency and simplicity breakthrough for ordinary playback without accepting broken conferencing audio.

## Adaptive callback-buffer policy

The 16-frame result is real, but it leaves only 0.333 ms between callbacks at 48 kHz. That is smaller than some steady-state delays inside Core Audio. One captured cold system-sound start faulted a `coreaudiod` aggregate-context thread for 0.392 ms while GlassEQ's client I/O thread was waiting. A 32-frame period is 0.667 ms and a 64-frame period is 1.333 ms.

A later run supplied stronger evidence that this is not limited to screenshots. Before a debugger was attached, the runtime probe ring contained 22 paired input/output discontinuity records. The final uncontaminated record advanced both sample timelines by 608 frames at 48 kHz, or 12.667 ms. Both sides delivered 16-frame callbacks, valid sample and host times, and a valid rate scalar of `1.0000057521651913`. Their host-interval errors were 12.664 ms. The same time window contained no public `coreaudiod` or `systemsoundserverd` overload, safety-violation, device-change, or route-change log. Records from sequence 23 onward were discarded because stopping the process in the debugger caused much larger artificial jumps.

GlassEQ therefore treats 16 frames as an optimistic starting point rather than a promise. Automatic mode stores the smallest callback size that has proved reliable for each route fingerprint:

`physical output UID + selected native output stream index + nominal sample rate`

A new fingerprint starts at 16 frames. One qualifying interruption records evidence but does not change the route. A second interruption within five minutes advances that fingerprint from 16 to 32, or from 32 to 64. The evidence window and learned value are persisted, so relaunching cannot either erase one half of a real failure burst or make a single event permanent. Existing Automatic records written by the earlier one-shot policy reset to 16 because they do not contain enough evidence to satisfy the new rule; explicit fixed-size choices remain intact. Changing the native stream or sample rate creates a separate record because the same device can behave differently in another format or transport mode.

The automatic policy does not learn from every diagnostic counter change. It requires all of the following:

- The aggregate has been running for a two-second settling period.
- No start, rebuild, output change, or sample-rate change is in progress.
- The route UID, native stream, and nominal rate still match the fingerprint.
- Both the input and output sample timelines jump in the same callback.
- Both timelines had at least eight consecutive callbacks with valid timestamps, nominal sample-time progression, host-time slope within the callback tolerance, and a sane rate scalar before the jump.

Once the safer aggregate has started successfully, GlassEQ posts a silent notification explaining that it increased this route's audio buffer. Opening the notification selects the Output pane. That pane exposes Automatic and fixed 16-, 32-, and 64-frame modes. A fixed choice disables learning for that route. Automatic also offers **Retry 16 frames**, which clears the learned rung for the current fingerprint without affecting other devices, streams, or rates.

Automatic learning is reversible. A settled aggregate run counts as clean after five uninterrupted minutes without a qualifying discontinuity. Three clean runs lower the persisted value by one rung and rebuild the route at that size for revalidation. Any qualifying interruption resets the clean-run count. A route learned at 64 therefore retries 32 before 16, and any new failure burst moves it back up through the same two-event rule.

Startup now includes a bounded topology warm-up. GlassEQ starts the aggregate muted, lets both tap inputs and the output IOProc run for 32 callbacks, and then fades processing in. The wait is capped at 100 ms so a disconnected route cannot stall startup indefinitely. This warms GlassEQ's own aggregate and callback storage, but it cannot force a dormant source such as `systemsoundserverd` to construct its separate physical-output graph. Arbitrary steady-state Core Audio stalls therefore remain possible, and the adaptive ladder is still required.

This changes the product meaning of the buffer setting. Automatic means “the lowest latency this exact route has demonstrated reliably,” not “always 16 frames.” The user may override that conclusion for experiments. GlassEQ requires a short failure burst before moving up and periodically retries lower rungs after clean use, so neither one cold-path event nor one bad session becomes a permanent verdict.

## Whole-bank transitions and the render watchdog

The aggregate graph no longer needs a rebuild when the profile topology changes. GlassEQ prepares a complete processor bank away from the realtime callback, warms it with live input, and crossfades it into the active bank over 10 ms. Biquad banks receive 20 ms of live history. A convolution bank receives 16,383 frames so every tap of its impulse history is valid before the blend begins.

This matters for more than cosmetic editing. Filter-count changes, channel-mode changes, bypass, and biquad-to-convolution changes can all replace the DSP bank without stopping Core Audio. The old bank continues producing output during warm-up. Only the newest pending edit survives, and retired banks are released outside the callback.

The first bypass test found a real lifecycle bug. Applying a bypassed bank while Music was playing left the output silent until Apple Music stopped and GlassEQ was disabled and re-enabled. After correcting the transition state, the same operation recovered normally and repeated tests no longer lost output.

A separate watchdog observes render progress without touching the callback. One three-second steady-state stall stops and rebuilds the engine once. A second stall within 60 seconds stops processing and restores direct system playback until the user retries. The manual fault-injection test reached the intended final state and reported that rendering had stalled again instead of entering a rebuild loop.

The deadline recovery policy handles shorter bursts. Three missed callbacks within one second trigger remediation. Automatic mode follows its persisted route-specific ladder. A fixed buffer first rebuilds at the user's chosen size, then temporarily climbs through 32 and 64 frames if bursts recur within 60 seconds. It does not overwrite the fixed preference. Another burst at 64 stops processing. This cannot guarantee continuity during arbitrary scheduler stalls, but it can recover from the shorter poisoned states observed during ordinary use.

## Programme-loudness-matched A/B comparison

Ordinary EQ bypass is a poor listening comparison. It removes the filters and often removes the profile preamp too, so the louder branch tends to sound better before the frequency response gets a fair hearing.

GlassEQ's A/B path renders two branches from the same input:

| Branch | Preamp | Filters |
| --- | --- | --- |
| EQ | Active profile preamp | Active biquads or response curve |
| Filters Off | Same linked or per-channel preamp | None |

The comparison is transient render state. It does not mutate or persist the profile. For convolution profiles, Filters Off removes the response curve and switches the reference processor back to the parametric path, but keeps the preamp and keeps bypass disabled.

Both branches run through BS.1770 K-weighting. The matcher stores thirty 100 ms energy segments, forms 400 ms gating blocks, and applies the same absolute and relative programme gate to both branches. Using a shared gate matters because independent gates could compare different passages of the song. The rolling history covers up to three seconds.

GlassEQ attenuates only the louder branch. It never boosts the quieter one, which preserves the headroom already available in the profile. Gain changes settle over 500 ms, while switching between EQ and Filters Off uses the same 10 ms smoothstep blend as other bank transitions. Leaving comparison first returns to the EQ branch, restores any temporary matching attenuation, and then returns to the saved active profile.

The first live attempt exposed a readiness bug: Matched never arrived even with music playing. After fixing publication of the realtime comparison snapshot, the match became ready, switching both ways worked, and returning to normal processing was clean. This confirmed the whole workflow with a real programme rather than only synthetic energy tests.

## Minimum-phase FIR without added tap-to-output latency

Response Curve profiles now compile frequency and gain points into a 16,384-tap minimum-phase impulse. The compiler uses log-frequency interpolation with linear dB gain, clamps below the first point and above the last point, constructs the even log-magnitude spectrum, performs the even-length cepstral lift, exponentiates the resulting complex log spectrum, and transforms it back into a causal impulse. The persisted source contains the curve points and a synthesis version, not the generated samples.

The realtime processor is a hybrid convolver:

- The first 512 taps run as a vectorized direct head and produce tap zero immediately.
- The remaining 15,872 taps form 62 partitions of 256 frames.
- Each partition uses a 512-point real transform.
- Tail work is spread across sample-frame progress and has a 16-frame guard before the inverse transform is due.
- All transform setups, storage, and Accelerate paths are allocated and prewarmed before the bank reaches the callback.

The scheduler uses absolute sample frames rather than callback count. That distinction is necessary because a 480-frame render callback can cross more than one internal 256-frame boundary. Random and deliberately hostile chunk sequences are compared continuously with direct convolution, including seams around taps 510 through 514 and every partition boundary.

Minimum phase does not make a 16,384-tap filter computationally cheap by itself. Partitioned convolution does. Minimum phase places useful impulse energy near time zero and avoids a linear-phase delay, while the direct head makes that first output available in the current callback. The tail is computed before its samples become due. The result adds DSP work but no fixed buffering and no tap-to-output scheduling term.

The live D10s run confirmed that distinction. A Response Curve at 48 kHz with 32-frame aggregate callbacks still reported 3.17 ms tap-to-output, exactly the existing safety-offset and callback model. There was no convolution latency surcharge.

The fixed tap count has a sample-rate trade-off:

| Sample rate | Bin spacing | Impulse support |
| ---: | ---: | ---: |
| 48 kHz | 2.93 Hz | 341 ms |
| 96 kHz | 5.86 Hz | 171 ms |
| 192 kHz | 11.72 Hz | 85 ms |

That is ample for smooth headphone correction but can become coarse for narrow low-frequency room correction at high sample rates. EqualizerAPO `GraphicEQ:` import is implemented and was exercised with a real Sennheiser HD 58X curve. Imported arbitrary impulse responses, starting with REW WAV exports, remain separate work because their supplied samples and phase are the source material and must be preserved.

## Torture testing and the actual realtime limit

A six-minute screen-recorded torture run drove the machine close to zero idle CPU. Slight crackles coincided with timestamp jumps. The same failure pattern occurred with a biquad profile and with convolution, which made it unlikely that the FIR engine itself was poisoning the route.

The useful diagnostic split is:

| Category | Meaning |
| --- | --- |
| Start starvation | The callback was already at least one full period late when GlassEQ entered it. |
| Render overrun | The callback started in time, but GlassEQ's DSP itself consumed at least one full callback period. |
| Paired discontinuity | HAL advanced both input and output timelines across a lost or skipped service interval. |

The categories can overlap. A late callback may still complete in time relative to its delayed start, and one starvation event may or may not force HAL to rebase both timelines.

The final 48 kHz D10s capture at 32 frames provided a clean example:

| Diagnostic | Result |
| --- | ---: |
| Render deadline misses | 2 |
| Start starvations | 2 |
| Render overruns | 0 |
| Paired discontinuities | 1 |
| Captured / played frames | 3,181,984 / 3,181,984 |
| Underrun / dropped / saturated samples | 0 / 0 / 0 |
| Capture / output callback peak | 32 / 32 frames |
| Callback start late, p99.99 / maximum | 116.00 / 10,237.08 us |
| FIR direct head, p99.99 / maximum | 5.00 / 6.75 us |
| FIR scheduled tail, p99.99 / maximum | 16.50 / 42.62 us |
| Total render, p99.99 / maximum | 23.25 / 75.08 us |
| Completion late, p99.99 / maximum | 0.25 / 9,645.50 us |
| Tail completion | 0 frames minimum slack, 0 misses |
| Input / output timestamp jumps | 1 / 1 |

A 32-frame callback at 48 kHz has a 666.67 us period. GlassEQ's worst measured render took 75.08 us, while the worst callback started 10.24 ms late. Both deadline misses were start starvation, only one became a paired HAL discontinuity, there were no render overruns, and the partitioned tail never missed its own due frame. macOS did not schedule GlassEQ in time. The FIR scheduler did not accumulate debt.

The longer torture run also produced operating-system absences on the order of 45 ms. No 16-, 32-, or 64-frame low-latency policy can hide that. Adding 128- or 256-frame rungs only to make an artificial CPU-apocalypse test look cleaner would add product complexity and latency during conditions where the rest of the machine was already visibly unusable.

### Output repair after a paired discontinuity

GlassEQ now remembers the last emitted sample for each channel. When both HAL timelines jump, it smooths from that sample into the resumed programme over 1.333 ms, scaled by sample rate. This de-clicker runs after the DSP, system-sound mix, and output fade. It adds no look-ahead or buffering.

The repair made the crackle less sharp in the manual test, but the interruption remains audible because the source contains an actual gap. A 1.333 ms blend can smooth the reconnection edge. It cannot recreate 10 or 45 ms of missing audio. Hiding those gaps would require carrying a reservoir at least as large as the scheduler stall, which would give back the low-latency result the aggregate architecture was built to obtain.

The current policy is therefore deliberate. Smooth the edge, classify the cause, recover through the buffer ladder when ordinary contention repeats, and stop safely when the operating system disappears for longer than a low-latency engine can cover.

## Current working conclusions

- A device-scoped, native-format, non-mixdown tap is the key to the low-latency aggregate. The first global-tap aggregate measured the wrong architecture.
- The fixed tap-to-output cost is the physical device's input and output safety offsets. USB's 74-frame input value is a driver constant GlassEQ cannot remove through supported aggregate controls.
- Sixteen-frame callbacks are real on the private aggregate, even when the physical device reports a much larger shared buffer. Automatic mode treats 16 as an experiment and learns 32 or 64 per device UID, native stream, and sample rate when steady-state evidence demands it.
- A single aggregate is the normal backend. The separate-clock bridge remains useful for the unsettled part of low-rate Bluetooth headset transitions and for rollback, not as the permanent headset renderer.
- System sounds need their own device-scoped tap so they keep the profile preamp without passing through the EQ filters. Cold `systemsoundserverd` graph startup can still provoke a HAL correction at 16 frames.
- Whole-bank transitions let profile topology change without rebuilding Core Audio. The watchdog and deadline ladder cover stalled or poisoned render sessions without rebuilding the graph.
- Programme-loudness A/B keeps the preamp, compares the same programme windows, and attenuates only the louder branch. It avoids the usual louder-is-better bypass bias.
- The 16,384-tap minimum-phase response curve adds compute but no fixed tap-to-output latency. The head is immediate and the partitioned tail completes against frame deadlines.
- Under severe contention, the measured failure was callback start starvation. Biquads and FIR failed in the same way, FIR render cost stayed far below one callback period, and the tail scheduler recorded no debt.
- No application can make a low-latency stream continuous when macOS fails to schedule it for 10 to 45 ms. GlassEQ can soften the return and recover, but actually concealing the hole requires latency paid in advance.
