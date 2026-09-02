# GlassEQ entitlement protocol

This document defines the v1 protocol for licensing the official GlassEQ distribution. It covers server data, application credentials, signed offline entitlements, Stripe event processing, activation management, and update authorization.

This is the cross-project design contract. The `GlassEQLicensing` client module implements compact-JWS verification, entitlement evaluation, the activation-lifecycle HTTP calls against the fixed origin, Keychain persistence, trusted-time handling, refresh scheduling, and actor-owned activation state. The main app gates audio processing on the published license state and fades to identity before stopping on expiry, but only in builds that embed entitlement public keys; production keys have not been provisioned. The companion server implements entitlement issuance, activation, refresh, deactivation, management, and recovery. Stripe checkout and webhook processing, the Settings license UI, Sparkle integration, and release-service enforcement remain pending. Code and tests are authoritative for implemented behavior.

## Product invariants

- GlassEQ remains open source. A modified build can remove local license checks, so the protocol does not pretend to provide hard DRM.
- The enforceable boundaries are the official signing identity, notarized distribution, activation service, update service, and support.
- A license has at most two active server registrations.
- A perpetual license authorizes local use and official v1.x releases. It does not require recurring checks.
- A monthly license authorizes the current official release while Stripe considers the subscription active or recoverable, followed by a seven-day GlassEQ grace period.
- Expiry never mutes system audio. GlassEQ transitions to identity processing and restores normal dry playback.
- Network and license work stays outside the realtime audio path.
- The service does not receive device names, hardware identifiers, OS details, profiles, audio, output metadata, or diagnostics.
- The main app owns licensing, Keychain access, network checks, update authorization, and audio enforcement. The Settings helper only displays snapshots and sends bounded commands through the existing IPC session.

## Trust model

The service protects activation slots, official downloads, update access, Stripe-derived purchase state, and the entitlement-signing key.

The customer controls the Mac and can inspect or modify an open-source client. The protocol assumes they can copy local files, change the clock, intercept their own process, and rebuild GlassEQ under another signing identity. They cannot forge an Ed25519 entitlement, authenticate to the official service without a valid credential, or publish a modified app under GlassEQ's official signing identity.

The server never accepts a client-supplied entitlement as authority for activations or downloads. It resolves the activation token to current server state. The signed entitlement exists so the official app can make bounded offline decisions.

Use system TLS validation without certificate pinning. Licensing requests use fixed HTTPS origins. Secrets never appear in URLs, logs, diagnostics, analytics, crash data, or app-group storage.

## Terms

- **License:** The purchaser's perpetual or monthly product right.
- **License key:** A revocable credential used to activate a Mac or create a management session.
- **Installation ID:** A random identifier generated on one Mac. It is not derived from hardware.
- **Activation:** One server registration associated with a license and installation ID.
- **Activation token:** A credential scoped to one activation. It refreshes entitlements and authorizes eligible downloads.
- **Entitlement:** A compact JWS signed by GlassEQ. It describes the local processing window and release scope for one activation.
- **Management session:** A short-lived credential that can list and release activation slots or rotate the license key.
- **Recovery token:** A single-use credential delivered to the purchase email and exchanged for a management session.

## Credential authority and storage

The purchase email is the ultimate recovery authority. A customer who controls that inbox can create a recovery session, rotate the license key, and manage activation slots.

The license key is a revocable bootstrap and management credential. The customer receives it after purchase and should save it in a password manager. The app uses it for activation but does not persist it. A saved key can activate another Mac or manage slots without an email round trip. Email recovery can rotate the key, which invalidates every saved copy. Rotation does not revoke existing activation tokens unless the customer separately deactivates those installations.

Generate credentials as follows:

| Credential | Generation | Server storage | Client storage |
| --- | --- | --- | --- |
| License key | 128 random bits, Crockford Base32, `GEQ1-` prefix | SHA-256 hash | Never persisted by GlassEQ |
| Installation ID | Random UUID | SHA-256 hash | Keychain |
| Activation token | 256 random bits, Base64URL, `gea_` prefix | SHA-256 hash | Keychain |
| Management token | 256 random bits, Base64URL, `gem_` prefix | SHA-256 hash until expiry | Memory only |
| Recovery token | 256 random bits, Base64URL, `ger_` prefix | SHA-256 hash until use or expiry | Email recipient only |
| Entitlement | Ed25519 compact JWS | Re-creatable from current state | Keychain |

