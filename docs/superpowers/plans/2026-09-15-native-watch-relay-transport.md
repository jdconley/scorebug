# Bounded companion message ownership

Follow the native Watch relay plan with a small, injectable request owner before
connecting the app's existing WCSession delegate. Use TDD and independent review.
No timer, routing decision or camera ownership belongs in the typed scoring client.

A MainActor owner accepts one bounded Data request at a time. A second request
fails busy; unavailable reachability fails before dispatch. Validate request bytes
before dispatch and response bytes before admitting a callback to the actor. The
existing typed client validates request/reply correlation. The platform adapter
uses the existing session's sendMessageData and maps its errors to a sanitized
unavailable failure. Do not log payloads or credentials.

An injected monotonic clock and scheduler impose a finite attempt deadline. Start
with a configurable four-second companion attempt for simulator/model work; this
is not a physically qualified routing budget. Check the absolute deadline again
when a callback is handled so a delayed timer cannot admit an expired success.
Cancellation and peer invalidation settle local ownership once; duplicate and late
callbacks cannot settle a later request. A sent WC message cannot be unsent, so a
canceled/timed-out execute remains uncertain and its durable command stays pending.
The request owner never retries or switches routes.

Tests cover pre-cancellation, cancellation after dispatch, synchronous send errors,
unreachable peers, busy admission, malformed/oversized data, exact byte delivery,
duplicate callbacks, reply-after-deadline before timer execution, timer expiration,
peer invalidation, and stale callbacks after a new request begins. Use controllable
callbacks and clocks, not sleeps. Integrate this sender with WatchRelayScoringClient
and the real coordinator/outbox in a cancellation or timeout recovery test.

The separate phone forwarder must validate complete persisted binding before HTTP,
forward only the Watch credential, own one HTTP task, invalidate generations before
cancellation, and remain busy until canceled work joins. Strict bounded delegate
admission must precede creating actor Tasks. App-scoped activation, routing budgets,
bootstrap redemption and physical networking qualification remain follow-on work.

Platform contract checked against Apple's documentation: configure the existing
session delegate before activation; send only from an activated session. Data
messages and reply callbacks arrive serially on background threads. An active
Watch sender can wake its iOS counterpart in the background; the reverse direction
does not wake the Watch. The receiving delegate must invoke its reply block even
for rejected input. This supports immediate bounded failure replies at admission,
then one owned async forwarding task for an accepted request. See
[sendMessageData](https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessagedata(_:replyhandler:errorhandler:))
and [the receiving delegate](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceivemessagedata:replyhandler:)).

## Implemented local request owner

`WatchRelayMessageTransport` now owns one MainActor continuation, absolute deadline,
cancelable timer and immutable request UUID. It validates the bounded request before
dispatch. A private lock admits at most one callback, replacing oversized reply
bytes or invalid HTTP error metadata before creating its actor Task. The injected
scheduler must defer its callback rather than call inline; the default uses an
asynchronous cancellable Task. Early timer callbacks rearm to the original deadline.

Fifteen focused tests pass, including a real-file outbox whose timed-out committed
command recovers via one receipt with no second mutation. Expected missing-API and
metadata-bound failures are retained in `watch-relay-transport-{red,admission-red}.log`;
`watch-relay-transport-green.log` records terminal exit 0. A draft-only type-inference
compile failure is preserved separately. Full Core now passes all 159 tests, and
Release iPhone builds both arm64 and arm64_32 Watch code successfully, including the
final phone peer-change gate. Both commands terminated with exit 0; logs are
`watch-relay-transport-{core-full,phone-release}.log`.

This implements injected local ownership only. The WCSession adapter, phone HTTP
forwarder, route selection and app-level background lifecycle remain unwired.

Independent review approved continuation ownership, bounded callback admission,
monotonic deadline handling, timer lifetime and durable recovery coverage with no
concrete correctness findings. Parent also inspected the implementation and verified
the built Watch executable contains arm64_32 and arm64 slices using Xcode 26.2.
