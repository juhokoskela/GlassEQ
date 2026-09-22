# Unreleased

## About window

GlassEQ now has an About window with the version, build, copyright, website, and source links. Its sections cover the GPL notice with the full license text, the trademark policy, what stays on the Mac and what the license service and AutoEq search send, and the AutoEq MIT attribution. Open it from the info button in the menu bar popover, the app menu while a GlassEQ window is open, or the About row in Settings. Official builds also show the current license state there, and Manage License reopens the setup guide at the activation step.

## Support report and debug launches

About GlassEQ, the Settings Output tab, and the menu bar popover after a crash can open a support report: the app and macOS versions, the Mac model identifier, engine and setup state, the audio route without its device UID, profile names, and the last 200 app events. Review it in the window, then copy it or save it as a text file. GlassEQ never sends it anywhere itself. The app entitlement for user-selected files is now read-write so that the save panel works; GlassEQ still reaches only files you choose.

Launching the executable with `--debug` streams the same events to stderr, and the events always go to the unified log under `com.glasseq.app`. After a run that crashed or was killed, the popover shows a notice with recovery guidance and a shortcut to the report.

The release script now writes dSYMs for both executables, verifies that they match the packaged binaries, and archives them beside the app zip.

## Source API changes

`SettingsCommand.showAbout` and `SettingsCommand.showSupportReport` ask the main app to open the About and Support Report windows. The app and bundled Settings helper must be rebuilt together.

Programme comparison now always compares the draft with its filters off. `SettingsCommand.startProgrammeComparison` takes only the profile, and `EQProgrammeComparisonReference` has been removed. `EQProgrammeComparisonSnapshot` contains only `isActive`, `isReady`, and `selection`; attenuation-dB reporting has been removed. The app and bundled Settings helper must be rebuilt together. Saved profiles are unchanged.

Live DSP state now has single ownership. `EQProcessor`, `RealtimeEQTransition`, and `EQTransitionRenderResult` are noncopyable. Construct independent processors from a shared `EQRenderConfiguration`; its configuration is now read-only. Transition adoption takes `inout EQProcessor?` slots and empties them only when accepted. Move retired processors out of render results with `take()` and release them off the audio thread. Processor construction and configuration updates must also run off that thread.
