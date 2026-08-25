# Where the 74-frame input safety offset comes from

This is a follow-up to [Aggregate clock experiment: findings](AggregateClockExperiment.md). It answers one question: can a sandboxed application remove the 74-frame input-scoped safety offset that the private combined aggregate inherits from a USB output device, while keeping the physical output as clock source and output target?

Measured on macOS 26.6 (build 25G81), Xcode 26.6 SDK, all devices at 48 kHz.

## Verdict

Effectively device-defined and unbeatable from an application. The value is published by Apple's USB audio driver stack, it is read-only in every scope, and the aggregate device copies it verbatim from whichever subdevice owns its timeline. Every aggregate composition key that touches latency is additive and clamps at zero, so nothing can subtract. The only supported way to change the number is to change which device supplies the aggregate's timebase, and the only device GlassEQ could supply is one it wrote itself, which means a driver.

I do not think the 74 frames are worth chasing. Reasoning is in the last section.

## What I measured

Two read-only probes plus a private-aggregate matrix. No taps were created, no IO was started, and no property on any physical device was written. Every aggregate was private and destroyed immediately. Source is in the appendix.

### Physical devices on this machine

| Device | Transport | In streams | Out streams | Safety in | Safety out | Latency in | Latency out | ZTS period |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Topping D10s | usb | 0 | 1 | 74 | 14 | 74 | 14 | 12000 |
| Scarlett Solo | usb | 1 | 1 | 74 | 14 | 74 | 14 | 12000 |
| ThinkPad Dock (engine 1) | usb | 1 | 0 | 74 | 50 | 74 | 50 | 12000 |
| ThinkPad Dock (engine 2) | usb | 0 | 1 | 74 | 50 | 74 | 50 | 12000 |
| MacBook Pro Speakers | bltn | 0 | 1 | 36 | 48 | 21 | 60 | 15840 |
| MacBook Pro Microphone | bltn | 1 | 0 | 36 | 24 | 14 | 1 | 15840 |
| LEN Y27q-20 | dprt | 0 | 1 | 0 | 320 | 0 | 88 | 12288 |
| iPhone Microphone | ccwd | 1 | 0 | 100 | 0 | 6000 | 0 | 12480 |
| Teams loopback | virt | 1 | 1 | 0 | 0 | 0 | 0 | 40960 |
| rekordbox Aggregate | grup | 0 | 1 | 36 | 48 | 21 | 60 | 0 |

Three facts fall out of this table.

Every device publishes a safety offset in both scopes no matter what streams it has. Four of the devices listed are one-directional, and all four still answer the opposite scope. `kAudioDevicePropertySafetyOffset` is absent in global scope and read-only in input and output scope on every device.

All three USB devices report exactly 74 frames of input safety, while their output safety differs (14, 14, 50, 50). The input number does not vary with the endpoint, so it is a constant of the USB audio driver, not a measurement of any hardware path. On USB the driver also sets `kAudioDevicePropertyLatency` equal to the safety offset in both directions. The built-in and DisplayPort devices keep the two properties distinct, which is why GlassEQ's earlier speaker measurement showed 21 and 60 frames of latency alongside 36 and 48 frames of safety.

The `rekordbox Aggregate Device` is the accidental control experiment. Its composition names `BuiltInSpeakerDevice` as `master`, and it republishes the speakers' input safety (36), output safety (48), device latency (21 and 60), and even the speakers' 690-frame output stream latency. Its other subdevice is a USB controller, which would contribute 74 if anything about the USB device leaked in. Nothing does. The aggregate is a mirror of its main subdevice.

### The aggregate mirror rule

One subdevice, no taps, IO never started. Requested value on the left, aggregate readback on the right.

| Composition | Aggregate safety in | Aggregate safety out |
| --- | ---: | ---: |
| `[Scarlett]` master=Scarlett | 74 | 14 |
| `[Scarlett]` no `master` key | 74 | 14 |
| `[Scarlett]` `channels-in: 0` | 74 | 14 |
| `[Dock engine 2]` | 74 | 50 |
| `[Speakers]` | 36 | 48 |
| `[Built-in mic]` | 36 | 24 |
| `[DisplayPort]` | 0 | 320 |
| `[Teams loopback]` | 0 | 0 |
| no subdevices at all | 0 | 0 |

