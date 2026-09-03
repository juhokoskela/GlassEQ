# GlassEQ v1.0 readiness

This checklist tracks the work required to move GlassEQ from the technical alpha to the first supported release. It covers the official Developer ID distribution. Builds made from source remain available under the project's open-source license.

## Release decisions

- [x] Distribute the official app outside the Mac App Store.
- [x] Gate the signed, notarized distribution and its update service behind either a perpetual license or a monthly subscription.
- [x] Use Stripe Managed Payments as the merchant of record and billing authority.
- [x] Price the perpetual license at EUR 29 and the monthly subscription at EUR 3 per month.
- [x] Keep the monthly subscription genuinely month to month. Do not require annual prepayment.
- [x] Keep audio, profiles, and device details local.
- [x] Use Sparkle 2 for automatic updates.
- [x] Ship the production app in a notarized DMG.
- [x] Reserve the GlassEQ name and logo for the official distribution.
- [x] Change the source license from MIT to `GPL-3.0-or-later` and update the repository license notice and README.
- [x] Publish a trademark policy. Third-party builds must use a different name and logo and must not imply that Juho Koskela signed, published, or supports them.
- [ ] Add the GPL and trademark notices to the About window and release documentation.
- [ ] Have the licensing, subscription, privacy, refund, and trademark terms reviewed before taking payments.

The GPL permits redistribution of official binaries, so the paid product cannot rely on download scarcity. The value of the commercial offering is the trusted signed build, notarization, automatic updates, and support. Server-controlled downloads and updates are enforceable service boundaries. A secret embedded in the open-source client is not.

## License behavior

### Billing and entitlement architecture

Stripe owns checkout, recurring billing, payment recovery, refunds, chargebacks, and international consumer tax handling through Managed Payments. GlassEQ owns license issuance and product access.

- [ ] Receive Stripe purchase, subscription, refund, and chargeback events through a server-side webhook endpoint.
- [ ] Process webhook events idempotently and verify their Stripe signatures.
- [ ] Issue a GlassEQ license key after a successful perpetual purchase or subscription start.
- [x] Let the app exchange its license key and installation identifier for a server-signed entitlement. Monthly entitlements expire; perpetual entitlements do not.
- [ ] Use the same entitlement service to authorize Sparkle archive downloads.
- [ ] Keep all Stripe secret keys and webhook secrets on the server. The app must never contain or receive them.
- [ ] Store only the billing identifiers and entitlement state needed to operate licensing, updates, refunds, and account recovery.
- [ ] Document the customer data exchanged with Stripe and the GlassEQ entitlement service.
- [x] License one purchaser for two concurrently activated Macs under either payment plan.
- [x] Generate a random installation identifier and store it in Keychain. Do not derive it from hardware identifiers.
- [ ] Let the purchaser deactivate an old Mac and transfer an activation without support intervention.
- [ ] Record the policy version accepted at checkout with the purchase.
- [x] Apply material entitlement restrictions prospectively. Do not silently reduce the rights attached to an existing purchase.

### Perpetual licenses

- [ ] Convert a completed EUR 29 Managed Payments purchase into a non-expiring GlassEQ entitlement.
- [ ] Issue a server-signed entitlement that the app can verify locally with an embedded public key.
- [x] Store the entitlement and license credential in Keychain.
- [x] Keep an installed version working without recurring license checks.
- [x] Include every official v1.x update, including security and compatibility fixes published for v1. A perpetual v1 license does not include v2.
- [x] Offer a voluntary 14-day refund window while honoring later refunds required by Stripe or applicable law.
- [x] After a refund or chargeback, block new activations, official downloads, updates, and support. Do not disable an already activated offline installation.
- [ ] Apply perpetual refund and chargeback restrictions in the entitlement and update services.

### Monthly subscriptions

The app must never cut or mute system audio when a subscription expires. Expiry disables GlassEQ processing and returns the route to normal dry system playback. The app remains open so the user can renew, inspect profiles, export data, or retry verification.

Stripe is the billing authority for the EUR 3 monthly subscription. The GlassEQ entitlement service maps Stripe subscription state to the signed entitlement consumed by the app. The app does not contact Stripe directly.

An active monthly subscription includes the current official GlassEQ release, including future major versions, on two concurrently activated Macs.

Proposed check policy:

1. At launch, use the cached signed entitlement when it is still fresh.
2. Verify in the background when the last successful check is at least seven days old or the cached entitlement is near expiry.
3. Repeat the check every seven days while the app remains running. This prevents an indefinitely running process from avoiding renewal checks.
4. When the service confirms expiry, or verification remains unavailable, start a seven-day grace period. Persist the deadline so quitting, relaunching, or restarting the Mac cannot reset it.
5. Show a clear but non-blocking warning during the grace period. Include the deadline and a Renew button.
6. When grace ends, transition the active DSP bank to identity filters and unity preamp with the normal click-free bank transition. Stop the tap only after the transition has completed so Core Audio returns to direct dry playback.
7. Keep every profile, output mapping, import, and calibration record intact.
8. Show a persistent message in the menu bar and Settings. Explain that the subscription expired and GlassEQ has returned to unprocessed playback.
9. After renewal, retry verification and resume the selected profile through the normal click-free startup path.

