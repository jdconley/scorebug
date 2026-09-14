# Native Watch networking design notes

The [pairing foundation](watch-pairing-foundation.md) now provides server issuance,
redemption, and durable Watch setup recovery through the shared Swift HTTP client.
The [native Watch app and companion adapters](native-watch-app.md) now use this
foundation. ScorebugCore's
durable command coordinator owns command identity and receipt reconciliation
independently of the iPhone UI.

## Platform behavior

Watch URLSession requests can use the paired iPhone as a network proxy, known Wi-Fi,
or cellular. Let watchOS select the available route instead of attempting to force
a radio from app code. Foreground requests must also account for app suspension;
background execution is not a continuously available scoring process.
[Apple: keeping watchOS content up to date](https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date)

WatchConnectivity offers immediate request/reply messaging when the companion is
reachable, plus queued transfers and replacement application context. Replacement
context is appropriate for current setup/snapshot hints, not a sequence of scoring
commands. Delayed transfer delivery alone cannot acknowledge acceptance by the
Scorebug server. Debugger attachment can change watch suspension behavior, so wrist
lowering and recovery must also be tested with the app launched normally.
[Apple: transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity)

Default/ephemeral URLSession tasks need explicit lifecycle cleanup as the Watch app
becomes inactive. Keep an uncertain command durable when cancelling a request;
recovery must query its receipt before deciding whether it can still be submitted.
[Apple: default and ephemeral requests](https://developer.apple.com/documentation/watchos-apps/making-default-and-ephemeral-requests)

Apple explicitly excludes `transferUserInfo(_:)` support from Simulator. Injected
transport tests and direct Watch HTTP Simulator tests can verify the application
protocol, but physical paired devices remain necessary for that queued route.
[Apple: transferUserInfo](<https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)>)

## Application decisions to implement

- Give each Watch a distinct scorer device identity and scoped match credential.
  Keep direct HTTP available without an active companion app. Watch A may score
  while its paired phone A films, and Watch B may score through phone B while phone A
  films. The scorer role must never require capture ownership.
- Reuse one durable command ID and exact payload across direct URLSession and
  companion relay attempts. A route timeout is uncertainty, not rejection. Let the
  existing coordinator reconcile the receipt before retrying or abandoning it.
- Use a bounded typed companion envelope, not an unrestricted URLRequest proxy.
  Restrict relaying to the configured Scorebug endpoint and allowed match operations;
  scope replies to the request, Watch identity, match, and credential generation.
  Never forward camera/publish grants or long-lived installation credentials merely
  to score a point.
- Let direct HTTP work through OS-selected paired/Wi-Fi/cellular networking. Use
  reachable companion request/reply as an additional transport option with finite
  deadlines and joined cancellation. A late response must not overwrite newer match
  state. Do not wait indefinitely for a companion before trying a usable network.
- Persist setup in device Keychain, transfer only an expiring pairing capability,
  refresh snapshots on wake, and show pending/accepted/rejected distinctly. Success
  haptics require the authoritative command outcome, not local enqueue or phone receipt.
- Do not enqueue stale point mutations indefinitely using background user-info
  transfer. If that route is used, reconcile receipts/expiry before submitting at
  the companion, using the same immutable command identity.

## Qualification order

1. Shared deterministic transport/coordinator tests: lost response, timeout,
   cancellation, duplicate delivery, route changes, expiry, takeover, and stale reply.
2. watchOS 10 deployment build; Series 7 41 mm, Ultra 2, and SE-sized layout checks.
3. Direct HTTP tests on owned Watch/phone simulators, including Watch A + filming
   phone A and a separate Watch B/phone B scorer pair. Document simulated routes.
4. Real Ultra 2 and Series 7 with the paired filming phone: app suspension/relaunch,
   phone relay, Wi-Fi without companion reachability, and cellular where service is
   available. Repeat without debugger attachment and verify one server outcome per
   action while the phone archive and stream continue.

These are design constraints for the approved Watch milestone. Runtime fallback
ordering and deadlines need measured physical-route behavior before reliability is
claimed; no browser scorer is part of this design.