The server checks every cryptographic random-generation result. The display form of a license key may contain hyphens and lowercase letters. Normalization removes hyphens and uppercases ASCII before hashing. It does not perform ambiguous-character substitution.

### Keychain records

The main app stores two non-synchronizable, device-only Keychain items with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:

1. The installation identity, containing the installation ID.
2. One versioned, atomically replaced activation-state value containing the activation token, compact entitlement, highest accepted revision, highest trusted time, last authenticated wall-clock reading, and any clock-anomaly, denial, or deactivation state. A client rejects schema versions newer than it understands.

The entitlement, replay state, and trusted time must not use separate persistence classes. Clearing the activation-state value removes every cached authority that depends on it. The Settings helper never receives the activation token or direct Keychain access.

## Signed entitlement

The entitlement uses JWS Compact Serialization and Ed25519. The server signs the exact ASCII JWS signing input. The client verifies it with `Curve25519.Signing.PublicKey` from CryptoKit.

The protected header contains exactly these fields:

```json
{
  "alg": "EdDSA",
  "kid": "entitlement-2026-01",
  "typ": "glasseq-entitlement+jwt"
}
```

The verifier rejects `crit`, unknown header fields, an unknown key ID, another algorithm, another type, padded or malformed Base64URL, and a token larger than 8 KiB. It verifies the signature before decoding claims. The trusted Go issuer emits each JSON key once; the client uses `Decodable` with exact allowed-key sets rather than maintaining a second JSON parser. It never follows `jku`, `x5u`, or another remotely supplied key reference.

### Common claims

```json
{
  "iss": "https://license.glasseq.app",
  "aud": "com.glasseq.app",
  "sub": "lic_01...",
  "jti": "ent_01...",
  "iat": 1788235200,
  "schema": 1,
  "plan": "monthly",
  "activation_id": "act_01...",
  "installation_id": "4E70638A-...",
  "revision": 17,
  "release_scope": "current",
  "security_updates_after_expiry": true
}
```

| Claim | Rule |
| --- | --- |
| `iss` | Exactly `https://license.glasseq.app` |
| `aud` | Exactly `com.glasseq.app` |
| `sub` | Opaque license ID |
| `jti` | Unique entitlement issuance ID |
| `iat` | Server issuance time in Unix seconds |
| `schema` | Exactly `1` for this protocol |
| `plan` | `perpetual_v1` or `monthly` |
| `activation_id` | Opaque server activation ID |
| `installation_id` | Must match the local Keychain identity |
| `revision` | Monotonically increasing for the activation |
| `release_scope` | `v1` for perpetual v1, `current` for monthly |
| `security_updates_after_expiry` | Whether an expired monthly installation may use the security feed |

The client accepts `iat` up to five minutes ahead of its effective local time. A larger difference reports that the Mac's date and time may be slow. It rejects a revision lower than the highest revision stored for the activation. Unknown schema versions, plans, release scopes, missing claims, unknown claims, and inconsistent claim combinations fail closed.

Perpetual entitlements set `security_updates_after_expiry` to false because they do not expire. Monthly entitlements set it according to the published security-update policy. This claim controls feed selection only. The download service always decides eligibility from current server state.

### Perpetual claims

A perpetual v1 entitlement has `plan` set to `perpetual_v1` and `release_scope` set to `v1`. It omits `billing_state`, `billing_period_end`, `recovery_until`, `refresh_after`, and `exp`.

The app verifies a perpetual entitlement locally at launch but performs no scheduled network refresh. A later refund, chargeback, or server deactivation blocks new activations and official services. It cannot disable the cached offline entitlement.

### Monthly claims

A monthly entitlement adds:

```json
{
  "billing_state": "active",
  "billing_period_end": 1790913600,
  "recovery_until": 1792123200,
  "refresh_after": 1788840000,
  "exp": 1792728000
}
```

`billing_state` is one of `active`, `recovering`, `ending`, `lapsed`, `refunded`, or `charged_back`. The state controls messaging. The signed times control processing.

The verifier requires:

- `iat <= refresh_after <= exp`
- `recovery_until < exp`
- `billing_period_end <= recovery_until` for `active`, `recovering`, `ending`, and `lapsed`
- `exp = recovery_until + 604800`
- All monthly fields to be present
- All perpetual-only combinations to be absent