- [x] Grace runs from the signed timeline. The server sets `recovery_until` and `exp`, and the app evaluates them against its trusted-time floor, so detection time never extends the window.
- [x] An authoritative expired response and a network outage share the signed window. A refund or chargeback denial is persisted so an offline relaunch cannot resurrect processing.
- [x] Refresh is driven by the signed `refresh_after` claim. Launch refreshes only when it has passed, and a running app schedules the next check from the same claim.
- [x] Security updates after a lapse follow the signed `security_updates_after_expiry` claim, which selects the security-only feed.
- [ ] Test clock changes, stale cached state, invalid signatures, replayed entitlements, account recovery, cancellation, renewal, refund, and service outages.

License verification must run outside the realtime path. It must not make Core Audio ownership, route recovery, profile editing, or dry-playback restoration depend on a network response.

## First-time onboarding

- [ ] Present a normal foreground window on first launch. Keep a Dock presence until onboarding finishes so the app cannot appear to launch invisibly.
- [ ] Explain that GlassEQ lives in the menu bar and show where to find it.
- [ ] Explain system audio capture before asking macOS for permission.
- [ ] Handle permission granted, denied, dismissed, and later revoked.
- [x] Activate or restore a license.
- [ ] Offer Launch at Login through `SMAppService.mainApp`.
- [ ] Confirm the current output and active profile.
- [ ] Show a clear success state after GlassEQ starts processing.
- [ ] Let the user reopen onboarding or permission help later.
- [ ] Verify onboarding with keyboard navigation and VoiceOver.

## Automatic updates

- [ ] Integrate the current production release of Sparkle 2.
- [ ] Serve the appcast, release notes, and archives over HTTPS.
- [ ] Sign update archives with Sparkle EdDSA in addition to Apple code signing.
- [ ] Sign the appcast and release notes.
- [ ] Keep the Sparkle private key outside the repository and hosting server. Back it up separately from the Developer ID key.
- [ ] Add a manually approved production release workflow in the GlassEQ repository. Build from an exact release tag, run tests, Developer ID sign, notarize, staple, Sparkle-sign, and verify before publishing.
- [ ] Publish immutable release artifacts to S3 through a narrowly scoped GitHub OIDC role, then publish the signed appcast only after every referenced artifact is available.
- [ ] Keep release credentials and artifact-write access out of ordinary CI and `GlassEQServer`. The entitlement service may authorize downloads, but it must not sign, upload, overwrite, or delete releases.
- [ ] Use the app's existing network entitlement. Do not enable Sparkle's downloader service when the main app already owns network access.
- [ ] Enable Sparkle's installer XPC service and add only the Mach lookup exceptions required by Sparkle's sandbox integration.
- [ ] Extend the custom packaging script to copy Sparkle with its symlinks and executable permissions intact.
- [ ] Sign every Sparkle helper, XPC service, framework, the Settings helper, and the containing app in the correct order.
- [ ] Gate update archive downloads with a server-validated license credential. Do not put a reusable license key in a URL.
- [ ] Use the GlassEQ entitlement service, backed by Stripe Managed Payments state, as the update-download authority.
- [ ] Enforce update scope in the service. Perpetual v1 licenses may download v1.x releases, while active monthly subscriptions may download the current release.
- [ ] Add Check for Updates and automatic-update controls to Settings.
- [ ] Prevent an update prompt from interrupting first-time onboarding.
- [ ] Test update installation while GlassEQ is processing audio. The normal termination path must restore dry playback before Sparkle replaces the app.
- [ ] Test v1.0 to v1.0.1 with genuine signed, notarized builds and the production update feed.
- [ ] Test a failed download, invalid archive signature, invalid Apple signature, interrupted installation, relaunch failure, and update-server outage.
- [ ] Keep release dSYMs for GlassEQ, GlassEQSettings, Sparkle, and any other nested executable.

## Production distribution