Six devices, six exact matches in both scopes. The aggregate also mirrors the main subdevice's `kAudioDevicePropertyLatency`. Note that the aggregate's own zero-timestamp period is 0, on both my probe aggregates and rekordbox's. An aggregate has no ring buffer and no timeline of its own, so it has nothing to declare and nothing to compute a margin from. It borrows both from the subdevice that owns its timebase.

`channels-in: 0` is worth calling out. HAL accepts the key, then overrides it: the composition readback comes back as `channels-in=2`. That is the mechanism behind the Scarlett microphone channels appearing in the aggregate despite the request in `SystemTapAudioEngine.createCombinedAggregateDevice`. `IsStackedKey: 1` does suppress the phantom input channels (input channel count goes to 0), but the input safety offset stays at 74, so it buys nothing for latency.

### Adding subdevices only makes it worse

| Composition | master | Safety in | Safety out |
| --- | --- | ---: | ---: |
| `[Scarlett, Speakers]` | Scarlett | 74 | 94 |
| `[Scarlett, Speakers]` | Speakers | 127 | 48 |
| `[Speakers, Scarlett]` | Speakers | 127 | 48 |
| `[Scarlett, DisplayPort]` | Scarlett | 74 | 394 |
| `[Scarlett, DisplayPort]` | DisplayPort | 148 | 320 |

The scope owned by the main subdevice keeps the main subdevice's value. The other scope goes up, sometimes a lot. Adding the DisplayPort monitor to a Scarlett-clocked aggregate takes output safety from 14 to 394 frames. Nothing here ever produced a number below the main subdevice's own value, and list order makes no difference (rows two and three are the same composition in the opposite order).

The practical consequence: you cannot dilute the 74 by adding a device with a lower input safety offset. There is no configuration in which the Scarlett or the D10s is present and the aggregate's input safety drops below 74.

### The clock device makes it worse too

`kAudioAggregateDeviceClockDeviceKey` with one of this machine's two TimeSync clock devices, on an otherwise identical single-Scarlett aggregate:

| Composition | Safety in | Safety out | Latency in | Latency out |
| --- | ---: | ---: | ---: | ---: |
| `[Scarlett]` master=Scarlett | 74 | 14 | 74 | 14 |
| `[Scarlett]` master=Scarlett, clock=TimeSync | 148 | 28 | 0 | 0 |
| `[Scarlett]` clock=TimeSync, no master | 148 | 28 | 0 | 0 |

Both offsets double and the reported latency collapses to zero. This is what the header warns about. `kAudioAggregateDevicePropertyClockDevice` says "Setting this property will enable drift correction for all subdevices in the aggregate device" (`AudioHardware.h:1673`). Once the physical device is no longer the timebase, it is a drift-corrected member and pays double its own margin, plus a resampler on the output path.

There is also a structural reason a clock device can never help. In AudioDriverKit, `IOUserAudioDevice` is a subclass of `IOUserAudioClockDevice` (`IOUserAudioDevice.iig:51`). The clock base class owns `SetZeroTimeStampPeriod`, `SetInputLatency`, `SetOutputLatency`, `SetClockDomain`, `SetClockAlgorithm` and `SetClockIsStable`. The safety offset setters, `SetInputSafetyOffset` and `SetOutputSafetyOffset`, exist only on the device subclass (`IOUserAudioDevice.iig:401,434`). A clock device has no safety offset to donate. Timebase and IO margin are separate concepts in Apple's own driver model, so separating the clock declaration from the main subdevice declaration cannot move the IO margin.

### A device-scoped tap resolves to its backing device

The newer `AudioHardwareAggregateDevice` API exposes `setClockSource(_:)` with an `AudioHardwareObject`, and Apple documents the corresponding `clockSource` as a device, clock, or tap. That is a real supported degree of freedom which the first investigation missed.

`GlassEQDiagnostics --clock-source-probe` tested it on both the Scarlett and D10s. Each probe used one device-and-stream-scoped, non-mixdown tap and the physical USB output. The live cells briefly started silent IO and disabled the physical input stream for their IOProc.