An expired cached JWS is still parsed after its signature has been verified so the app can display the authenticated reason and dates. It grants no processing or ordinary update access after `exp`. The server never issues a monthly entitlement when its new `iat` is at or after `exp`.

## Monthly time model

Configure Stripe Smart Retries for eight attempts over two weeks. Stripe's final action must cancel the subscription after retries finish. Do not configure Stripe to leave the subscription `past_due` indefinitely.

For an ordinary active monthly subscription:

```text
billing_period_end = current paid billing period end
recovery_until     = billing_period_end + 14 days
exp                = recovery_until + 7 days
```

The app derives local behavior as follows:

| Effective time | Local behavior |
| --- | --- |
| Before `billing_period_end` | Active |
| From `billing_period_end` through `recovery_until` | Continue processing while renewal or recovery can complete |
| After `recovery_until` and before `exp` | Grace warning, processing continues |
| At or after `exp` | Transition to identity processing, stop the tap, retain user data |

If the latest signed `billing_state` is `recovering`, the recovery message asks the customer to update payment details. If the app is merely offline after `billing_period_end`, it says renewal could not be verified. It must not claim a payment failed without an authenticated server response.

A voluntary cancellation at period end sets `recovery_until` to `billing_period_end`. A monthly refund or chargeback sets `recovery_until` to the event's effective time. For those two states, the client ignores the later `billing_period_end` and enters grace at `recovery_until`. A higher-revision entitlement can shorten an earlier conservative window after the app reconnects. An offline app may keep the longer cached window.

`refresh_after` is the only normal refresh schedule. The server sets it to the earlier of seven days after issuance and `exp`. At launch, the app starts a background refresh only when the timestamp has passed. A running app schedules the next check from the same timestamp. Failed checks use bounded exponential backoff with per-process jitter without changing `exp`.

### Clock changes

Clock checks apply only to monthly entitlements.

The app permits up to six hours of backward wall-clock movement. A larger rollback requests an immediate background refresh. If the service is unavailable, GlassEQ keeps processing under the cached entitlement and displays verification messaging. A clock anomaly never causes immediate expiry.

For the current process, advance trusted time with a monotonic clock anchored to the latest authenticated `iat`. Persist the advanced value at bounded license-state checkpoints and clean termination, never from the realtime path. While a monthly entitlement is held, the checkpoint runs at least hourly, so a long-running app never relies on clean termination alone. Across launches, use the greater of the current wall clock and the highest trusted time stored in Keychain. A successful authenticated refresh rebases the floor to the greater of its `iat` and the current wall clock. It also stores that wall-clock reading as the next rollback baseline, so a mistaken forward jump can heal and only a later six-hour backward move is anomalous. The signed `exp`, evaluated against the trusted-time floor, remains the final cutoff.

This is modest replay resistance, not an attempt to defeat a customer who controls an open-source process.

## Server data model

The following logical relational schema is authoritative. Concrete SQL types may follow the selected database, but identifiers are opaque text, timestamps are UTC instants, and hashes are fixed-size bytes.

### `checkout_orders`

| Field | Constraint |
| --- | --- |
| `id` | Primary key and Stripe `client_reference_id` |
| `plan` | `perpetual_v1` or `monthly` |
| `policy_version` | Server-selected version shown at Checkout |
| `stripe_price_id` | Server-selected price |
| `stripe_checkout_session_id` | Unique Stripe reference |
| `state` | `pending`, `paid`, `failed`, or `fulfilled` |
| `license_id` | Unique and nullable until fulfillment |
| `created_at` | Creation time |
| `fulfilled_at` | Nullable fulfillment time |

Checkout fulfillment locks this row and creates at most one license. The browser never supplies a Stripe Price ID, policy version, success URL, or cancellation URL. Stripe owns any local-currency presentation through Managed Payments Adaptive Pricing.

### `licenses`

| Field | Constraint |
| --- | --- |
| `id` | Primary key |
| `plan` | `perpetual_v1` or `monthly` |
| `state` | `active`, `refunded`, `charged_back`, or `revoked` |
| `policy_version` | Version accepted at Checkout |
| `recovery_email_ciphertext` | Authenticated encryption under a server-managed key |
| `recovery_email_lookup` | HMAC of the normalized email under a separate lookup key |
| `stripe_customer_id` | Nullable Stripe reference |
| `stripe_subscription_id` | Unique and nullable, required for monthly |
| `created_at` | Creation time |
| `updated_at` | Last state change |

