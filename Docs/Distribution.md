# Distribution Notes

GlassEQ beta-0.9.3 is intended for ad hoc-signed distribution to technical testers. It is not Developer ID signed and is not notarized. A later release will move to Developer ID distribution outside the Mac App Store.

## Current Beta Distribution

Build the beta artifact:

```sh
./Scripts/build-release-app.sh
```

With no overrides, the script uses the beta channel and the version from the app's Info.plist. It derives the release label from the channel and version and produces:

- `.build/release-app/GlassEQ.app`
- `.build/dist/GlassEQ-beta-0.9.3-macos26-arm64.zip`
- `.build/dist/GlassEQ-beta-0.9.3-macos26-arm64-dSYMs.zip`

`RELEASE_CHANNEL=alpha` selects an alpha build and label. Alpha and beta builds both require Apple Silicon and ad hoc signing. `RELEASE_CHANNEL=production` requires Developer ID signing, Hardened Runtime, and notarization. `RELEASE_LABEL` can override the archive label without changing the channel or its signing requirements.

The release script requires a clean Git checkout so the packaged source matches the binaries it builds. The downloadable ZIP contains:

- `GlassEQ.app`, with the GPL text embedded at `Contents/Resources/LICENSE`.
- `LICENSE`, containing the full GPLv3 text.
- `SOURCE.md`, identifying the exact Git commit and build inputs.
- `TRADEMARKS.md`, the policy for redistributed and modified builds. The app repeats the GPL and trademark notices in its About window.
- `GlassEQ-beta-0.9.3-source.tar.gz`, containing the machine-readable Corresponding Source for that commit.

The source archive is generated from the same clean commit used for the build. The script verifies the license inside the app, at the ZIP root, and inside the source archive before writing the release checksum. Do not publish an app-only ZIP. A future DMG or other download format must provide the same license and Corresponding Source access.

The bundle is ad hoc-signed with `codesign --sign -`. It is not Developer ID signed and is not notarized, so this command should reject it:

```sh
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
```

That rejection is expected for beta. Document it clearly for testers.

## Production Distribution

Production builds use the same script with Developer ID signing, Hardened Runtime, notarization, and the entitlement public keys:

```sh
./Scripts/build-release-app.sh RELEASE_CHANNEL=production VERSION=1.0.0 BUILD=20 \
    SIGN_IDENTITY="Developer ID Application: Juho Koskela (TEAMID)" \
    ENABLE_HARDENED_RUNTIME=1 NOTARIZE=1 NOTARY_PROFILE=glasseq-notary \
    ENTITLEMENT_PUBLIC_KEYS_FILE=/path/to/entitlement-public-keys.json
```

`ENTITLEMENT_PUBLIC_KEYS_FILE` is a JSON object of key identifier to base64 Ed25519 public key. The script validates it, embeds it in the packaged Info.plist under `GlassEQEntitlementPublicKeys`, and refuses a production build whose Info.plist lacks the dictionary, because such a build would run unrestricted. Prerelease builds may embed the keys to test licensing and otherwise run unrestricted. `NOTARY_PROFILE` names a keychain profile created with `xcrun notarytool store-credentials`.

The order of operations is: sign the helper and the app, notarize the app and staple it, verify signatures, entitlements, and Gatekeeper assessment, package the zip, then build the disk image from the stapled app, sign it, notarize and staple it, and assess it with `spctl --assess --type open`. The script then mounts the image and checks its contents and the app's signature and staple before writing checksums.

Every channel produces, under `.build/dist`:

- `GlassEQ-<label>-macos26-arm64.zip` and its `.sha256`, as before.
- `GlassEQ-<label>-macos26-arm64.dmg` and its `.sha256`: the supported download. It contains `GlassEQ.app`, an `Applications` link for the drag install, `LICENSE`, `TRADEMARKS.md`, `SOURCE.md`, and the Corresponding Source archive.
- `GlassEQ-<label>-macos26-arm64-dSYMs.zip`, described below.
- `GlassEQ-<label>-macos26-arm64-release-evidence.md`: the release label, version and build, channel, source revision, signing identity, notarization submission identifiers for the app and the disk image, licensing status, Xcode and Swift versions, binary UUIDs, and the SHA-256 of every artifact. Keep it with the release.

Publish the disk image, its checksum, and the evidence file. Keep the dSYM archive private with the release records. When GlassEQ runs from the mounted disk image, a Gatekeeper translocation copy, or the Downloads folder, the menu bar popover asks the user to move it to Applications, because an update cannot replace the app in those places.

## Beta Installer Instructions

Technical testers can install by unzipping the artifact and moving `GlassEQ.app` to `/Applications`.

Because the app is not notarized, a browser-downloaded build should be blocked on first launch. The preferred tester path is to open System Settings > Privacy & Security and explicitly allow GlassEQ to open.

