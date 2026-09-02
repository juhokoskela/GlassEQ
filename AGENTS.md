# GlassEQ Engineering Guide

This file records the stable constraints and engineering standards for work in this repository. It is intentionally not an implementation guide. Keep detailed runtime behavior in `Docs/Architecture.md`, experimental evidence in `Docs/AggregateClockExperiment.md`, and straightforward behavior in the code and tests.

## Product In A Nutshell

GlassEQ is a native, sandboxed, system-wide equalizer for macOS 26 and later. It follows the output selected by macOS, captures that output with Core Audio process taps, applies EQ in real time, and writes the result to the same physical device.

The product deliberately avoids virtual audio devices, drivers, system extensions, and manual output routing. Audio and profiles remain local. GlassEQ does not record the microphone, provide per-application routing, or send telemetry.

The main product is a lightweight menu bar audio engine. Its SwiftUI settings editor runs in a separate bundled helper so the always-on process does not retain the UI's memory footprint.

Apple Silicon is the supported architecture today. Intel support may be added after explicit build and hardware validation. Do not add compatibility branches for older macOS releases; the product depends on the macOS 26 platform and UI.

## Engineering Priorities

Make trade-offs in this order:

1. Audio correctness and safe restoration of normal system playback.
2. Realtime safety and predictable latency.
3. Security and privacy.
4. Readability and long-term maintainability.
5. Measured CPU and memory efficiency.
6. Feature breadth.

Prefer the smallest design that preserves these properties. Complexity is acceptable when it buys a measured product benefit or enforces a necessary invariant. Do not retain obsolete compatibility machinery, add abstractions for hypothetical requirements, or hide unclear behavior behind defensive fallbacks.

This is a permanently open-source project. Code should be reviewable by someone who did not participate in its original design. Use clear ownership, explicit state, accurate names, and narrow responsibilities. Do not split code merely to reduce line counts, but do split it when doing so creates an honest ownership boundary.

## Repository Map

- `Sources/GlassEQCore`: profile models, persistence, filter design, DSP, convolution, and realtime bank transitions.
- `Sources/GlassEQAudio`: Core Audio ownership, device discovery, taps, aggregate devices, render callbacks, fallback clock bridging, and diagnostics.
- `Sources/GlassEQApp`: menu bar application, lifecycle coordination, policy, and the main side of Settings IPC.
- `Sources/GlassEQSettingsIPC`: bounded messages shared by the app and Settings helper.
- `Sources/GlassEQProfileImport`: AutoEq catalogue access, WAV impulse-response decoding, and file import loading shared by the settings UI.
- `Sources/GlassEQSettingsUI`: reusable SwiftUI settings and import UI.
- `Sources/GlassEQSettings`: bundled Settings helper lifecycle.
- `Sources/GlassEQDiagnostics`: command-line hardware probes and release DSP benchmarks.
- `Tests`: behavior and regression tests organized by the corresponding source module.
- `Docs`: architecture, distribution, release notes, and the aggregate-clock experimental workbook.

Respect these module boundaries. In particular, UI code must not own audio resources, and the realtime path must not depend on SwiftUI or application state.

## Core Audio And DSP Invariants

- macOS owns output selection. GlassEQ observes the default route and follows it; it does not present a competing physical-output selector.
- Normal-rate routes use one private aggregate joining a device-scoped process tap to the physical output. The physical device remains the timebase.
- The separate-clock backend is a narrow compatibility path for unsettled low-rate routes and failed aggregate qualification. It is not a second general-purpose architecture.
- Disable and verify all physical input streams before starting output. After tap attachment, enable only the process-tap input streams. If the microphone path cannot be isolated, startup must fail safely.
- A failed start, rebuild, watchdog recovery, or teardown must return the user to normal dry system playback. Never leave another process muted behind a tap that GlassEQ is not reading.
- Do not mutate shared physical-device settings when a private aggregate setting will do. Any unavoidable shared-device mutation needs explicit ownership, persistence, restoration, and crash recovery.
- Treat callback size as variable input. Scheduling and buffering must be based on frames and deadlines, not assumptions about callback count.
- Build, validate, and prewarm complete DSP banks outside the render callback. Publish them as ready-to-render state, transition them without a discontinuity, and reclaim retired state outside the callback.
- Biquad and convolution renderers obey the same bank-transition and failure contracts. Convolution may consume more work, but it must not silently add fixed tap-to-output buffering.
- Recovery may temporarily choose safer runtime behavior, but must not silently overwrite an explicit user preference.
- Core Audio behavior is hardware and OS dependent. Separate observed facts from hypotheses, and preserve uncertainty when an experiment has not isolated the mechanism.

Read `Docs/Architecture.md` before changing audio ownership, routing, clocks, buffer policy, DSP publication, Settings isolation, or persistence. Read the relevant section of `Docs/AggregateClockExperiment.md` before revisiting a measured Core Audio workaround.

## Realtime Code

The render callback must not:

- Allocate or release heap-owned state.
- Acquire a mutex or wait on another thread.
- Touch disk, preferences, files, network resources, or IPC.
- Log, format strings, parse data, or report directly to UI state.
- Use Combine, dispatch synchronous work, or enter an actor.
- Invoke code that may lazily initialize an unprepared subsystem.

Preallocate mutable storage, precompute coefficients and transforms, and exercise third-party or system DSP paths before publication. Bound every buffer operation by the formats and capacities validated during setup. Do not let callback-scoped pointers or borrowed `AudioBufferList` storage escape their lifetime.

Use atomics only for small realtime state and counters. Make the ordering and lifetime invariant understandable at the point of use. Prefer a simpler ownership handoff over an intricate lock-free structure. Release Swift objects, FFT setups, and other owned resources on a non-realtime thread.

