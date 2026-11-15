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

Update: the [bootstrap relay](2026-09-15-watch-bootstrap-relay.md) now adds initial
setup to the companion route and is wired into both native apps. Follow
that document for current integration evidence and remaining physical gates.

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

Physical availability changed at this checkpoint: `devicectl list devices` now
reports the iPhone 16 Pro and Apple Watch Ultra 2 as available (paired), with command
exit 0 (`watch-relay-device-availability.log`). This is device discovery only;
installation/signing, running apps and real relay delivery have not been qualified.
Attempt those after app-scoped forwarding and native session wiring are tested.

The [bounded message owner](2026-09-15-native-watch-relay-transport.md) is now
implemented and independently reviewed. Full Core passes 159 tests; the Release
app build passes with both Watch architectures and the final phone pairing gate.
The next concrete implementation task is the scoped phone HTTP forwarder, followed
by the existing-session native adapter and Watch scoring-client injection.

## Provisional native routing budget

Add a bounded direct HTTP transport and a per-pairing routed scoring client before
selecting the companion client in the Watch app. Direct HTTP remains the first
route so the OS can use its available networking. Retain a route that answers
successful reads; after an uncertain execute, prefer the alternate route for
receipt recovery. Each execute uses exactly one route. Reads may fall back only
for recognized connectivity failures or companion unavailable/busy/scope mismatch.
Cancellation, authorization, malformed responses and authoritative HTTP errors
must propagate. Domain outcomes and authoritative receipt absence keep their meaning.

Configure native direct and companion attempts to two seconds, with phone forwarding
nested at 1.5 seconds. Library defaults remain configurable. Direct HTTP needs an
absolute monotonic deadline with cancellation/join ownership, not only a URLRequest
inactivity timeout. Test its timer with injected clocks and cancellation-ignoring
HTTP work before use. A bounded transport can be injected into MatchHTTPClient;
it must not mutate the caller's URL, headers or body beyond its timeout setting.

After an uncertain execute, perform one immediate coordinator receipt-first recovery
inside the current Watch model operation. Do not add the two-second polling wait.
The ordinary one-switch sequence is 2 seconds initial execute + 2 receipt + 2 fresh
snapshot (if absent) + 2 exact original-command retry = 8 seconds, leaving nominal
margin within the existing ten-second retry age. Additional read fallbacks, delayed
cancellation joins or suspension can exceed this envelope; preserve the fresh server
age checks and explicit reconciliation. Receipt lookup can still recover a committed
command after retry expiry. These defaults require physical latency qualification.

## Routed native scoring checkpoint

The forwarder, existing-session adapter and production Watch scoring factory are
now connected. Phone relay setup is restored independently of foreground setup UI.
The Watch factory receives the complete persisted pairing; a failed replacement
disables the old scorer and remains retryable. Bootstrap redemption still uses its
separate HTTP client.

`MatchHTTPDeadlineTransport` supplies an absolute deadline and joins canceled HTTP
work before returning. `WatchRoutedScoringClient` initially uses direct HTTP, retains
a successful route and sends each execute through exactly one route. Recoverable
execute failures remember an alternate route for that command's receipt; reads can
use one alternate. Authorization, malformed data, cancellation and authoritative
server errors do not cause route fallback. The Watch model performs one immediate
receipt-first recovery under the same operation ownership, preserving durable
acknowledgment before success haptics. The provisional 2/2/1.5-second native budget
above is implemented and remains subject to physical measurement.

Core passes 193 tests, including 13 forwarder, nine deadline and 12 router tests.
Watch passes 43 model/gate tests and phone companion passes 34 model tests. All
commands terminated with exit 0. Evidence:

- `artifacts/qa/watch-relay-routed-core-full.log`
- `artifacts/qa/watch-immediate-recovery-green.log`
- `artifacts/qa/watch-relay-background-restore-green.log`
- `artifacts/qa/watch-relay-routed-native-release.log` (Release iPhone plus both Watch architectures)

Independent review approved final immediate recovery, production factory wiring,
router cancellation ownership and the native peer-transition gate. The review of
the forwarder caught malformed HTTP decoding being classified as connectivity;
the new failing regression and corrected classification are retained. App-level
recording integration, bootstrap relay and physical networking remain outstanding.

### Physical-device readiness, read-only check

The connected iPhone 16 Pro reports iOS 26.6.2 and the Ultra 2 reports watchOS 26.6;
both have Developer Mode enabled and developer services available. This is fresh
device discovery, not an app installation or WatchConnectivity result. The local
wildcard development profiles include this phone but omit this Watch. No signing
team has been selected for Scorebug and no developer-account registrations have
been changed. Complete the local integration and bootstrap path before resolving
Watch provisioning and beginning physical acceptance tests.

## Recording integration and final error taxonomy

The injected native integration now passes with two distinct Watch/phone pairs
and one real `FixtureCameraSource` / `FilmModel` local recording. Watch A's committed
point loses its reply, keeps a durable pending command with no success haptic, then
recovers the exact receipt. Watch B takes over and scores while the original capture
ID continues. The HTTP fixture observes exactly three original durable commands
with the two Watch credentials and one recovery receipt, with no duplicate mutation.

The finalized archive assembles and fully decodes: 2.687 seconds, 80 video frames,
128,960 audio samples, audible content and the fixture's clean lower image band.
Disabling immediate recovery only in the test fixture produces eight relevant
assertion failures; restoring the real configuration passes. Independent review
approved this functional scope. This does not establish frame continuity, 24 fps
under load, A/V synchronization, sustained latency or physical WatchConnectivity.

A final cross-route regression found TLS, URL cancellation and unknown phone HTTP
errors still becoming `unavailable`. They now remain terminal across the relay;
only recognized connectivity failures can prompt route fallback. The actual HTTP
client / typed relay / router test first failed 11 assertions, then passed after
the mapping fix and correction of the test's public error-type expectation.
Independent review approved the final mapping. Full Core passes 194 tests and full
Film model passes 86 tests, including the recording integration, both terminal 0.
Evidence is `watch-relay-forwarder-taxonomy-*.log`,
`native-watch-relay-recording-{red,green}.log` and `native-watch-relay-film-full.log`.
The final combined Release build also terminates with exit 0
(`watch-relay-native-final-release.log`) after the taxonomy fix; its embedded Watch
executable retains arm64 and arm64_32. The 43 Watch model/gate and 34 phone model
checks above remain the relevant companion-model evidence for this checkpoint.

The next implementation checkpoint is the separately scoped
[Watch bootstrap relay](2026-09-15-watch-bootstrap-relay.md).
