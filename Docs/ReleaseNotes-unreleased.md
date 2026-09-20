# Unreleased

## Source API changes

Programme comparison now always compares the draft with its filters off. `SettingsCommand.startProgrammeComparison` takes only the profile, and `EQProgrammeComparisonReference` has been removed. `EQProgrammeComparisonSnapshot` contains only `isActive`, `isReady`, and `selection`; attenuation-dB reporting has been removed. The app and bundled Settings helper must be rebuilt together. Saved profiles are unchanged.

Live DSP state now has single ownership. `EQProcessor`, `RealtimeEQTransition`, and `EQTransitionRenderResult` are noncopyable. Construct independent processors from a shared `EQRenderConfiguration`; its configuration is now read-only. Transition adoption takes `inout EQProcessor?` slots and empties them only when accepted. Move retired processors out of render results with `take()` and release them off the audio thread. Processor construction and configuration updates must also run off that thread.
