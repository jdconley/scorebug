# Native Watch scoring relay

Next implementation checkpoint of the portable streaming/Watch plan. Use
brainstorming and writing-plans, then TDD with bounded implementation tasks and
independent specification/quality review. Do not overlap test/build execution with
native media qualification. This plan preserves native scoring on either phone
or either Watch/phone pair; no browser scorer is introduced.

## Source assessment

`WatchSetupConnectivity` exchanges replacement setup/identity application context
only. It has no scoring request/reply transport. Direct Watch `URLSession` may use
OS-selected networking, but that is distinct from an application command relay.

`MatchCommandCoordinator` already owns durable command identity, one pending
operation, receipt-first recovery, expiry/revision/scorer checks and authoritative
acknowledgment. It currently depends on concrete `MatchHTTPClient`; the three
operations it needs are snapshot, execute and receipt. That client has a 20-second
request timeout, while command retry age is 10 seconds. Waiting for the entire HTTP
timeout before trying a companion would often make a fresh command unreplayable.

`PhoneWatchModel` clears its pending issuance record after paired confirmation.
It does not retain an authorized endpoint/match/Watch association for a relay.
The bridge is already app-owned as a StateObject; activation is driven by the
foreground view lifecycle. Background companion activation needs qualification,
and relay handling must remain independent of the selected tab or phone scorer.

## Typed foundation

1. Introduce a small Sendable scoring-client interface for snapshot, execute and
   receipt. Make the HTTP client conform, preserving coordinator behavior and all
   existing callers. Keep setup, installation authority, camera and publishing
   operations outside this interface.
2. Define a separate strict, bounded request/reply codec, not an arbitrary HTTP
   request or URL proxy. Include request identity, canonical endpoint scope, match,
   Watch device identity and pairing generation. Represent only the three allowed
   operations with their existing typed command/outcome/snapshot contracts. Choose
   byte/count bounds against actual protocol fixtures before implementation.
3. Persist an authorized nonsecret pairing association on the phone before clearing
   completed setup. Failed persistence must not activate relay. Restore that binding
   on launch and invalidate in-flight operations on peer/configuration changes.
4. Forward the Watch's scoped score credential and exact immutable command, never
   the phone's credential or installation token. The credential may be transient
   request data needed for existing server authentication; never retain it in the
   phone binding or diagnostic logs. Validate the request against the stored binding
   and existing endpoint/declared-role/identity rules before any HTTP dispatch.
   A declared score role does not authenticate an opaque bearer token: the server
   must still validate that credential on every allowed scoring request. Reject
   installation-authority operations locally, and never supply the phone's token
   as a replacement for an invalid Watch credential.

## Routing and lifecycle

1. Add bounded request/reply ownership to the existing companion session; do not
   compete for its delegate or replace the setup codec. Bound active requests and
   response bytes, correlate replies and ignore terminal/stale callbacks.
2. Let direct HTTP use OS-selected networking. Add reachable companion messaging as
   an additional route with finite attempt deadlines. Decide initial ordering and
   deadline values using an explicit timing budget smaller than command retry age;
   test them under injected clocks before choosing physical defaults.
3. A mutation timeout is uncertain, never a rejection or automatic permission to
   resend elsewhere. Preserve the coordinator outbox and query its receipt before
   another mutation attempt. Snapshot/receipt fallback may use another route, but
   a transport wrapper must not replay an execute operation blindly.
4. Cancellation must terminate local request ownership and join owned HTTP work;
   a sent companion message cannot be unsent. Retain command uncertainty and reject
   late replies by immutable generation/request scope. Success haptics still require
   the authoritative outcome after durable local acknowledgment.
5. Activate and retain phone handling at app scope, including the relevant native
   background launch path. Filming phone A can relay Watch A; phone B can relay
   Watch B while A films. Neither relay depends on capture ownership or the phone's
   current scorer identity.

## Required checks

- Direct-route failure followed by companion receipt/snapshot/command success uses
  the original Watch identity and exact command.
- Server commit followed by lost relay reply recovers one receipt and one mutation.
- Cancellation, duplicate delivery, peer switching and late replies cannot alter
  newer state or acknowledge another scope. Failures retain pending work.
- Expiry, takeover, revision conflicts, authentication failures and domain rejection
  preserve existing coordinator decisions.
- Malformed/oversized requests, arbitrary endpoints, wrong scopes/generations,
  and installation-authority/capture/publish operations fail before dispatch.
  Invalid opaque credentials fail server authentication without fallback to the
  phone's installation authority.
- Failed binding persistence prevents relay; restored bindings are checked again.
- Injected app-level relay runs while recording remains active, with distinct Watch
  A and Watch B receipts. Existing phone scoring remains native and independent.