Instrumentation must be bounded, preallocated, and cheap enough to leave enabled. Publish snapshots outside the callback. A diagnostic that changes the scheduling behavior it measures is a bug.

## Swift 6 Style

- Keep strict concurrency checking enabled. Fix isolation and ownership instead of silencing diagnostics.
- Prefer value types and immutable prepared state. Use reference types where identity or lifecycle ownership is the point.
- Prefer concrete types. Introduce a protocol only for a real substitution boundary, and keep it small near the consumer when practical.
- Model lifecycle and recovery states with enums and explicit transitions rather than related Boolean flags.
- Put UI-facing mutable state on `@MainActor`. Keep audio control and realtime state outside the main actor.
- Use structured concurrency for asynchronous work with clear ownership and cancellation. Do not create unowned background tasks.
- Keep mutex critical sections short. Never hold a lock across a Core Audio call, callback registration, sleep, poll, or blocking wait without a documented and measured reason.
- Use `throws` and domain-specific errors for recoverable failures. Add context when it helps diagnosis and preserve the underlying error when callers depend on its identity.
- Prefer `guard` for preconditions and early failure. Avoid deeply nested state-machine code.
- Avoid force unwraps and force casts except for static invariants that are both local and obvious.
- Treat `@unchecked Sendable`, `nonisolated(unsafe)`, raw pointers, and manual memory management as audited boundaries. Use them only when the system API requires them and document the invariant, ownership, and lifetime.
- Rely on names and types for straightforward behavior. Comments should explain non-obvious invariants, Core Audio contracts, concurrency assumptions, and measured interoperability constraints.
- Follow existing formatting and naming. Do not introduce a second style or a general utility namespace.

## Security And Privacy

- Preserve the App Sandbox and least-privilege entitlements. An entitlement change is a security-sensitive product change, not a build workaround.
- System audio capture is the only audio privacy permission. Never enable, read, or retain physical microphone input.
- Treat the Settings helper and its IPC session as a trust boundary. Preserve bundle containment, signing-identifier, signing-team, token, payload-size, and lifecycle checks.
- Treat imported files, pasted settings, persisted stores, IPC payloads, update metadata, and remote AutoEq data as untrusted input. Validate structure and bounds before large allocation, DSP compilation, or persistence.
- File access must follow explicit user selection and sandbox rules. Do not broaden filesystem access to make an import path convenient.
- Keep audio, profiles, device details, and diagnostics local. Do not add analytics, telemetry, crash uploading, or cloud sync without an explicit product decision.
- Any updater must verify both Apple code signing and the update framework's archive or feed signatures. Keep signing keys out of the repository and release artifacts.
- Never weaken helper validation, updater verification, or sandboxing because debug and packaged builds behave differently. Fix and test the packaging boundary.

## Change Discipline

- Inspect the relevant implementation, tests, and documentation before designing a change.
- Make the smallest coherent change that fixes the cause. Avoid opportunistic refactors and unrelated cleanup.
- Preserve behavior unless changing it is part of the request. Delete code made obsolete by the new behavior.
- Do not add configuration, a fallback, or a recovery path until the state it handles has been observed or established as possible.
- Keep the worktree's unrelated and untracked files untouched. Stage explicit paths and review the diff before committing.
- Use Conventional Commits for commits. Keep them cohesive and independently reviewable.
- Update `Docs/Architecture.md` when a durable ownership model or invariant changes. Add experimental evidence to `Docs/AggregateClockExperiment.md` without rewriting earlier observations.
- Do not place volatile measurements, exact hardware quirks, line numbers, or implementation walkthroughs in this file.

## Verification

Test the changed behavior at the narrowest practical layer, then run the repository's standard checks when practical:

```sh
swift build
swift test
./Scripts/build-release-app.sh
```

Apply additional evidence according to the change:

- DSP changes need deterministic reference comparisons, transition coverage, boundary impulses, and irregular render-chunk tests. Benchmark optimized release code.
- Realtime changes need an explicit audit for allocation, locking, lifetime, and bounded work. Audible success is not sufficient evidence.
- Core Audio changes need packaged-app tests on relevant physical hardware and route transitions. Unit tests cannot establish HAL behavior.
- Persistence changes need current-schema round trips, older-schema migration, corrupt-store recovery, future-schema protection, and atomic-write coverage.
- Settings, IPC, sandbox, entitlement, signing, or updater changes need packaged-app validation and strict nested-code signature verification.
- UI changes need keyboard and VoiceOver checks in addition to previews or screenshots.
- Performance claims must identify the exact optimized artifact measured. `swift build` does not replace an installed app bundle.

Do not run `GlassEQDiagnostics` while the main GlassEQ app is processing audio; two simultaneous global taps invalidate the result and may disturb playback. Use the diagnostic deliberately against the intended route.

Do not claim a test, benchmark, signing check, or hardware trial passed unless it was actually run. If a required check cannot be performed, state precisely what remains unverified.

## Documentation Boundaries

- `README.md`: product promise, supported target, installation, features, limitations, and public-facing privacy explanation.
- `Docs/Architecture.md`: current ownership model, runtime flows, module boundaries, and durable implementation detail.
- `Docs/AggregateClockExperiment.md`: measurements, hypotheses, experiments, failures, and architecture rationale.
- Tests: executable contracts and regressions.
- Source comments: local invariants that cannot be made obvious through types and structure.
- `AGENTS.md`: stable engineering values and constraints for future changes.

When these disagree, verify the current code and tests, correct the stale documentation, and preserve measured evidence rather than rewriting history.
