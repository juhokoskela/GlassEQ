# Swift tooling policy

GlassEQ uses the Xcode-bundled `swift format` for layout and import ordering, with four-space indentation and a 120-column target. CI selects Xcode 27.0 through `DEVELOPER_DIR`; use the same Xcode locally because another version can produce different formatting. Rules that change access control, loop structure, or synthesized initializers remain disabled.

`Scripts/swiftlint.sh` downloads SwiftLint 0.65.1 into `.build/tools` and verifies the archive against GitHub's published release-asset SHA-256 digest. It does not change a system-wide installation. `.swiftlint.yml` explicitly selects rules so upgrades do not enable new defaults implicitly.

`Scripts/check-swift.sh` checks formatting and runs SwiftLint before compilation in CI. `Scripts/analyze-swift.sh` makes a fresh debug build of source and test targets in a separate scratch directory, preserving the normal build cache, then runs `unused_declaration` and `unused_import`. The package manifest and icon-generation script are formatted and linted but are outside the analyzer's compiled modules. Both scripts run strictly: warnings fail the check, and SwiftLint findings appear as GitHub Actions annotations. The analyzer build log remains at `.build/swiftlint-analysis/build.log` for local diagnosis.

Complexity above 20 fails the lint check, excluding switch cases. `SeparateClockAudioBackend.servicePlaybackMaintenance` has a local exception because it selects recovery work under the control lock, then performs persistence and device work outside it with generation checks.

SwiftUI property wrappers and the convolver bank's borrowing and mutating accessors have narrowly scoped analyzer suppressions. Foundation and Darwin remain allowed canonical imports because the analyzer can attribute their APIs to SDK submodules or framework re-exports. Do not remove declarations solely because the analyzer reports them, import private SDK modules, or replace an invariant with a silent fallback to satisfy lint. Recheck analyzer suppressions when upgrading SwiftLint or Xcode: `superfluous_disable_command` does not detect stale analyzer suppressions.
