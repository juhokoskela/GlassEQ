# Unreleased

## About window

GlassEQ now has an About window with the version, build, copyright, website, and source links. Its sections cover the GPL notice with the full license text, the trademark policy, what stays on the Mac and what the license service and AutoEq search send, and the AutoEq MIT attribution. Open it from the info button in the menu bar popover, the app menu while a GlassEQ window is open, or the About row in Settings. Official builds also show the current license state there, and Manage License reopens the setup guide at the activation step.

## Source API changes

`SettingsCommand.showAbout` asks the main app to open the About window. The app and bundled Settings helper must be rebuilt together.

Programme comparison now always compares the draft with its filters off. `SettingsCommand.startProgrammeComparison` takes only the profile, and `EQProgrammeComparisonReference` has been removed. `EQProgrammeComparisonSnapshot` contains only `isActive`, `isReady`, and `selection`; attenuation-dB reporting has been removed. The app and bundled Settings helper must be rebuilt together. Saved profiles are unchanged.

Live DSP state now has single ownership. `EQProcessor`, `RealtimeEQTransition`, and `EQTransitionRenderResult` are noncopyable. Construct independent processors from a shared `EQRenderConfiguration`; its configuration is now read-only. Transition adoption takes `inout EQProcessor?` slots and empties them only when accepted. Move retired processors out of render results with `take()` and release them off the audio thread. Processor construction and configuration updates must also run off that thread.
