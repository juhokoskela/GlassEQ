# Licensing and automatic updates: completion checklist

Bookkeeping snapshot: September 22, 2026. The implementation progress section records subsequent work in the isolated branches.

The app's offline licensing and activation lifecycle are implemented. GlassEQServer implements activation, management, recovery requests, and Stripe Checkout. The remaining work is to turn payments into delivered licenses, provide customer management and renewal flows, enforce download access, integrate Sparkle, and verify the signed production release path.

## Scope and evidence

This document inventories code, tests, documentation, Git history, and GitHub status. A checked item means implementation exists at the inspected revision; it does not imply production deployment or hardware acceptance.

| Repository | Inspected revision | State |
| --- | --- | --- |
| GlassEQ | `ab087a86414a7cbb03611d43d348ceb23ebb9d26` | Isolated `finalize-licensing-auto-updates` worktree; matches GitHub `main` |
| GlassEQServer | `b24ba91e29dbab6f3b4b32f56360eec7b7fa6adb` | `/Users/juhokoskela/src/GlassEQServer`; clean `main`, matches GitHub `main` |

The server path refers to the sibling of the original GlassEQ checkout, not a sibling of this isolated worktree. The initial inventory did not change server files. Subsequent server work uses the isolated sibling worktree described below.

GitHub reports successful CI for the inspected [app revision](https://github.com/juhokoskela/GlassEQ/actions/runs/35742523521) and [server revision](https://github.com/juhokoskela/GlassEQServer/actions/runs/33957090236). App CI includes Swift checks, tests, release packaging, and strict signatures for the existing app and Settings helper. Server CI includes PostgreSQL migrations, race tests against PostgreSQL, vet, and a container build. No tests or builds were rerun for this documentation pass.

At the initial snapshot, no licensing or updater PR was open in either repository. GlassEQ's open PR #33 concerns an experimental CI runner. The latest published app release is `beta-0.9.3`; [Distribution.md](Distribution.md) describes the beta as ad hoc signed and not notarized.

AWS resources, deployed services, Stripe settings, SES delivery, the public website, production signing identities, and release secrets were not inspected. Their readiness remains unverified. This inventory does not infer that an external resource is missing merely because it is absent from these repositories.

The original GlassEQ checkout has separate uncommitted About-window work on `feat/about-window`, including `Sources/GlassEQApp/About.swift` and a bundled GPL text. That work is not in this worktree or the inspected `main` revision. Coordinate with it before implementing overlapping legal/About UI.

## Implemented already

### GlassEQ

- [x] `GlassEQLicensing` verifies compact Ed25519 JWS entitlements, exact claims, installation binding, revisions, and signed monthly timelines. Perpetual v1 entitlements have no expiry. See [EntitlementVerifier.swift](../Sources/GlassEQLicensing/EntitlementVerifier.swift) and [Entitlement.swift](../Sources/GlassEQLicensing/Entitlement.swift).
- [x] The actor-owned licensing controller persists installation identity and activation state in device-only Keychain records, tracks trusted time, schedules refreshes, handles retry and storage failures, and preserves pending deactivation cleanup. The bootstrap license key is not persisted. See [LicensingController.swift](../Sources/GlassEQLicensing/LicensingController.swift) and [LicenseCredentialStore.swift](../Sources/GlassEQLicensing/LicenseCredentialStore.swift).
- [x] The HTTP client activates, refreshes, and deactivates the current installation against `https://license.glasseq.app`, bounds responses, and refuses redirects. See [LicenseService.swift](../Sources/GlassEQLicensing/LicenseService.swift).
- [x] Builds with embedded entitlement keys gate audio startup on license state. Expiry transitions DSP to identity before stopping the tap, with a bounded stop timeout. Renewal respects processing intent and sleep state. Onboarding supports key activation and removal/recovery guidance. See [GlassEQApp.swift](../Sources/GlassEQApp/GlassEQApp.swift), [LicenseActivation.swift](../Sources/GlassEQApp/LicenseActivation.swift), and [Architecture.md](Architecture.md).
- [x] Regression coverage exists for entitlement verification, trusted time, controller lifecycle, HTTP boundaries, activation copy, and app-level expiry/renewal behavior. See [licensing tests](../Tests/GlassEQLicensingTests), [activation tests](../Tests/GlassEQAppTests/LicenseActivationTests.swift), and [app lifecycle tests](../Tests/GlassEQAppTests/GlassEQAppModelLifecycleTests.swift). These do not establish physical audio behavior or live service interoperability.
- [x] The release script already supports Developer ID signing, Hardened Runtime, notarization submission, stapling, signature/entitlement checks, Gatekeeper assessment, and checksums. Current packaging produces a ZIP with GPL notices and Corresponding Source. See [build-release-app.sh](../Scripts/build-release-app.sh) and [Distribution.md](Distribution.md).

### GlassEQServer

Server references below are relative to the [GlassEQServer repository](https://github.com/juhokoskela/GlassEQServer/tree/b24ba91e29dbab6f3b4b32f56360eec7b7fa6adb).

- [x] PostgreSQL schema/migrations, HTTP liveness/readiness, Docker packaging, and CI exist. Goose is already pinned by digest in local Compose and CI. Evidence: `migrations/`, `compose.yaml`, `Dockerfile`, `.github/workflows/ci.yml`.
- [x] KMS-backed Ed25519 entitlement issuance, two-slot activation, idempotent activation replay, refresh, and current-installation deactivation exist. Entitlements are issued from stored license/subscription state. Evidence: `internal/entitlement/`, `internal/activation/service.go`, `internal/activation/lifecycle.go`.
- [x] Short-lived management sessions, activation listing/release, and license-key rotation exist. Evidence: `internal/activation/management.go`, `rotation.go`, and corresponding HTTP routes/tests.
- [x] Recovery request ingestion, encrypted durable jobs/outbox, token preparation, SQS FIFO dispatch, and one-time recovery-token exchange exist. The dispatcher ends at SQS; it does not send email. Evidence: `internal/activation/recovery*.go` and `internal/httpapi/recovery.go`.
- [x] Optional public Checkout API, exact website-origin CORS, durable order reservations, rate limits, Stripe idempotency, and retrieval of existing sessions exist. Server-owned requests select plan, price, EUR currency, policy version, terms consent, and fixed return URLs. Evidence: `internal/billing/checkout.go`, `order.go`, `internal/httpapi/checkout.go`, and `cmd/glasseqserver/main.go`.
- [x] `check-stripe-catalog` validates the configured Prices and Products, including environment, amounts, billing shape, tax-exclusive pricing, and Product tax details. Evidence: `internal/billing/catalog.go` and `cmd/glasseqserver/catalog.go`. Checkout/schema/catalog work is merged through PR #13.
- [x] Schema foundations exist for Stripe events, release metadata, payment references, and the license-delivery outbox. These tables are not evidence that their workers or download endpoints exist. Evidence: `migrations/00001_initial.sql` and `00004_checkout_billing.sql`.

## Documentation discrepancies to resolve first

- [x] **D1: Reconcile prices and currency.** Base prices are EUR 29.99 and EUR 2.99 per month plus tax. Stripe Managed Payments supplies local-currency payment through Adaptive Pricing. EUR catalog validation is compatible with that product decision; the existing Checkout request still needs a sandbox check for both plans.
- [x] **D2: Reconcile Stripe ingestion.** Use Stripe EventBridge partner events through SQS Standard, with no public Stripe webhook or webhook secret. The cross-project protocol now follows the server billing contract.
- [x] **D3: Refresh implementation status.** The protocol and readiness checklist distinguish existing Checkout, entitlement issuance, onboarding, and signing code from production verification. Security-update eligibility is parsed; feed selection remains pending.
- [x] **D4: Remove obsolete schema instructions.** Server migration `00004_checkout_billing.sql` already adds nullable Checkout session IDs, request/payment references, and the license-delivery outbox. The billing document now records that baseline.

## Remaining implementation

### 1. Fulfill and maintain purchases (GlassEQServer)

- [ ] **L1: Complete the billing queue consumer.** Checkout, Invoice, and Subscription events are implemented; refund/dispute events remain. Validate bounded EventBridge envelopes, source/environment/API version, and the accepted event set. Hydrate current Stripe objects outside transactions; commit idempotent normalized transitions before acknowledging SQS. Handle duplicates, concurrency, reordering, unowned objects, retries, and dead-letter outcomes according to server `Docs/Billing.md`.
- [x] **L2: Implement paid-order fulfillment.** Both plans validate the purchased item, payment, order association, terms consent, and Checkout email before creating one license, key, and delivery record atomically. Monthly purchases also create the subscription projection. Both paths commit directly to `fulfilled`, so there is no intermediate paid-order gap. Failures retry through SQS with bounded redrive; email delivery remains L4.
- [ ] **L3: Complete subscription and terminal-state reconciliation.** Paid renewals, payment recovery, cancellation, and restoration after removing a pending cancellation are implemented. Refunds, disputes, and eligible dispute restoration remain. Preserve manual revocation and perpetual offline rights. Add the planned daily reconciliation and billing-specific retention for processed events, abandoned orders, and expired delivery material. Existing cleanup covers activation/recovery data, not the full billing lifecycle.
- [ ] **L4: Finish email delivery.** Dispatch license-delivery records and implement the SES consumer for both license and recovery messages, templates, stable-delivery-ID deduplication beyond SQS's five-minute window, expiry handling, retries, and cleanup. Verify recovery links and delivery without logging credentials or email contents.

### 2. Finish customer-facing licensing (app, server, and website)

- [ ] **L5: Connect purchase and post-purchase pages.** Inventory the website separately, then connect its plan selection to Checkout, show fulfillment-pending/success/cancel states, and explain email delivery and recovery. No website implementation was inspected here.
- [ ] **L6: Provide self-service management and recovery.** Connect the existing server APIs to a customer UI for listing/releasing either activation, rotating a key, and recovering access by email. Decide which actions belong in the website and which need app entry points. Keep recovery tokens out of query strings and clear fragment tokens from browser history as specified by the protocol.
- [ ] **L7: Connect Link billing management.** Use Stripe Link for subscription cancellation and payment-method changes. Add app and website entry points to Link and let the app retry verification without requiring a relaunch. Verify the customer path for restarting an ended subscription; use the existing Checkout flow where a new purchase is required. GlassEQ owns activation-slot management and license recovery, not a second billing portal.
- [ ] **L8: Add Settings license state and actions.** Publish bounded credential-free license DTOs over Settings IPC and add status, relevant deadlines, activation/deactivation, management, and verification actions. The existing client HTTP interface only covers activation, refresh, and current-installation deactivation. Preserve main-process ownership of Keychain and credentials.
- [ ] **L9: Make official licensing configuration mandatory.** Provision or verify the entitlement signing key and public `kid` mapping, embed trusted public keys in official builds, and add release checks that reject missing/malformed licensing configuration. Current `Info.plist` has no `GlassEQEntitlementPublicKeys`, so the current bundle follows the unrestricted source-build path. Preserve that deliberate behavior for source builds. Document rotation so new keys can reach installed apps before becoming necessary.

### 3. Implement authorized release delivery (server and release infrastructure)

- [ ] **U1: Implement release registration and archive delivery.** Connect immutable release records to immutable stored artifacts. Add the planned `GET /v1/releases/{release_id}/archive` endpoint using activation-token authentication and current server-side license state. Stream directly without redirects; never accept caller-controlled storage paths or trust a client entitlement as download authority. Ensure the service can read releases but cannot publish or alter artifacts.
- [ ] **U2: Enforce update eligibility.** Cover perpetual v1-only access, eligible monthly access, security-only access after expiry when policy permits, and denial after refund, chargeback, revocation, or deactivation. Keep security-release classification under the release publisher's control and test it against the signed policy. Neither authorization nor these download tests exists yet.
- [ ] **U3: Resolve first-install delivery.** The archive protocol assumes an activation token, but a first-time purchaser has not activated the app yet. Document and implement how that purchaser obtains the initial official installer without putting a reusable license key in a URL or weakening update authorization.
- [ ] **U4: Publish feeds and release notes.** Provide HTTPS v1, stable, and security-only appcasts with the correct version/build ordering, minimum OS, release notes, and authenticated archive URLs. Implement the planned feed/release-note integrity mechanism after checking support in the selected Sparkle release. Preserve the protocol's public metadata and private archive distinction.

### 4. Integrate Sparkle (GlassEQ)

- [ ] **U5: Add and pin Sparkle 2.** `Package.swift`, sources, plist, packaging, and CI currently contain no Sparkle integration. Add updater ownership in the main app, feed selection from verified license state, manual Check for Updates, automatic-update controls, and clear license-related failures. Disable system profiling and defer prompts during onboarding.
- [ ] **U6: Add narrow download authorization.** Expose only the necessary updater capability from the licensing owner. Validate the archive's exact HTTPS origin, port, user-info absence, and permitted path before displaying/downloading an update; attach the activation token only to the archive request. Reject redirects and keep credentials out of public feeds, release notes, logs, and global Sparkle headers. Implement the contract in [EntitlementProtocol.md](EntitlementProtocol.md#update-authorization).
- [ ] **U7: Extend sandboxing and packaging.** Preserve framework symlinks and permissions, enable the installer XPC service and required lookup exceptions, and use the app's existing network access rather than adding the downloader service. Sign nested Sparkle code, Settings, and the containing app in order. Update exact-entitlement and nested-signature checks rather than weakening them.
- [ ] **U8: Integrate update termination and relaunch.** Let the normal app termination path finish audio teardown and licensing persistence before replacement. Verify update behavior with an open Settings helper, in-flight licensing requests, and processing audio. Preserve profiles and user processing intent across relaunch.

### 5. Complete production packaging and operations

- [ ] **R1: Create the production DMG.** Include the Applications shortcut and preserve GPL notices and access to the exact Corresponding Source. Define the actual Sparkle enclosure artifact and verify it independently. The current script produces a ZIP, even for its production channel.
- [ ] **R2: Add the approved release workflow.** Build an exact tag/revision, run checks, Developer ID sign, notarize, staple, Sparkle-sign, and verify before publication. Publish immutable artifacts using a narrowly scoped OIDC role, then publish feeds only after their referenced artifacts are available. Ordinary CI and GlassEQServer must not receive release signing or artifact-write access.
- [ ] **R3: Provision or verify deployment resources.** Locate the infrastructure owner/repository and record the sandbox/production status of PostgreSQL, ECS/ALB, DNS/TLS for the three documented origins, KMS, secrets, billing and email queues, dead-letter handling, SES, artifact storage, and alarms. Retain the server's documented ALB forwarding and IAM boundaries. Run the pinned Goose migration task before service rollout. No production infrastructure definitions were found in the two inspected repositories.
- [ ] **R4: Verify external billing setup before enabling purchases.** Check Managed Payments eligibility/terms and the pinned preview API in sandbox; run catalog preflight for each environment; verify production Product/Price IDs, terms/privacy URLs, and the documented eight payment retries over two weeks with final cancellation. Verify SES domain/production access and create the EventBridge destination together with its AWS association. These are unverified operational gates, not established missing resources.
- [ ] **R5: Retain release and recovery evidence.** Preserve artifact hashes, source/build/toolchain identity, notarization evidence, and dSYMs for every shipped executable. Document signing-key backup/rotation, service secret recovery, database restore, failed-release recovery, and safe billing dead-letter redrive. Keep entitlement, Sparkle, Apple, billing, and database keys separate.
- [ ] **R6: Finish customer terms and notices.** Reconcile pricing, update scope, refunds, subscriptions, customer-data handling/retention, privacy, and support routes before taking payments. Review final terms and link them from the relevant customer flows. Coordinate About/GPL/trademark/third-party notices with the existing About work, then update distribution instructions and release notes.

## Implementation progress

The perpetual fulfillment slice is merged in [GlassEQServer PR #14](https://github.com/juhokoskela/GlassEQServer/pull/14), along with the protocol/checklist alignment in [GlassEQ PR #40](https://github.com/juhokoskela/GlassEQ/pull/40). They add EventBridge/SQS ingestion, duplicate/concurrent event handling, current Checkout hydration, and atomic license/key/delivery-outbox creation. Link remains the selected billing-management flow.

The next server slice, [GlassEQServer PR #15](https://github.com/juhokoskela/GlassEQServer/pull/15), adds monthly fulfillment and event-driven subscription reconciliation. Initial paid purchases issue one monthly key and projection. Renewals advance only from paid invoice lines; failed renewal does not grant the next unpaid period. Customer cancellation removes the fourteen-day recovery window, removing a pending cancellation restores it when eligible, and renewal events cannot restore refunded, charged-back, or revoked licenses. An order revision makes concurrent stale Stripe reads retry.

Local verification uses PostgreSQL 18 with all six migration Up sections applied. The race-enabled server suite, vet, build, and vulnerability check passed. Coverage includes monthly key activation and signed deadlines, initial unpaid/terminal states, renewal recovery, cancellation, duplicate/out-of-order events, stale concurrent snapshots, mismatched purchase objects, and rollback after projection and delivery writes. Verification also exposed and fixed a Checkout reservation race between the primary-key and request-ID constraints; twenty repeated concurrent-retry checks passed.

These checks establish local protocol and database behavior. Live Stripe/KMS/SQS/SES, Link, and packaged-app acceptance remain unverified. Refunds/disputes, daily reconciliation, retention, email delivery, and production enablement remain open.

## Acceptance still required

These checks must use the implemented flows and intended artifacts. Existing unit tests and green CI do not satisfy the live boundaries below.

- [ ] **V1: Cross-project licensing.** Verify that real server-issued entitlements are accepted by the packaged app using the intended key mapping. Exercise two concurrent Macs, a rejected third activation, slot transfer, key rotation, email recovery, lost responses, and deactivation retry.
- [ ] **V2: Billing end to end.** In sandbox, prove purchase through email and activation for both plans; delayed payment; renewal success/failure/recovery; cancellation; refund; dispute/restoration; duplicate/out-of-order events; reconciliation; and dead-letter redrive. Record database outcomes as well as provider responses.
- [ ] **V3: Packaged license lifecycle and audio.** Exercise active/recovery/grace/expired states, network outages, clock changes, corrupt/future Keychain data, service denial, sleep/wake, and renewal during shutdown. Verify dry playback restoration and subsequent resumption on physical hardware without losing profiles. Do not run a diagnostics tap alongside the processing app.
- [ ] **V4: Genuine update round trip.** Install one signed/notarized release and update it to the next using the intended hosted feed and archive service, while processing audio. Verify nested signatures, updater integrity checks, preserved data, teardown, relaunch, and operation from the supported installation location.
- [ ] **V5: Update failure and entitlement boundaries.** Exercise invalid Sparkle/Apple signatures, unauthorized enclosure origins/redirects, missing or revoked credentials, ineligible major versions, security-only updates, failed/interrupted downloads and installation, relaunch failure, and service outages. Ensure no token reaches an unrelated origin and license denial produces an actionable message.
- [ ] **V6: Clean-machine and accessible customer flows.** Test a quarantined browser download with no development credentials, beta-to-production migration, installation outside `/Applications` or from the DMG, and keyboard/VoiceOver operation of activation, management, renewal, and update controls. Recheck audio permission behavior across the signing transition.

## Suggested order for the next implementation pass

1. D1-D4 are aligned. Link is selected for billing management; finish the first-install and license-management paths (U3, L6-L7).
2. Complete server payment fulfillment, reconciliation, and email delivery (L1-L4), then prove the sandbox purchase-to-activation path.
3. Finish app/customer licensing UI and official key configuration (L5-L9).
4. Build release authorization and Sparkle together against the same contract (U1-U8).
5. Complete production packaging/operations and run V1-V6 on the intended artifacts.

The initial bookkeeping pass created only this checklist. Subsequent implementation and verification should be recorded against the tasks above.