The recovery email lookup is not a plain hash because email addresses have low entropy. Stripe identifiers may become unavailable after a Managed Payments deletion request. Entitlement state must remain usable without retaining deleted customer details beyond legal and operational requirements.

### `license_keys`

| Field | Constraint |
| --- | --- |
| `id` | Primary key |
| `license_id` | Foreign key to `licenses` |
| `secret_hash` | Unique SHA-256 hash |
| `delivery_ciphertext` | Nullable, temporary authenticated encryption of a newly issued key |
| `delivery_expires_at` | Nullable, no later than seven days after issuance |
| `state` | `active` or `revoked` |
| `created_at` | Creation time |
| `revoked_at` | Nullable revocation time |

Exactly one license key is active per license. Rotation creates a new row and revokes the previous row in one transaction. The delivery ciphertext exists only long enough to send or retry the purchase email, then the service deletes it. Durable credential storage remains hash-only.

### `subscriptions`

| Field | Constraint |
| --- | --- |
| `license_id` | Primary key and foreign key to `licenses` |
| `state` | `active`, `recovering`, `ending`, or `lapsed` |
| `billing_period_end` | Latest paid period end |
| `recovery_until` | End of payment recovery or cancellation time |
| `terminal_at` | Nullable terminal state time |
| `last_paid_invoice_id` | Nullable unique Stripe invoice reference |
| `last_stripe_event_id` | Nullable event that triggered the latest reconciliation |
| `last_reconciled_at` | Time the service last fetched and normalized current Stripe state |
| `updated_at` | Last normalized state change |

The service derives this record from Stripe. It does not expose raw Stripe statuses to the app. Stripe v1 objects do not provide a generic update revision, so the service fetches current object state rather than treating event arrival order as authority.

### `activations`

| Field | Constraint |
| --- | --- |
| `id` | Primary key |
| `license_id` | Foreign key to `licenses` |
| `installation_hash` | SHA-256 hash |
| `token_hash` | Unique SHA-256 hash |
| `state` | `active` or `deactivated` |
| `entitlement_revision` | Monotonic integer, starts at 1 |
| `activated_at` | Initial activation time |
| `last_refreshed_at` | Last successful entitlement refresh |
| `deactivated_at` | Nullable deactivation time |

The pair of `license_id` and `installation_hash` is unique. Re-activating the same installation updates the existing row and rotates its token. Creating a different activation locks the license row, counts active registrations, and fails if two already exist.

### `idempotency_records`

| Field | Constraint |
| --- | --- |
| `scope` | Endpoint operation name |
| `credential_hash` | License-key or management-token hash |
| `idempotency_key` | Caller-supplied UUID |
| `request_hash` | Hash of canonical request fields not already bound by the primary key |
| `status_code` | Original successful HTTP status |
| `response_ciphertext` | Authenticated encryption of the original successful response |
| `created_at` | Creation time |
| `expires_at` | 24 hours after creation |

The primary key is `scope`, `credential_hash`, and `idempotency_key`. The service stores only successful operations that created or restored state. An identical retry of a stored success receives the original status and body, while reuse with another body returns `idempotency_conflict`. Failed operations are evaluated again and are not retained for replay. The encrypted response permits exact replay without retaining activation-token plaintext indefinitely. A bounded background job deletes expired records. Durable activation storage remains hash-only.

### `stripe_events`

| Field | Constraint |
| --- | --- |
| `stripe_event_id` | Primary key |
| `event_type` | Stripe event type |
| `object_id` | Primary Stripe object reference |
| `stripe_created_at` | Event creation time |
| `processed_at` | Nullable completion time |
| `outcome` | Bounded processing result |

Do not retain the complete webhook body after processing unless an explicit operational or legal requirement justifies it.

### `access_tokens`

| Field | Constraint |
| --- | --- |
| `token_hash` | Primary key |
| `license_id` | Foreign key to `licenses` |
| `purpose` | `management` or `recovery` |
| `created_at` | Creation time |
| `expires_at` | Expiry time |
| `consumed_at` | Nullable, required after recovery use |

Management tokens expire after 15 minutes. Recovery tokens expire after 30 minutes and are single use.

### `releases`

| Field | Constraint |
| --- | --- |
| `id` | Primary key used in archive URLs |
| `version` | Unique semantic release version |
| `major_version` | Integer release major |
| `channel` | `v1`, `stable`, or `security` |
| `is_security_fix` | Whether expired monthly licenses may download it |
| `archive_storage_key` | Server-side object identifier, never client supplied |
| `archive_sha256` | Published archive checksum |
| `published_at` | Publication time |

