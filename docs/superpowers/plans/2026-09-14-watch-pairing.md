# Recoverable native Watch pairing

First implementation slice of the approved Watch milestone. The native phone and
Watch apps will exchange a short-lived setup capability; the Watch will redeem it
for its own match-scoped scoring credential. The Watch receives no installation
token, camera role, or publish grant. Direct HTTP scoring remains available through
the OS-selected network route. Pairing does not take over scoring.

## Existing foundations

`MatchStore.issueCredential` already provides stable device/role credentials and
does not change scorer ownership. Existing `/join` requires installation authority
and retains that requirement. `MatchCommandCoordinator` already persists uncertain
scoring commands and reconciles receipts. The iPhone `ScoringModel` stores an
installation token, so it cannot serve as Watch setup storage unchanged.

## Contract and persistence

1. Add installation-authorized `POST /v1/matches/:id/watch-pairings`, strict body
   `{ pairingId, watchDeviceId }`. The native phone persists its random issuance ID
   before sending. Return pairing/match/Watch identity, fixed `score` role, capability,
   expiry, and server time. The capability has high entropy and a five-minute life.
   Exact issuance retries return the same token and expiry; changed requests conflict.
   Either configured phone can issue it, independent of capture or scorer ownership.
2. Add `POST /v1/matches/:id/watch-pairings/:pairingId/redeem`, capability bearer auth,
   strict `{ redemptionId, deviceId }`, and a Watch-generated secret recovery key in
   a dedicated header. The Watch atomically persists its exact redemption attempt
   before making the request. First redemption requires an active match, matching
   device, and unused/unexpired capability. It can issue only a scoring credential.
3. In one SQLite transaction, check for an exact prior redemption before applying
   first-redemption expiry rules. A matching retry with its recovery key returns the
   same committed credential even after capability expiry. A different device,
   redemption ID, or recovery key cannot recover that result. A never-redeemed expired
   token remains unusable. No separate receipt route is needed for this slice.
4. Persist canonical issuance/redemption requests, fixed expiry, secret digests,
   and credential identity. Use a distinct HMAC domain for repeatable capabilities;
   do not store bearer secrets in SQLite or logs. Bound issuance per match, and
   preserve committed uncertainty records for the match's retention lifetime.
   Credential-key changes fail closed for old redemption results.
5. Refactor credential creation into a transaction-internal helper: the existing
   public method starts `BEGIN IMMEDIATE`, so calling it inside redemption would
   create a nested transaction. Credential creation, capability consumption, and
   redemption receipt must commit together, including across competing processes.

## Shared Watch setup coordinator

Use Foundation-only contracts and injected storage/HTTP transport. Keep a Watch-local
device UUID and a setup record with no installation-token field. Pending redemption
contains normalized endpoint, pairing capability/identity, exact redemption ID,
device ID, and recovery key. Native adapters will store this in device Keychain.

Persist before sending, retain the exact attempt through timeout/cancellation, and
validate all response identities, role, and snapshot before committing the returned
credential. A failed local save after server success leaves the pending attempt
recoverable. Construct the existing scoring coordinator only after that commit.
Scope scoring outboxes by normalized endpoint and credential fingerprint. Old setup
messages cannot overwrite unresolved redemption or pending scoring work. No setup,
retry, or restoration path sends `takeOver` automatically.

The later companion envelope carries only the configured endpoint, match, target
Watch ID, capability, and expiry. It does not carry the eventual Watch credential
or recovery key. Manual short numeric codes require a separate bounded guessing
design; do not truncate the high-entropy capability for this implementation slice.

## Implementation and verification order

1. Shared protocol contracts and fixtures; server transaction tests and routes.
   Cover lost issuance/redeem replies, exact retry after expiry and process restart,
   concurrent redemption, wrong identity/role/secret, strict malformed bodies, expired
   unused tokens, capacity limits, credential-key changes, and no match revision or
   scorer/capture/broadcast mutations. Keep existing join behavior unchanged.
2. Swift Codable/client methods, mirrored fixtures, and durable setup coordinator.
   Cover pre-send save failure, post-success save failure, cancellation/relaunch,
   stale responses, endpoint changes with pending work, and immutable retries.
   Run Core tests and compile watchOS 10 arm64_32 and iOS 17 targets.
3. Independent specification review followed by quality review and final regression
   checks. Commit this bounded foundation before connecting the Watch UI.

Expected files: shared `packages/protocol/src/` contracts and fixtures;
`apps/control-plane/src/matches-store.ts`, match routes, and tests;
`ios/Packages/ScorebugCore/` client, new pairing/setup types, coordinator, and tests.

## Native follow-on

Add the watchOS target and typed companion setup flow to the full native phone app,
then home/away score, undo, pending/confirmed states, explicit takeover, guarded set
and match completion, and refresh/recovery on wake. Test Watch A while phone A films,
then Watch B/phone B while phone A films. Use Series 7 41 mm, Ultra 2, and SE layouts.
Companion command fallback, Wi-Fi/cellular handoff, real wrist suspension, and
physical-device reliability require their own qualification; Core tests and
simulator networking do not certify those routes.
