# Unreleased

## Source API changes

Programme comparison now always compares the draft with its filters off. `SettingsCommand.startProgrammeComparison` takes only the profile, and `EQProgrammeComparisonReference` has been removed. `EQProgrammeComparisonSnapshot` contains only `isActive`, `isReady`, and `selection`; attenuation-dB reporting has been removed. The app and bundled Settings helper must be rebuilt together. Saved profiles are unchanged.