## HTTP protocol

The licensing API origin is `https://license.glasseq.app`. Requests and responses use UTF-8 JSON with `Content-Type: application/json`. The default maximum body size is 16 KiB. The Stripe webhook has a separate 1 MiB raw-body limit.

Bearer credentials use the `Authorization` header. License keys appear only in activation or management-session JSON bodies. No credential appears in a query string.

Error responses have a stable machine code and a server-generated request ID:

```json
{
  "error": {
    "code": "activation_limit",
    "message": "This license already has two active Macs.",
    "retryable": false,
    "request_id": "req_01..."
  }
}
```

The app localizes known codes instead of displaying server text directly. Supported codes are:

- `invalid_request`
- `invalid_credentials`
- `activation_limit`
- `activation_revoked`
- `license_not_eligible`
- `release_not_eligible`
- `idempotency_conflict`
- `rate_limited`
- `temporarily_unavailable`

Rate-limited responses use status 429 and a bounded `Retry-After` header. A 503 `temporarily_unavailable` response may also carry `Retry-After`, notably when a database lock is busy. Authentication errors do not reveal whether a license, email, activation, or token exists.

## Purchase and activation API

### Create a Checkout Session

```http
POST /v1/checkout-sessions
Content-Type: application/json
```

```json
{
  "plan": "monthly"
}
```

```json
{
  "checkout_url": "https://checkout.stripe.com/c/pay/..."
}
```

The only accepted plans are `perpetual_v1` and `monthly`. The server creates the pending order, chooses every Stripe and policy parameter, enables Managed Payments, and then returns Stripe's hosted Checkout URL. It rate-limits creation per IP address.

### Create or restore an activation

```http
POST /v1/activations
Idempotency-Key: 2b1bc1ba-407a-49f2-ad2e-a260a56bcf23
Content-Type: application/json
```

```json
{
  "license_key": "GEQ1-...",
  "installation_id": "4E70638A-..."
}
```

A new activation returns status 201. Re-activating the same installation with a new idempotency key returns status 200 and rotates its activation token. An idempotent replay of either successful response returns its original status and body. Failed activation attempts are not cached.

```json
{
  "activation_token": "gea_...",
  "entitlement": "eyJhbGciOiJFZERTQSIs..."
}
```

The server validates the key, plan, license state, and installation ID. It performs the two-activation check and creation in one transaction. An existing installation does not consume another slot. A request that reaches the two-device limit returns status 409 with `activation_limit`.

The server rate-limits this endpoint per license-key hash and per IP address.

### Refresh an entitlement

```http
POST /v1/entitlements/refresh
Authorization: Bearer gea_...
Content-Type: application/json
```

```json
{
  "installation_id": "4E70638A-..."
}
```

```json
{
  "entitlement": "eyJhbGciOiJFZERTQSIs..."
}
```

The activation token and installation ID must resolve to the same active activation. Each successful issuance increments the activation revision before signing.

A monthly license can receive a `lapsed`, `refunded`, or `charged_back` entitlement while its signed grace window remains open. After `exp`, the endpoint returns status 403 with `license_not_eligible`; the app retains the expired signed entitlement for authenticated dates and presents renewal UI. A deactivated activation returns status 403 with `activation_revoked`. Perpetual clients do not call this endpoint on a schedule.

### Deactivate the current installation

```http
DELETE /v1/activations/current
Authorization: Bearer gea_...
```

The operation is idempotent and returns status 204. It releases the server registration and revokes the activation token. The service retains the token hash on the deactivated row so a retry of this specific operation can still return 204, while every other use fails. After success, the current app removes its local activation state and returns to dry playback.

## Management and recovery API

### Create a management session with a license key

```http
POST /v1/management-sessions
Content-Type: application/json
```

```json
{
  "license_key": "GEQ1-..."
}
```

```json
{
  "management_token": "gem_...",
  "expires_at": 1788236100
}
```

The server rate-limits this endpoint per license-key hash and per IP address. The app holds the management token only in memory.

### List activations

```http
GET /v1/management/activations
Authorization: Bearer gem_...
```

```json
{
  "activations": [
    {
      "id": "act_01...",
      "activated_at": 1785643200,
      "last_refreshed_at": 1788235200
    }
  ]
}
```

