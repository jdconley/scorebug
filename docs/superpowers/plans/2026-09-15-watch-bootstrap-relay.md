# Watch setup through the paired phone

Next bounded checkpoint after routed scoring and the recording integration. Use
TDD and independent specification/quality review; bounded implementation and review
tasks may run in parallel only when files and execution ownership are separate.
Keep native/media qualification isolated from other builds and tests.

## Existing contracts to preserve

`WatchSetupCoordinator` owns explicit acceptance/replacement, device identity,
the empty scoring-outbox check, and atomic pending-to-paired Keychain persistence.
It saves the original redemption ID and recovery key before HTTP. Those values
must survive uncertainty and a failed final Keychain save.

The server's `redeemWatchPairing` checks an already committed redemption before
expiry or match status. The same capability, device, redemption ID and recovery
key recover the same credential. Different recovery identity fails. Only the
authoritative `409 pairing_expired` response allows explicit discard of an unused
pending redemption. A relay must not impose a local expiry check that blocks this
receipt-equivalent recovery after the original capability expires.

The phone atomically persists pending issuance and the returned offer before
transferring it. A matching paired notice activates its confirmed scoring binding
only after durable phone persistence. Server redemption success alone must not
activate that binding: the Watch may still fail its Keychain commit.

## Design

1. Inject one narrow Sendable redemption operation into `WatchSetupCoordinator`,
   accepting `PendingWatchPairing` and returning `WatchPairingRedeemed`. Keep the
   default existing HTTP path and its public callers compatible. This is separate
   from the three-operation `MatchScoringClient` protocol.
2. Add a distinct strict bootstrap request/reply codec with explicit discrimination
   from scoring messages. Carry request UUID, canonical endpoint/game/Watch/pairing
   scope, the exact redemption request, pairing capability and recovery key.
   Correlate the response with the request UUID, full scope and redemption ID;
   validate credential/snapshot shape and identity before publication. Derive
   finite byte/count bounds from current server fixtures. Reject duplicate keys,
   unknown operations, malformed tokens and unbounded models before actor work.
3. Authorize phone forwarding only against its persisted pending issuance and saved
   offer, including exact capability and canonical full scope. Require the durable
   peer-change gate to permit the pending request. An existing confirmed scoring
   binding is insufficient authority for a different bootstrap request. Unavailable
   or invalid persisted authority, including a missing saved offer, prevents HTTP dispatch.
4. Use the existing HTTP redemption method with only the supplied capability and
   recovery key. Installation authority stays on the phone; no arbitrary request
   URL, header, path or method is accepted. Recovery keys and returned credentials
   are transient forwarding data, never phone binding fields, application context,
   diagnostics or logs.
5. Reuse finite deadline/cancellation ownership and the native delegate's one
   admission gate and once-only replies. The current scoring message owner validates
   the scoring codec directly: introduce an explicit closed set of message kinds
   or a narrowly injected validator, without accidentally admitting arbitrary Data
   or creating competing WCSession delegates. Scoring and bootstrap together must
   still respect phone admission and invalidation bounds.
6. Choose one route per redemption attempt. Preserve the same durable pending data
   after uncertain direct failure and prefer a reachable companion on the next
   coordinator recovery attempt. Existing pending-setup polling can trigger that
   recovery. Do not create new redemption IDs or perform hidden mutation retries in
   a transport. Use bounded direct and companion clients, and preserve terminal
   authorization, TLS, cancellation and invalid-response errors. Redemption recovery
   does not use the scoring command's ten-second retry-age budget.

## Implementation sequence and checks

- First inject the redemption dependency and prove real-store persistence before
  invocation, lost committed reply recovery, failed Keychain commit and exact
  identity/key reuse. Existing setup tests must continue to pass.
- Implement the strict codec and typed client with correlation, bounded validation
  and sanitized failures. No installation token may enter a fixture payload.
- Publish a separate authorized pending-offer view from the phone model after
  persistence. Test missing offer, mismatch in every scope field/capability,
  peer invalidation, failed saves and late completion before adding forwarding.
- Add bounded forwarding, route selection and native discrimination. Preserve one
  owner and cancellation joins across scoring and bootstrap. Test direct offline
  to companion recovery, lost response after commit, expired committed recovery,
  invalid credentials and terminal transport failures.
- Verify an unaccepted replacement keeps the old scorer usable, while accepted
  replacement still requires an empty scoring outbox. Receipt recovery and failed
  setup must not accidentally install an old pairing or activate a phone binding.
