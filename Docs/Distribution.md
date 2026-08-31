# Distribution Notes

GlassEQ alpha-0.9.2 is intended for ad hoc-signed distribution to technical testers. It is not Developer ID signed and is not notarized. A later non-alpha build will move to Developer ID distribution outside the Mac App Store.

## Current Alpha Distribution

Build the alpha artifact:

```sh
./Scripts/build-release-app.sh
```

The script produces:

- `.build/release-app/GlassEQ.app`
- `.build/dist/GlassEQ-alpha-0.9.2-macos26-arm64.zip`

The bundle is ad hoc-signed with `codesign --sign -`. It is not Developer ID signed and is not notarized, so this command should reject it:

```sh
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
```

That rejection is expected for alpha. Document it clearly for testers.

## Alpha Installer Instructions

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
- Signing for alpha: ad hoc.
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

For alpha packaging, also run:

```sh
./Scripts/build-release-app.sh
codesign --verify --strict --verbose=2 .build/release-app/GlassEQ.app/Contents/Helpers/GlassEQSettings.app
codesign --verify --strict --verbose=2 .build/release-app/GlassEQ.app
codesign -d --entitlements :- .build/release-app/GlassEQ.app
spctl --assess --type execute --verbose=4 .build/release-app/GlassEQ.app
```

`codesign --verify` should pass. The entitlements output should include `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-only`, and `com.apple.security.network.client`, all set to `true`. `spctl` should reject the ad hoc-signed alpha because it is not Developer ID signed or notarized.

For manual sandbox verification, launch the packaged app and open Activity Monitor, then enable the `Sandbox` column. GlassEQ should show `Yes`.