The response contains no device name, model, architecture, OS version, or hardware identifier.

### Release an activation slot

```http
DELETE /v1/management/activations/act_01...
Authorization: Bearer gem_...
```

The operation returns status 204 and is idempotent.

Deactivation releases the server registration and revokes its activation token. It does not remotely disable the cached entitlement on that Mac. A monthly entitlement remains usable until its signed `exp`. A perpetual entitlement remains usable forever. Remotely disabling a stolen Mac with a perpetual entitlement is outside the offline threat model.

### Request email recovery

```http
POST /v1/recovery-requests
Idempotency-Key: 931ea290-c176-4d1e-ab5b-10c107e7d978
Content-Type: application/json
```

```json
{
  "email": "customer@example.com"
}
```

The endpoint always returns status 202 with the same body, whether or not the email exists:

```json
{
  "accepted": true
}
```

Rate limits apply per normalized-email HMAC and per IP address. The email contains a short-lived URL whose secret is in the fragment, not the query string. The recovery page reads the fragment, clears it from browser history, and posts the token to the API. Referrer policy is `no-referrer`.

### Exchange a recovery token

```http
POST /v1/recovery-sessions
Idempotency-Key: 2b1bc1ba-407a-49f2-ad2e-a260a56bcf23
Content-Type: application/json
```

```json
{
  "recovery_token": "ger_..."
}
```

The response matches the management-session response. The exchange consumes the recovery token in the same transaction.

### Rotate the license key

```http
POST /v1/management/license-key-rotations
Authorization: Bearer gem_...
Idempotency-Key: 80cbbaf8-a9a4-4920-80a7-3aa29d25b309
```

```json
{
  "license_key": "GEQ1-..."
}
```

The new key is shown once. Rotation invalidates every saved copy of the previous key. It does not deactivate installations.

## Stripe ingestion

The Stripe adapter uses one pinned API version and maps Stripe objects into the internal model. No Stripe status or identifier appears in an app entitlement. Managed Payments currently requires a preview API version, so production work must verify the current version and event contract again before launch.

```http
POST /v1/stripe/webhooks
Stripe-Signature: ...
```

The endpoint reads the raw body, enforces the 1 MiB limit, and verifies Stripe's signature with the official server library and its normal timestamp tolerance. It records the event ID before enqueueing work and returns a 2xx response promptly. Processing is idempotent by event ID and by the affected domain record.

Stripe does not guarantee event order and can deliver duplicates. A worker fetches the current Checkout Session, Invoice, Subscription, Refund, or Dispute when the embedded event state is insufficient or could be stale. An older event never moves a subscription period or entitlement revision backwards.

Listen only for required events from the pinned Stripe version:

- `checkout.session.completed`
- `checkout.session.async_payment_succeeded`
- `checkout.session.async_payment_failed`
- `invoice.paid`
- `invoice.payment_failed`
- `invoice.updated`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `refund.created`
- `refund.updated`
- `refund.failed`
- `charge.dispute.created`
- `charge.dispute.closed`

### Purchase fulfillment

Checkout creation chooses the Stripe Price ID, quantity, Managed Payments setting, policy version, success URL, and cancellation URL on the server. The browser cannot supply a price or arbitrary return URL. Checkout requires acceptance of the versioned terms. Managed Payments may present the purchase in a supported local currency.

A perpetual purchase is fulfilled once only after the retrieved Checkout Session has the expected Price ID, product, quantity, mode, Managed Payments setting, consent, and successful payment state. Delayed methods wait for `checkout.session.async_payment_succeeded`.

A monthly purchase is fulfilled only after the initial invoice is paid and the retrieved subscription is active. `incomplete`, `incomplete_expired`, `paused`, and unpaid initial states never receive a license.

Fulfillment creates the license and first license key in one transaction. It stores a temporary encrypted delivery copy for the email worker and deletes that copy after successful delivery or its seven-day limit. The success page may show a pending state while webhook processing completes. Email recovery remains available if delivery fails.

### Subscription normalization