- Add an injected app-level setup-then-score test and rerun native Release iPhone
  plus both Watch architectures. Repeat on paired devices after provisioning is
  resolved; injected tests do not qualify actual WC wake, radio switching or
  physical background delivery.

No server contract change is currently indicated. If implementation reveals a
need to change recovery or capability semantics, reassess that change explicitly
and retain the existing server regression evidence.

## Phone authority lifecycle details

Expose only the persisted pending offer's canonical scope and capability to the
bootstrap forwarder, never the enclosing `PhoneWatchRequest` containing installation
authority. Construct that view only after successful load/save and offer validation.
A pending issuance without a saved offer cannot authorize redemption. Publish an
invalidation when a reset, replacement, confirmation or actual peer change removes
or changes this authority, before late HTTP work can report success.

The confirmed scoring binding and pending bootstrap authority have different
lifetimes: the user can have a working scorer while deciding whether to accept a
new offer. Preserve that behavior. `requiresNewRequest` is the durable peer-change
gate and must close bootstrap forwarding immediately, including if saving that gate
fails. Do not infer bootstrap authority from an unordered Watch identity notice.

Review failure cases against the actual durable value. If saving a new offer fails,
the unsaved offer cannot be forwarded; the previously committed request remains
unchanged. If saving confirmation fails, do not fabricate a confirmed scoring
binding. Recovery through a still-valid previously saved offer must continue using
its original capability and redemption identity. Neither elapsed local time nor an
expired offer's display state proves the server never committed redemption.

Independent design review approved these lifecycle rules after clarifying that
unavailable/invalid persisted authority blocks dispatch, while a failed confirmation
save can leave a previously committed offer valid for exact redemption recovery.

## Redemption dependency foundation implemented

`WatchSetupCoordinator` now accepts an optional Sendable `redemption` closure after
the existing `clientFactory` argument. Its default builds the same HTTP call from
that factory. Only transport dispatch moves: the coordinator still owns pending
persistence, scoring-outbox exclusion, cancellation checks, response validation
and paired-state commit.

Six new tests reopen actual committed test files before dispatch and across
coordinator recreation. They prove exact capability/request/key reuse after a
committed lost reply or failed final save, pending-save failure before invocation,
invalid returned authority, and cancellation plus busy ownership while a reply is
awaited. Production storage remains device Keychain. The expected missing-argument
compile red terminated with exit 1; focused green and full Core terminated with
exit 0, with all 200 Core tests passing. Evidence is
`artifacts/qa/watch-setup-redemption-{red,green,core}.log`.

Independent review approved source compatibility, unchanged default HTTP behavior,
durable ordering, cancellation, validation and the tests. This is the first
dependency checkpoint only: the strict bootstrap codec, authorized pending-offer
view, native dispatch and route selection are still required.

The combined Release iPhone/Watch build after this dependency change also passes
with terminal exit 0 (`watch-setup-redemption-native-release.log`).

## Bootstrap relay and native wiring implemented

The strict bootstrap codec/client use distinct request/reply discriminators,
16 KiB requests and 32 KiB replies. They share the existing strict JSON preflight
and snapshot/failure validators; the scoring codec only widens helper visibility
inside Core. Bootstrap capabilities, recovery keys and returned score tokens must
be canonical 32-byte values. Replies correlate request UUID, full scope and
redemption ID, then verify the returned credential and snapshot identities. A
maximally escaped five-set snapshot fits the reply bound without artificially
capping scores. The typed client performs one attempt with cancellation checks
before dispatch and after receipt; authoritative expiry errors retain their type.

`PhoneWatchModel` now publishes a transient bootstrap authority from the canonical
scope and capability of a saved pending offer. The view contains no installation
token or recovery key. Save/load validation precedes publication; failed confirmation
retains the prior saved offer, successful confirmation removes it, and peer changes
force immediate invalidation even if storage fails. A previous confirmed scorer can
coexist with a distinct offer awaiting acceptance. Nine new phone tests cover
publication order, invalid/missing authority, peer gates, reset, confirmation failure
and unordered notices; all 43 phone companion model tests pass.

`WatchBootstrapPhoneForwarder` checks that complete authority before constructing
its HTTP client. It passes the original capability, recovery key and redemption
request unchanged, never uses installation authority, and cannot activate a scoring
binding. One task owns the HTTP attempt until it joins, including timeout and peer
invalidation; a late result cannot cross authority generations. Nine actual-HTTP
tests cover forwarding, every authority mismatch, cancellation/deadlines, terminal
errors and committed redemption recovery.

