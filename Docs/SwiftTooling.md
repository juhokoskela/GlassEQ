# Swift tooling policy

GlassEQ uses the Xcode-bundled `swift format` for layout and import ordering. The configuration keeps four-space indentation and a 120-column target. Rules that change access control, iteration, ownership declarations, or API structure are disabled. SwiftLint owns the explicitly listed code checks; upgrading it does not implicitly enable additional defaults.

`Scripts/check-swift.sh` checks formatting and runs the selected lint rules. `Scripts/analyze-swift.sh` builds all source and test targets from scratch before running `unused_declaration` and `unused_import`. The package manifest and standalone icon-generation script are formatted and linted, but are outside the analyzer's compiled app and test modules. Build and analyzer command failures fail CI; analyzer warnings remain advisory.

## Reviewed findings

The initial SwiftLint 0.65.1 run produced 13 selected-rule diagnostics and 48 analyzer warnings. Review led to these changes:

- Reject invalid UTF-8 when converting the running Settings helper's executable path. Replacement decoding could change the path being compared. This is validation hardening; the lint finding did not demonstrate a signature or containment bypass.
- Remove unused main-app profile-action wrappers, an obsolete rollback helper, an unused notification constant, a private sendability wrapper, an unused diagnostic conversion and label, and unused test-double controls. The Settings controller's active commands remain in place.
- Remove unnecessary imports and use the narrower AVFAudio and Dispatch imports where those modules own the referenced APIs.
- Use `isEmpty`, loop `where` clauses, explicit drawing branches, static URLProtocol overrides, and a synthesized internal initializer where they preserve behavior.

Some findings require retaining the original code:

- SwiftUI owns `@NSApplicationDelegateAdaptor` even without an explicit property read. The onboarding removal confirmation state is used through its projected binding. Both have local `unused_declaration` suppressions.
- The convolver bank's `_read` and `_modify` accessors implement actual subscript reads and mutations. Removing them changes the ownership contract. Their suppression is confined to that subscript.
- SettingsCoordinator requires OSLog for Logger and privacy-aware string interpolation. Removing the import failed compilation despite the analyzer's unused-import warning. A local suppression records the requirement.
- Foundation and Darwin remain allowed canonical imports. The analyzer can attribute their APIs to SDK submodules or other frameworks' re-exports. Enabling `require_explicit_imports` produced warnings demanding private `_DarwinFoundation` imports, so that option is not enabled.
- `SeparateClockAudioBackend.servicePlaybackMaintenance` retains its advisory complexity warning at 22. It chooses recovery work under the control lock, then performs persistence and device work outside it with generation checks. Changing that structure only to lower the score would exceed the tooling cleanup.

Do not remove a declaration solely because the analyzer reports it, add imports of private SDK implementation modules, or turn an invariant into a silent fallback to satisfy lint. Recheck local suppressions when upgrading SwiftLint or Xcode.