- `invoice.paid` advances `billing_period_end`, returns the normalized state to `active`, and computes a new two-week `recovery_until`.
- `invoice.payment_failed` or the related `invoice.updated` moves the state to `recovering` while Stripe continues scheduled retries.
- Cancellation at period end moves the state to `ending` and sets `recovery_until` equal to `billing_period_end`.
- `canceled` or `unpaid` after retry exhaustion moves the state to `lapsed`.
- A successful later payment advances the period and restores `active` state.
- A monthly refund or chargeback moves the entitlement timeline to a seven-day grace period starting at the event's effective time.
- A perpetual refund or chargeback blocks new activations, downloads, updates, and support without changing cached offline entitlements.
- A won or withdrawn dispute restores service only after the current Stripe objects confirm that the purchase remains paid.

Partial refunds do not revoke a license automatically. They require an explicit operator decision recorded against the license.

## Update authorization

Appcasts and release notes are public. Archives are authorized by the download service at `https://downloads.glasseq.app`.

The client chooses one public feed:

| Entitlement state | Feed behavior |
| --- | --- |
| Perpetual v1 | v1 feed |
| Monthly active, recovery, or grace | Stable feed |
| Monthly expired and security eligible | Security-only feed |
| Expired and not security eligible | No automatic check; show Renew to Update |

The app disables Sparkle system profiling. It does not use Sparkle's global `httpHeaders` property for authorization because those headers also apply to appcasts and release notes.

Before presenting a selected update, `shouldProceedWithUpdate` validates the enclosure origin and rejects a mismatch. Immediately before an archive download, `willDownloadUpdate` repeats the validation before adding authorization. Both checks require all of the following:

- Scheme is exactly `https`
- Host is exactly `downloads.glasseq.app`
- Port is absent or exactly `443`
- URL has no user information
- Path starts with `/v1/releases/` and ends with `/archive`

Only then does it attach `Authorization: Bearer gea_...`. Any mismatch aborts the update without sending the token. The download service must stream the archive directly and must not redirect. A 3xx response is a protocol failure.

```http
GET /v1/releases/rel_01.../archive
Host: downloads.glasseq.app
Authorization: Bearer gea_...
```

The server resolves the release ID from its own immutable release record and applies current license state:

- An active perpetual v1 license may download releases whose major version is 1.
- A monthly license whose current server state is eligible and whose entitlement has not reached `exp` may download the current stable release.
- An expired monthly license may download only a release marked as a security fix.
- A refunded, charged-back, revoked, or deactivated credential receives status 403.

The server does not trust a version, channel, file path, or release scope supplied by the client. A 403 maps to licensing or renewal UI, not a generic network error.

Sparkle still verifies its EdDSA archive signature, and macOS still verifies the Apple code signature. Entitlement signing keys, Sparkle signing keys, Apple signing keys, Stripe secrets, and data-encryption keys remain separate.

## Application state and audio behavior

One licensing owner coordinates Keychain state, refresh work, and clock handling. It publishes immutable snapshots to the main app. Settings license DTOs and update authorization are not implemented yet; when added, Settings must not perform license network requests itself.

The client-visible states are:

- `unlicensed`
- `perpetual`
- `monthlyActive`
- `monthlyRecovery`
- `monthlyGrace`
- `monthlyExpired`
- `verificationNeeded`
- `invalidEntitlement`
- `storageUnavailable`

An invalid signature, wrong audience, wrong installation, unknown key, impossible timestamp relationship, or rollback to an older revision never authorizes processing. A transient network failure does not invalidate a correctly signed cached entitlement. A Keychain read failure is `storageUnavailable`: the cached state is unknown, so processing is not permitted and the read is retried on the refresh backoff. It is reported separately from an invalid entitlement.

A `403 license_not_eligible` answer to a refresh is persisted in the activation-state record as a server denial. After a refund, the server's shortened grace window can end while the cached JWS still carries a later `exp`; the persisted denial keeps the installation in `monthlyExpired` across an offline relaunch. Only a successful refresh or a new activation clears it.

A `403 activation_revoked` or `401 invalid_credentials` answer to a refresh means the activation token is gone, for example because the slot was released from another Mac. The server deliberately returns the same permanent `invalid_credentials` response when the request's installation ID does not match the token. The client therefore records either code as permanent service revocation and stops refreshing, but it does not erase the signed entitlement: a monthly license keeps processing until its signed `exp`, and a perpetual license keeps processing indefinitely, exactly as the management API section promises.

Local deactivation writes a tombstone into the activation-state record before sending the request. From that point the installation is unlicensed even if the request or the Keychain deletion fails; the idempotent request and the deletion are retried on the bounded schedule, including after a relaunch. If activation succeeds remotely but its entitlement cannot be verified or the active record cannot be saved, the client retains the token in a cleanup-only tombstone and uses the same retry path. Activation refuses to replace any existing record, including an unfinished tombstone, so the old server slot cannot become unreachable.