| Construction | Requested source | Published source | Safety in | Safety out |
| --- | --- | --- | ---: | ---: |
| Physical output plus tap | Physical device | Physical device | 74 | 14 |
| Physical output plus tap | Tap, before IO | Physical device | 74 | 14 |
| Physical output plus tap | Tap, during IO | Physical device | 74 | 14 |
| Tap first, physical output added later | Tap | Physical device | 74 | 14 |
| Tap UID stored as aggregate `master` | Tap | Physical device | 74 | 14 |
| Tap only | Tap | None | 74 | 14 |

The `master` composition is the most revealing case. HAL accepts and round-trips the tap UID, but `clockSource` still reports the physical device that backs the device-scoped tap, including while IO is running. A device-scoped tap therefore does not supply an independent timeline on either tested USB device. Its aggregate inherits the backing device's `74 / 14` margins even when the aggregate has no physical subdevice.

There are two tap object identities during live IO. Passing the original `AudioHardwareTap` to `setClockSource(_:)` returns successfully but does not change `clockSource`. The aggregate also publishes a distinct object through `activeSubtaps`; passing that object is rejected with `kAudioHardwareBadObjectError` (`'!obj'`). The active-subtap list was nonempty during these attempts, so the negative result is not explained by a dormant tap.

The explicit-clock control was unavailable. Calling `AudioHardwareDevice.clock` on both USB devices returned Core Audio's `clock not found` error, so neither exposes a separate `AudioHardwareClock` object to select. The system TimeSync objects remain the only explicit clock objects tested here, and those doubled the margins.

### The latency keys are additive and clamp at zero

`kAudioSubDeviceExtraInputLatencyKey` ("latency-in") on the Scarlett subdevice. This turned out to be the only key that moves the number at all, and it moves it the wrong way.

| latency-in | Aggregate safety in |
| ---: | ---: |
| -1000 | 74 |
| -148 | 74 |
| -74 | 74 |
| -74.0 (Float64) | 74 |
| -14 | 74 |
| -1 | 74 |
| 0 | 74 |
| +1 | 75 |
| +14 | 88 |
| +74 | 148 |
| +1000 | 1074 |

`latency-out` behaves the same way: -14 leaves output safety at 14, +1 gives 15, +100 gives 114.

So the sub-device extra latency lands on the aggregate's **safety offset**, not on its reported latency, which explains why earlier experiments looked like the metadata was being ignored. It was not ignored. The negative side is clamped at zero, and the clamp is exact: -1 does nothing, +1 works. Passing the value as a Float64 rather than an integer changes nothing, so it is not a signedness accident in how CFNumber is read.

The header wording matches. `kAudioSubDeviceExtraInputLatencyKey` says "the total number of frames of additional latency that will be **added** to the input side" (`AudioHardware.h:1783`). The runtime property `kAudioSubDevicePropertyExtraLatency` is documented more loosely as "a Float64 indicating the number of sample frames to add to or subtract from the latency compensation" (`AudioHardware.h:1826`), so I checked whether the runtime object accepts what the composition key refuses. It does not, because the object is not reachable: `kAudioAggregateDevicePropertyActiveSubDeviceList` returns objects whose `kAudioObjectPropertyClass` is `'adev'`, the real device, not `'asub'`. Setting `'xltc'` on it returns `kAudioHardwareUnknownPropertyError` (`'who?'`) in global, input and output scope. There is no AudioSubDevice instance for a client to talk to.

Writing `kAudioDevicePropertySafetyOffset` on the aggregate returns `kAudioHardwareIllegalOperationError` (`'nope'`).

### Everything else that does nothing

Aggregate buffer frame size at 16, 512 and 4096 frames: safety offsets unchanged at 74 and 14 in all three cases. Confirms the earlier finding from the running app. The aggregate's buffer frame size range is 15 to 4096, which is where the 16-frame floor comes from.

