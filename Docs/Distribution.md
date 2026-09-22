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
- User-selected read-only file entitlement: enabled on the main app, which presents the open panel and reads guided text-profile and WAV impulse-response imports.
- The settings helper is signed with only `com.apple.security.app-sandbox` and `com.apple.security.inherit`. Adding another App Sandbox entitlement makes macOS abort the inherited child process during sandbox initialization.
- Info.plist: use `Sources/GlassEQApp/Info.plist`.
- Entitlements: use `GlassEQ.entitlements`.
- Signing for beta: ad hoc.
- Signing for public distribution: Developer ID Application with Hardened Runtime.

## Required Plist Key

`NSAudioCaptureUsageDescription` is required for Core Audio system/process taps. The shipped value is:

> GlassEQ captures system output audio so it can apply equalization before playback. System audio output stays completely local.

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

`codesign --verify` should pass. The entitlements output should include `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-only`, and `com.apple.security.network.client`, all set to `true`. The ZIP listing should include `GlassEQ.app`, `LICENSE`, `TRADEMARKS.md`, `SOURCE.md`, and the release's source archive. `spctl` should reject the ad hoc-signed beta because it is not Developer ID signed or notarized.

For manual sandbox verification, launch the packaged app and open Activity Monitor, then enable the `Sandbox` column. GlassEQ should show `Yes`.