Compile supported iPhone/Watch targets and rerun appropriate Core/native model
tests before isolated simulator integration. Simulator protocol tests cannot prove
physical companion delivery, suspension or radio switching. Repeat on Ultra 2 and
Series 7 with normally launched apps, paired filming, other-pair scoring, Wi-Fi and
cellular where available, retaining one server outcome per action and clean media.

## Follow-on still required

Initial Watch redemption currently requires direct HTTP. Add a separately bounded
bootstrap redemption relay after configured scoring works; the recovery-key and
capability rules must remain intact. Neither a configured-only relay nor model
tests complete the user's all-available-networking requirement by themselves.

## Scoring-client foundation implemented

`MatchScoringClient` now supplies the three Sendable operations. The HTTP client
conforms, and the coordinator accepts the interface without changing its command
or recovery logic. Receipt absence must be authoritative; transport uncertainty
throws and retains pending work. Setup and installation operations remain outside
the interface.

Three tests use a non-HTTP actor and real durable outbox to prove persistence before
send, Watch identity/credential preservation, receipt-only recovery after a lost
committed reply, and exact-command retry after confirmed absence plus a fresh
snapshot. They pass after the expected missing-interface compile failure. All 122
Core tests, 27 Watch model tests, and 9 phone companion model tests pass. The Release
iPhone build also builds both arm64 and arm64_32 Watch targets successfully.
Independent specification/quality review finds no issues. Evidence is under
`artifacts/qa/watch-scoring-client-*.log`.

The 85 Film model tests also pass, including recording/streaming lifecycle and
fixture media regression coverage. All verification commands terminated with exit 0.

That checkpoint implements typed foundation step 1. Subsequent codec and binding
work is tracked in the [codec contract](2026-09-15-native-watch-relay-codec.md) and
[atomic binding design](2026-09-15-native-watch-relay-binding.md). The Watch model
still uses HTTP until the companion client is wired into app-scoped request
ownership. Routing, background lifecycle and bootstrap relay remain required.

## Native networking integration references

Configure and activate the existing single WCSession delegate before messages
arrive. Immediate messages require a reachable counterpart, and delegate callbacks
arrive on a background thread. Keep the bounded request owner at app scope rather
than the setup tab. See [Apple's WCSession documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession).

Direct URLSession remains useful alongside the explicit companion relay: the OS
can route Watch requests through its paired phone, known Wi-Fi or cellular. Each
route still needs physical testing; simulator protocol checks cannot establish
radio switching. See [Keeping watchOS content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date).

## Next native integration checkpoints

Continue with [bounded companion request ownership](2026-09-15-native-watch-relay-transport.md),
then the [scoped phone forwarder](2026-09-15-native-watch-relay-forwarder.md).
Keep the existing single WCSession delegate. Install message byte/admission bounds
before crossing into MainActor; activate at application start and restore the
phone binding before admitting relay requests, independent of active-scene setup UI.
The Watch model needs a separate scoring-client factory accepting full paired
setup and returning `any MatchScoringClient`; its bootstrap HTTP factory remains
separate until the explicitly planned redemption relay is implemented.

App wiring must invalidate local session/request generations on actual WC peer
changes, while preserving unordered application-context handling. Test the linked
client/transport/forwarder path under injected callbacks before simulator attempts.
Physical delivery, background suspension and radio switching remain unverified.

A Watch's outgoing paired notice does not acknowledge successful phone persistence.
A first relay attempt can legitimately encounter a temporary scope mismatch while
confirmation is being saved. Preserve command uncertainty and recover through the
normal receipt path; do not infer rejection or create a replacement command ID.

## Codec, client and phone association checkpoint

The strict scoring codec and `WatchRelayScoringClient` are implemented. The client
preserves immutable commands and Watch credentials, validates correlated replies,
and leaves retries to the durable coordinator. Nine client tests include a real
file outbox recovering a committed command after its relay reply is lost, plus
cancellation before dispatch and after a late reply. Independent review approved
the codec and client. All 144 Core tests passed (`watch-relay-core-full.log`).

Phone setup now persists one atomic version-2 Keychain record, migrates existing
pending setup, and installs a canonical nonsecret relay association only after a
matching confirmation is saved. Unordered notices cannot revoke that association.
Actual peer changes invalidate it and require fresh setup before reusing retained
pending issuance; the persisted gate prevents a delayed confirmation from reviving
an invalidated association. All 33 phone model tests passed after expected regression
failures (`watch-relay-peer-gate-{red,green}.log`). Parent reviewed the final gate.

All 27 Watch model tests also passed (`watch-relay-watch-models.log`). The Release
iPhone build passed with arm64 and arm64_32 Watch code after correcting the codec's
native integer bound (`watch-relay-phone-release.log`). That build preceded the
final phone-only peer gate; the final gate is compiled and tested by the phone model
suite. Repeat Release validation after the bounded transport is added.

These are local protocol/model checks, not completed WatchConnectivity integration.
The app still uses direct HTTP for Watch scoring until the next wiring checkpoint.