While chasing composition keys I found five undocumented ones in the HAL's string table, three of them next to `HALS_MetaDeviceDescription.cpp` and two next to `HALS_MetaSubTap.cpp`: `LDCM`, `isolated use case`, `dsp input settings override`, `don't pad` and `drift algorithm`. The last two show up in rekordbox's real aggregate composition, so third-party tools do carry them. HAL accepts all five and round-trips them in the composition readback. None of them changed the safety offsets at any value I tried. They are private, undocumented and unsupported, and I would not ship any of them.

## Answers to the ten questions

**1. What does an input-scoped safety offset mean on an output-only device?** It is a property of the device object, not of its stream topology. The driver sets it unconditionally for both directions. `IOUserAudioDevice::SetInputSafetyOffset` takes a plain `uint32_t` and is documented as "the number for frames behind the current hardware position that is safe to do IO" (`IOUserAudioDevice.iig:386`). Nothing in that contract asks the driver whether it has input streams. Apple's USB audio driver publishes 74 for every engine it creates, and my three USB devices confirm it, two of which are output-only.

**2. Which layer supplies it?** The device driver. On this machine USB audio is served by `/System/Library/Audio/Plug-Ins/HAL/usbaudiodxpc.driver`, an AudioServerPlugIn matching `AppleUSBAudioControlNub` and talking to the `com.apple.usbaudiod` Mach service, with `com.apple.driver.AppleUSBAudio` (850.5) loaded in the kernel. The HAL republishes the value. The aggregate plug-in copies it from the timebase subdevice. Nothing in the chain is client-writable.

**3. Why does the aggregate inherit it?** Because the aggregate has no timeline of its own. Its zero-timestamp period is 0, it has no ring buffer, and the host drives IO from `GetZeroTimeStamp()` on the device that owns the timebase (`AudioServerPlugIn.h:80`). Both of its safe-to-read and safe-to-write margins therefore come from that device. Verified against six devices with pairwise-distinct values, and against a third-party aggregate that mirrors the built-in speakers down to the 690-frame stream latency. The process taps do not lower this. They can only raise it, which is exactly what the global and mixdown taps did when they pushed both scopes to 1024 frames.

**4. Is there a topology that keeps the physical output as clock and output but avoids its input safety offset?** No. Single-subdevice aggregates mirror. Multi-subdevice aggregates never go below the main subdevice's value in its own scope, and raise the other one. A clock device doubles both. The extra-latency keys clamp at zero. I could not construct a composition that reports less than 74 with the Scarlett in it.

**5. Semantics of the individual properties.** `kAudioDevicePropertySafetyOffset` ('saft') is per-scope, driver-declared, read-only, and it is the value that governs the aggregate's IO cycle. `kAudioDevicePropertyLatency` ('ltnc') is separate and, as GlassEQ already measured, is not added to the tap-to-output timestamp interval. `kAudioDevicePropertyZeroTimeStampPeriod` ('ring') is declared in `AudioServerPlugIn.h`, not in the client umbrella header, with a documented minimum of 10923 frames; it sets how often the driver anchors sample time to host time and has nothing to do with IO margin. `kAudioDevicePropertyClockDomain` is decorative here: the value on this machine is `'main'` (1835100526) for the Scarlett, the monitor, the built-in devices and the rekordbox aggregate alike, and 0 for the D10s. `AudioHardwareAggregateDevice.setClockSource(_:)` accepts a device, clock, or tap, but a device-scoped tap resolves to its backing device in this topology. `kAudioAggregateDeviceClockDeviceKey` selects an explicit clock object and forces drift correction on everything. `kAudioAggregateDevicePropertyFullSubDeviceList` order controls stream order only; flipping it left the offsets identical. `kAudioAggregateDeviceTapAutoStartKey` gates when `AudioDeviceStart` returns and does not touch the offsets. Tap ordering determines input channel offsets, which GlassEQ already reads back from the composition. `CATapDescription` scoping is the one lever that genuinely matters, and GlassEQ is already on its fastest setting: a device and stream scoped tap with `isMixdown` false.

**6. Can the aggregate use the physical output clock without naming the whole device as `master`?** It can name the device-scoped tap instead, but this changes only the composition string. `clockSource` still resolves to the physical device and the offsets stay at 74 and 14. A separate `AudioHardwareClock` was not available from either tested USB device. Handing the timebase to a TimeSync clock doubled the physical device's offsets.

**7. Is mutability controlled by the device plug-in?** Yes. `AudioObjectIsPropertySettable` returns false for `kAudioDevicePropertySafetyOffset` on every device here, and setting it on an aggregate returns `'nope'`. The only code that can call `SetInputSafetyOffset` is the driver that owns the device.

**8. Untested supported mechanisms?** The tap clock source was the missing supported mechanism. It is now tested and leaves the offsets unchanged. The two undocumented sub-device keys and three undocumented aggregate keys are inert for this purpose, and I would not ship them anyway. `latency-in` is real and supported, but it only adds.

**9. Would separating clock declaration from main subdevice help?** No. A device-scoped tap still resolves to the backing physical device and reports 74 and 14. A TimeSync clock produces 148 and 28 because it makes the physical device a drift-corrected member.

**10. If it cannot be removed, where is the limit?** In `AppleUSBAudio` and its `usbaudiodxpc` AudioServerPlugIn. The value is a driver-family constant of 74 frames applied to the input direction of every USB audio engine regardless of topology. GlassEQ pays it because the aggregate's timeline is that device's timeline. A route whose driver declares a smaller value already costs less, which is why the DisplayPort output measured an input age of 15.6 frames against its declared input safety of 0.

## The tap-only experiment

The device-scoped, non-mixdown tap in a tap-only private aggregate reported the same 74-frame input and 14-frame output safety offsets on both the Scarlett and D10s. It published no clock source, even during a short IO run, but retained the backing device's margins. This nails down the mechanism: the safety offsets travel with the device-scoped tap, not merely with the physical device's membership in the aggregate.

Two smaller cells if you are in there anyway. Confirm that positive `kAudioSubTapExtraInputLatencyKey` raises the aggregate's input safety offset the way the sub-device key does; the earlier test only checked callback timing, and the sub-device key taught us that the value lands on the safety offset rather than the latency. And check whether 74 is a frame count or a fixed time by reading a USB device's input safety offset at 44.1 and 96 kHz. If it scales, it is roughly 1.54 ms of driver policy; if it stays 74, it is a raw frame constant. That one does require changing the device's nominal rate, so do it on a device nothing else is using.

## Risks, if someone tries anyway

The only remaining lever is a virtual device or custom driver, and it fails GlassEQ's constraints on its own terms. A driver's device would become the aggregate's main subdevice, which means it would supply the timeline, which means the physical output becomes a drift-corrected member at double its own safety offset plus a resampler, exactly as the clock device test showed. That is a second clock domain wearing a disguise, and it is slower than what GlassEQ has today. It also brings a system extension, user approval, an installer, and the whole class of failures GlassEQ avoids by owning nothing outside its own process. I would not present that as an app-level fix, because it is not one.

The supported knobs carry their own risks worth recording. `stacked` changes what output streams mean and is untested with taps. The private composition keys are undocumented and could change or start being rejected in any macOS update. Positive `latency-in` is safe and supported, but it buys tap-read slack, not deadline slack, so it will not help with the lateness failures behind the adaptive buffer ladder. The observed `SafetyViolationOccurred` with `lateness: 14` was the client thread missing its deadline, and moving the tap read point earlier does not extend that deadline.

## Recommendation

Leave it. Here is the arithmetic I would weigh it against.

The prize is 74 frames, 1.542 ms at 48 kHz, taking the USB routes from 120 frames to 46. Against that, the adaptive ladder's full 16-to-64-frame span changes the callback contribution by 96 frames. The buffer policy already accepts a larger latency range for reliability and tunes it per route. The observed timeline disturbances are larger still. The uncontaminated probe record advanced both timelines by 608 frames in one callback, which is 12.667 ms, roughly eight times the prize.

There is also no path to collect it. Not "no path we have found yet", but no path that survives the constraint list: every supported mechanism either mirrors the driver's value, raises it, or clamps at zero, and the unsupported ones do nothing. The only thing that would work is a driver, which trades 1.542 ms for a second clock domain, a resampler on the output, and a system extension.

I would close this line of investigation and record the model instead. GlassEQ's tap-to-output latency is

    input safety offset + one callback + output safety offset + one callback

where both safety offsets belong to the physical output device and are not negotiable. GlassEQ controls exactly one of those four terms, the callback size, and the adaptive policy already tunes it as far down as each route tolerates. That is the whole design space.

## Appendix: reproducing the measurements

The original aggregate-metadata probes are read-only apart from creating and destroying private aggregates. The clock-source probe additionally starts short silent IO cycles and disables physical input streams for combined-aggregate IOProcs. Sketch of the original aggregate matrix:

```swift
func probe(_ label: String, _ subDeviceExtras: [String: Any] = [:], clock: String? = nil) {
    var description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: "com.glasseq.probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceNameKey: "GlassEQ Probe",
        kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: outputUID,
             kAudioSubDeviceDriftCompensationKey: 0].merging(subDeviceExtras) { _, b in b }
        ]
    ]
    if let clock { description[kAudioAggregateDeviceClockDeviceKey] = clock }

    var deviceID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID) == noErr else { return }
    defer { AudioHardwareDestroyAggregateDevice(deviceID) }

    // Poll kAudioDevicePropertyDeviceIsAlive before reading, then read
    // kAudioDevicePropertySafetyOffset and kAudioDevicePropertyLatency in
    // kAudioObjectPropertyScopeInput and kAudioObjectPropertyScopeOutput.
    // kAudioAggregateDevicePropertyComposition shows what HAL kept or overrode.
}
```

`kAudioDevicePropertyZeroTimeStampPeriod` is declared in `AudioServerPlugIn.h`, which the CoreAudio umbrella header does not include, so Swift needs the raw selector `0x72696E67` to read it from a client.

## Primary sources

SDK headers, `MacOSX26.5.sdk` under Xcode 26.6:

- `CoreAudio/AudioHardwareBase.h:705,746` safety offset semantics and the `'saft'` selector; `:666` clock domain; `:820-828` AudioClockDevice properties.
- `CoreAudio/AudioHardware.h:1586-1602` `master` and `clock` composition keys; `:1655-1695` aggregate properties, including the drift-correction warning on `kAudioAggregateDevicePropertyClockDevice`; `:1783-1798` sub-device extra latency keys; `:1826-1842` sub-device runtime properties; `:1869-1928` sub-tap keys and properties; `:1635-1645` `tapautostart`.
- `CoreAudio/AudioServerPlugIn.h:80-82` the host drives timing from `GetZeroTimeStamp()`; `:432-449` `kAudioDevicePropertyZeroTimeStampPeriod`, `kAudioDevicePropertyClockAlgorithm`, `kAudioDevicePropertyClockIsStable`.
- `CoreAudio/CATapDescription.h` device and stream scoping, `mixdown`, and the macOS 26 additions `bundleIDs` and `processRestoreEnabled`.
- `CoreAudio/AudioHardwareTapping.h` tap creation, macOS 14.2.
- [`AudioHardwareAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice), including `clockSource` and `setClockSource(_:)`, macOS 26.
- [`AudioHardwareDevice.clock`](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice/clock), which returned `clock not found` on the Scarlett and D10s.

DriverKit SDK, `AudioDriverKit.framework`:

- `IOUserAudioDevice.iig:51` `IOUserAudioDevice` is a subclass of `IOUserAudioClockDevice`; `:386-449` `SetInputSafetyOffset` and `SetOutputSafetyOffset`.
- `IOUserAudioClockDevice.iig` `SetZeroTimeStampPeriod`, `SetInputLatency`, `SetOutputLatency`, `SetClockDomain`, `SetClockAlgorithm`, `SetClockIsStable`, and no safety offset.

System:

- `/System/Library/Audio/Plug-Ins/HAL/usbaudiodxpc.driver/Contents/Info.plist`, `AudioServerPlugIn_LoadingConditions` matching `AppleUSBAudioControlNub`, `AudioServerPlugIn_MachServices` naming `com.apple.usbaudiod`.
- `kmutil showloaded`, `com.apple.driver.AppleUSBAudio` 850.5.

The five undocumented composition keys came from the HAL string table in the dyld shared cache, adjacent to `HALS_MetaDeviceDescription.cpp` and `HALS_MetaSubTap.cpp`. That is inference from a closed binary, not documentation, and all five are inert here in any case.