Storage failures and network failures keep separate retry schedules. A recovered Keychain failure never escalates the next refresh retry, and a storage retry never suppresses an earlier `refresh_after`. An overdue trusted-time checkpoint is written immediately after launch rather than waiting for the next signed boundary.

When monthly processing reaches `exp`, the main app requests the normal click-free transition to identity filters and unity preamp. The publication returns an exact transition ID, and the app stops and destroys the tap only when the render thread reports that same ID complete. If the app launches in an expired state, it never starts the tap. Profiles, mappings, imports, and calibration records remain available.

Renewal follows the ordinary startup path only when the user still wants processing enabled. An explicit user stop remains stopped across license loss and renewal. Licensing does not publish state from a network callback to the render thread.

## Key and secret management

Keep the entitlement private key, reserved rollover key, Stripe API key, Stripe webhook secret, email lookup key, database encryption key, idempotency-response key, Sparkle private key, and Apple signing credentials outside the repository and release artifacts. Give the service access only to the secrets required by its deployed role.

The first production app embeds public entitlement keys for one active signer and one reserved rollover signer. Store the reserved private key separately from the active service key. Switching to the reserved signer requires no client update. A later app release adds another public rollover key before the service begins using it.

Do not remove a public key while a supported monthly client may still hold entitlements signed by it. A compromised signing key requires a new signed app release, a new entitlement key, and server-side denial of service access associated with forged credentials. Perpetual offline entitlements signed by a compromised key cannot be revoked remotely.

Logs record opaque request IDs, result codes, and bounded timing. They never record license keys, bearer tokens, recovery tokens, entitlement bodies, email addresses, Stripe payloads, or archive authorization headers.

## Verification requirements

### Entitlement parser

- Valid perpetual and monthly tokens
- Unknown, missing, and inconsistent claims
- Unknown schema, plan, release scope, algorithm, key ID, and type
- Any `crit` header
- Invalid signature and modified header or payload
- Padded, malformed, oversized, and non-UTF-8 data
- Five-minute future `iat` boundary
- Revision rollback
- Wrong installation, issuer, or audience
- A fixed token emitted by the Go issuer and verified by the Swift client
- Every exact second around `billing_period_end`, `recovery_until`, and `exp`

### Server

- Duplicate and out-of-order Stripe events
- Delayed Checkout success and failure
- Concurrent activation attempts at the two-device boundary
- Activation timeout followed by an identical retry
- Idempotency-key reuse with another body
- Reactivation of the same installation
- Current and remote deactivation
- License-key rotation and stale-key rejection
- Recovery enumeration and rate limits
- Renewal, retry recovery, voluntary cancellation, refund, chargeback, and won dispute
- Release authorization for every plan, major, state, and security flag
- A redirect attempt from the archive endpoint
- Secret redaction from logs and errors

### Packaged app

- Keychain behavior with the production application identifier and sandbox
- No credential access from the Settings helper
- Launch while active, in recovery, in grace, expired, and offline
- Six-hour clock boundary and larger rollback while offline
- Long-running refresh scheduling from `refresh_after`
- Expiry while audio is running, including a verified click-free return to dry playback
- Both audio backends reporting completion for the exact identity-bank publication before the tap stops
- Renewal after expiry
- Sparkle download authorization to the exact archive origin
- Token omission and update abortion for another host, port, path, or redirect
- Disabled Sparkle system profiling
- A 403 presented as license state rather than download failure

## External references

- [Stripe Smart Retries](https://docs.stripe.com/billing/revenue-recovery/smart-retries)
- [Stripe subscription states](https://docs.stripe.com/billing/subscriptions/overview)
- [Stripe webhook handling](https://docs.stripe.com/webhooks)
- [Stripe Checkout fulfillment](https://docs.stripe.com/checkout/fulfillment)
- [Stripe Checkout consent](https://docs.stripe.com/api/checkout/sessions/create)
- [Stripe refund events](https://docs.stripe.com/refunds)
- [Sparkle updater headers](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html)
- [Sparkle updater delegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
- [Sparkle system profiling](https://sparkle-project.org/documentation/system-profiling/)
- [CryptoKit Ed25519 signing](https://developer.apple.com/documentation/cryptokit/curve25519/signing)