`WatchRoutedBootstrapClient` keeps only nonsecret scope and redemption identity in
routing history. It initially uses direct HTTP, remembers success and chooses the
alternate for a later coordinator attempt after a recognized connectivity failure.
There is no inline retry. Unavailable companion selects direct; a terminal direct
failure retires any older companion preference. Eleven tests cover route identity,
busy/cancellation ownership and real-file coordinator recovery after lost responses
or failed saves. An added regression failed three assertions before the stale
terminal-error route preference was fixed.

The native bridge now shares one delegate, one inbound admission gate and one
outgoing message owner across scoring and bootstrap. Bootstrap requires explicit
opt-in at the outgoing owner. A closed native request decoder performs strict
validation before actor dispatch and generates correlated immediate/stale failures
for either kind. Peer invalidation closes both forwarding authorities before the
gate reopens. The phone restores its saved state for background requests; setup UI
need not be open. The Watch app injects the bootstrap router into its setup
coordinator, with two-second direct and companion attempts and a 1.5-second nested
phone attempt. These are provisional budgets pending physical measurements.

Current verification, all terminal exit 0:

- Full Core: 233 tests (`watch-bootstrap-router-core.log`).
- Phone companion: 43 tests (`watch-bootstrap-phone-green.log`).
- Watch model/inbound gate: 45 tests (`watch-bootstrap-inbound-green.log`).
- Combined Release iPhone/Watch build (`watch-bootstrap-native-release.log`).

Independent reviews approved the codec/client, phone authority lifecycle, forwarder
and final native wiring. Parent reviewed the router. Expected red/green evidence is
in `artifacts/qa/watch-bootstrap-{codec,phone,forwarder,router,message-owner,inbound}-*.log`.
App-level setup-then-score integration is the next functional check. Physical WC
delivery, background wake and Wi-Fi/cellular/paired-route transitions remain
unqualified; protocol tests and a compiling app do not establish those properties.

## Native setup-to-score integration passes

`NativeWatchBootstrapTests` now runs the phone and Watch models with actual atomic
test files, both HTTP forwarders, strict inbound discrimination, shared message
ownership and the native admission/reply gate under injected WC callbacks. It
explicitly accepts an offer, observes direct failure, commits through the companion
and loses that reply, observes one further direct failure, then recovers the same
credential through the companion after offer expiry. All four are separate
coordinator attempts; no transport silently repeats a redemption.

After each of the first three attempts the exact saved capability, recovery key
and redemption identity remain pending, the phone keeps only bootstrap authority,
and there is no success haptic. The fourth attempt commits Watch storage before
its paired notice causes the phone's atomic pending-to-scoring transition. The same
shared transport then handles explicit takeover and a point with the new Watch
credential and real durable scoring outbox. Assertions require one credential mint,
two exact companion redemption requests, no installation authority in forwarded
HTTP, and two distinct acknowledged scoring commands.

The initial and final focused runs pass, terminal exit 0. Suppressing the lost reply
only in the test fixture causes 20 expected assertion failures, terminal exit 65;
the original fixture is restored. Full FilmModels passes all 87 tests, terminal
exit 0, including the previous two-Watch real recording integration. Evidence is
`artifacts/qa/native-watch-bootstrap-{initial,counterfactual-red,green,film-models}.log`.
Production Keychain and actual WC radio behavior remain separate physical checks;
these test files are not a replacement production secret-storage implementation.

Independent review approved the final integration test's durable recovery, storage
ordering, credential separation, shared admission and acknowledgment assertions.

## Native Watch simulator regression passes

After the new setup/scoring factories were connected, the existing native UI runner
passed on Series 7 41 mm / watchOS 10.5 with terminal exit 0:
`artifacts/qa/native-watch-4itqTX` (`watch-bootstrap-native-watch-ui.log`). It uses a
real local server, native URLSession and simulator Keychain. Six exact command
outcomes are retained: takeover, point, undo, rejected tied end-set, point and
end-match; final revision is 5 and score is 0–1. The app relaunches without injected
setup and recovers its saved credential. Scoring and restored-state screenshots
were visually inspected on the small Watch display.

Only the initial offer is injected in this runner. This confirms native direct
networking and Keychain behavior with the new routing code, while the companion
fallback path has the injected model/HTTP evidence above. It does not supersede
the previously recorded paired-simulator ACX failures or physical WC requirements.