If a tester needs to bypass quarantine from Terminal instead, remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/GlassEQ.app
```

Then open the app from Finder. On first audio start, macOS should prompt for system audio capture permission. If permission is denied or the prompt does not appear, open System Settings > Privacy & Security and look for the system audio recording permission entry.

## Uninstall and Reset

Quit GlassEQ from the menu bar app, remove the app bundle, and optionally delete profile data:

```sh
rm -rf /Applications/GlassEQ.app
rm -rf ~/Library/Application\ Support/GlassEQ
rm -rf ~/Library/Containers/com.glasseq.app/Data/Library/Application\ Support/GlassEQ
```

If system audio permission gets stuck during testing, remove GlassEQ from the relevant Privacy & Security pane and launch it again.

## Xcode App Target Settings

- Product type: macOS App.
- Minimum deployment: macOS 26.0.
- Swift language mode: Swift 6.
- App Sandbox: enabled.
- Audio input entitlement: enabled for Core Audio system/process tap permission.
- Outgoing network entitlement: enabled for the built-in AutoEq browser.
- User-selected read-write file entitlement: enabled on the main app, which presents the open panel for guided text-profile, WAV impulse-response, and library imports, and the save panel for support reports and library exports.
- The settings helper is signed with only `com.apple.security.app-sandbox` and `com.apple.security.inherit`. Adding another App Sandbox entitlement makes macOS abort the inherited child process during sandbox initialization.
- Info.plist: use `Sources/GlassEQApp/Info.plist`.
- Entitlements: use `GlassEQ.entitlements`.
- Signing for beta: ad hoc.
- Signing for public distribution: Developer ID Application with Hardened Runtime.

## Required Plist Key

`NSAudioCaptureUsageDescription` is required for Core Audio system/process taps. The shipped value is:

> GlassEQ captures system output audio so it can apply equalization before playback. System audio output stays completely local.

## Support Reports and Debug Launches

GlassEQ builds a support report from state it already holds: the app and macOS versions, the Mac model identifier, the engine and setup state, the audio route without its device UID, profile names, and the last 200 lifecycle events. Events may contain filenames or error details. The report excludes EQ settings, impulse responses, and license keys. Dynamic messages are private in the unified log; the local report retains them for review before sharing. Users open it from About GlassEQ, from Settings → Output, or from the notice shown after a run that did not quit cleanly, then review, copy, or save it. Ask for it in every bug report.

For a launch that shows nothing, run the executable from Terminal with the debug flag. It streams the same lifecycle events to stderr as they happen:

```sh
/Applications/GlassEQ.app/Contents/MacOS/GlassEQ --debug
```

The events also reach the unified log under the `com.glasseq.app` subsystem, which works for a Finder launch:

```sh
log stream --predicate 'subsystem == "com.glasseq.app"' --level info
```

## Crash Logs and Symbolication

The release script writes `GlassEQ.dSYM` and `GlassEQSettings.dSYM` from the same link it packages, checks that their UUIDs match the shipped binaries, and zips them next to the app archive as `GlassEQ-<label>-macos26-arm64-dSYMs.zip`. Keep that archive with every release. A crash report from a build can only be symbolicated with the dSYMs of that exact build.

macOS writes crash reports to `~/Library/Logs/DiagnosticReports/GlassEQ-*.ips` and shows them in Console under Crash Reports. To symbolicate one:

1. Compare `dwarfdump --uuid GlassEQ.dSYM` with the UUID in the report's `Binary Images` entry for GlassEQ. They must match.
2. Resolve frames with `atos -o GlassEQ.dSYM/Contents/Resources/DWARF/GlassEQ -arch arm64 -l <load address> <frame address>`, using the load address listed for the GlassEQ image in the report.

## Verification

Run these before notarization:

```sh
swift test
swift build -c release --product GlassEQ
swift run GlassEQDiagnostics 2
```

For beta packaging, also run:

```sh
python3 Scripts/test-release-app.py
./Scripts/build-release-app.sh
codesign --verify --strict --verbose=2 .build/release-app/GlassEQ.app/Contents/Helpers/GlassEQSettings.app
codesign --verify --strict --verbose=2 .build/release-app/GlassEQ.app
codesign -d --entitlements :- .build/release-app/GlassEQ.app
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
unzip -Z1 .build/dist/GlassEQ-beta-0.9.3-macos26-arm64.zip
```

`codesign --verify` should pass. The entitlements output should include `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-write`, and `com.apple.security.network.client`, all set to `true`. The ZIP listing should include `GlassEQ.app`, `LICENSE`, `TRADEMARKS.md`, `SOURCE.md`, and the release's source archive. `spctl` should reject the ad hoc-signed beta because it is not Developer ID signed or notarized.

For manual sandbox verification, launch the packaged app and open Activity Monitor, then enable the `Sandbox` column. GlassEQ should show `Yes`.
