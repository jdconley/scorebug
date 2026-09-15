# Atomic phone pairing association

Implement native-watch-relay step 3 by replacing the existing phone setup Keychain
value with a version-2 record containing `pending`, `relayBinding` and
`requiresNewRequest`. Decode the existing version-1 PhoneWatchRequest as a pending-only record; write version 2 on
the next mutation using the existing service/account and atomic Keychain update.
The binding is a validated canonical WatchRelayScope and contains no token.
The new gate defaults to false when decoding version 1 or existing version-2
records without that field. A gated record cannot also contain a relay binding.

A matching paired notice may create authority only from a locally saved issuance
request. One atomic replacement installs its binding and clears pending setup
(including the installation token). Failure preserves the previous durable value,
keeps the pending request, and exposes no new relay binding. This removes the crash
window inherent in two separately persisted files. A retry can perform the same
replacement; a confirmed binding survives relaunch without another issuance.

Keep the existing pending property/UI and exact issuance retry behavior. Validate
both record components on restore. A notice cannot invent an endpoint or binding;
wrong match, device or pairing IDs must never replace the association. A known
association must survive unordered phase/pairing notices, including cached context
received before resume. Notices carry identity but no freshness guarantee. Actual
WC session peer changes clear it and invalidate the in-memory relay view immediately,
even if durable clearing fails. Setup suspension does not erase a confirmed
association; the later app-scoped request owner will control background work.

Expose a synchronous binding-change callback for the later app-scoped relay owner.
Invoke it only after successful persistence when activating a binding; clear it
before reporting failed replacement/clear or peer changes. The callback itself
must not need the setup tab or camera/scorer ownership. The upcoming relay owner
will independently cancel stale request generations and validate every scope.

A phone may retain its confirmed old binding while a different replacement offer
awaits explicit acceptance on the Watch. Do not break the existing scoring route
merely because an offer was issued. A matching new paired notice atomically
replaces authority. Subsequent pending/unpaired/different pairing notices are
observational and cannot erase that confirmation. Every relay request must still
match the complete saved scope and authenticate at the server. Reject a restored
record that represents the same pairing as both pending and confirmed, but allow distinct old/new generations.

Invalidate the issuance epoch and cancel its task before attempting a matching
confirmation write, including on storage failure. A retained matching notice
allows a later retry to perform the local atomic confirmation without HTTP.
Failed peer invalidation leaves a suppression latch in the current process;
resume/restore must not accidentally re-expose the stale stored association.

A peer change also sets `requiresNewRequest` before attempting its atomic save.
The save clears the binding and retains the exact pending request for review.
While gated, delayed matching confirmations and automatic retries cannot revive
that pending pairing. Explicitly resetting the saved setup clears both pending
and the gate in one successful write; a failed reset keeps the gate in memory
and preserves the prior durable record. This is separate from a failed ordinary
confirmation write, which remains locally retryable without HTTP. Successful
peer invalidation persists across relaunch; a failed write can guarantee
suppression only in the current process until a later durable replacement.

If no pending request exists, the existing UI has no reset action. Normal Connect
therefore remains available: it creates a fresh pairing UUID and clears the gate
only when that new pending request is atomically saved. Failure to save sends no
issuance and leaves the gate in force. Neither path reuses a pre-change pairing.

Required checks: exact atomic confirmation/no secret retention; failed commit
retains pending and no new authority; retry; confirmed restore; v1 migration;
invalid persisted binding blocks use; notice mismatches cannot create authority;
new confirmation supersedes old pairing atomically; unordered notices before
resume and after replacement cannot revoke it; actual peer clearing, including
storage failure; delayed pending confirmation after peer change; persisted gate
across relaunch; failed and successful explicit reset; fresh Connect without a
pending request; existing setup and late-response tests continue to pass.
