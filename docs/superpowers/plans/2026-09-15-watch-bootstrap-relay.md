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
   binding is insufficient authority for a different bootstrap request. Failed
   storage or a missing saved offer must prevent HTTP dispatch.
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