- [ ] Create a DMG containing `GlassEQ.app` and an Applications shortcut.
- [ ] Sign the app and all nested code with Developer ID and Hardened Runtime.
- [ ] Notarize the shipped DMG or the exact supported delivery artifact and staple its ticket.
- [ ] Verify nested signatures, exact entitlements, Gatekeeper assessment, and stapling after packaging.
- [ ] Publish a SHA-256 checksum for the shipped artifact.
- [ ] Keep the notarization submission ID, artifact hash, signing identity, build number, source revision, and toolchain version in the release evidence.
- [ ] Install the browser-downloaded artifact on a clean account without development certificates.
- [ ] Detect or explain launches from a read-only DMG, Downloads, or another location where updates cannot be installed reliably.
- [ ] Update `Docs/Distribution.md`, README installation instructions, and the release notes for the production channel.
- [ ] Embed the entitlement public keys in the official build's Info.plist under `GlassEQEntitlementPublicKeys`. A build without the key dictionary runs unrestricted by design.
- [ ] Add a "licensing required" marker to the release checks so a build that is missing the key dictionary fails the release instead of shipping unrestricted.

## Diagnostics and support

- [ ] Add Copy Diagnostics and Export Support Report actions.
- [ ] Include the app version and build, macOS version, Mac architecture, route metadata, current failure, recovery history, and bounded audio counters.
- [ ] Let the user preview the report before copying, saving, or submitting it.
- [ ] Exclude profile contents, imported impulse responses, license credentials, and other unnecessary personal data.
- [ ] Detect an unclean previous termination and offer local recovery guidance on the next launch.
- [ ] Retain release dSYMs and document the crash-symbolication process.
- [ ] Choose a support route that paying users can access. GitHub issue creation is currently restricted, so an email address or support form is still needed.
- [ ] Update the issue template for v1 builds and exported support reports.

Automatic crash uploading is not required for v1. Local diagnostics and an explicit user-controlled report path preserve GlassEQ's no-telemetry policy.

## Profiles and user data

- [ ] Export the complete profile library, including impulse responses, output mappings, the fallback profile, and relevant calibration records.
- [ ] Import a complete library without silently replacing existing data.
- [ ] Version and bound the backup format, validate it as untrusted input, and write restored data atomically.
- [ ] Test round trips, merge or replacement behavior, corrupt backups, future schema versions, duplicate identifiers, oversized payloads, and interrupted writes.
- [ ] Keep automatic backups before destructive migration or library replacement.

## Product and legal UI

- [ ] Add About GlassEQ with the version, build, copyright, source link, and official website.
- [ ] Add License, Privacy, Credits, Check for Updates, Manage License, Renew, and Export Support Report actions.
- [ ] Explain what the license and update services receive, how long the service retains it, and how the user can request deletion where applicable.
- [ ] Preserve the promise that audio, profiles, device details, and diagnostics remain local unless the user explicitly exports a report.
- [ ] Attribute AutoEq and include its MIT notice.
- [ ] Add the GPL notice and third-party notices to the app and distribution.
- [ ] Complete keyboard, VoiceOver, contrast, reduced-motion, window-resizing, and menu-bar discoverability checks.

## Release acceptance matrix

- [ ] Clean install from a quarantined browser download.
- [ ] Upgrade from alpha-0.9.2 to signed v1.0 without losing profiles or mappings.
- [ ] Verify system audio capture behavior when moving from the ad hoc alpha signature to Developer ID.
- [ ] Grant, deny, dismiss, revoke, and restore system audio capture permission.
- [ ] Launch inside and outside `/Applications`.
- [ ] Enable, deny, disable, and restore Launch at Login.
- [ ] Activate, restore, expire, renew, and revoke each license type.
- [ ] Start offline within grace, offline after grace, and online after renewal.
- [ ] Sleep, wake, log out, log back in, and restart the Mac.
- [ ] Switch between built-in, USB, HDMI, Bluetooth, headset, and unsupported outputs while audio plays.
- [ ] Force a crash or kill while the tap is active and confirm normal dry playback resumes.
- [ ] Update while processing audio and confirm the route remains audible before, during, and after relaunch.
- [ ] Downgrade and open a future-schema profile store without modifying it.
- [ ] Run keyboard and VoiceOver checks on onboarding, licensing, update, recovery, and profile backup flows.
- [ ] Soak the exact release artifact on representative hardware.

## Current verification baseline

- [x] `swift test` passed 567 tests on September 1, 2026.
- [x] The production release configuration dry run accepted v1.0 inputs.
- [x] The release script has Developer ID signing, Hardened Runtime, notarization, stapling, Gatekeeper assessment, exact entitlement checks, and checksums.
- [ ] Run the release script with the real Developer ID identity and notary profile.
- [ ] Verify a real signed and notarized DMG.
- [ ] Complete the production Sparkle update round trip.
- [ ] Complete packaged-app testing on supported physical hardware.

## Deferred beyond v1.0

These are not release blockers while GlassEQ continues to fail safely to dry playback and documents the limitations clearly.

- AirPlay output support.
- Intel support.
- Wider multichannel and preferred-pair support.
- Additional localizations.
- Automatic crash uploading or telemetry.
