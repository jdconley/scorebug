# Owned probe operations and configuration-aware restart

This is the Streaming prerequisite for Task 2 of
[owned measured retries](2026-09-25-owned-measured-retries.md). Task 1 already
joins exact rejected allocations. Its ID-based cleanup API cannot recover an
initial allocation whose UUID never reached the caller, or restart a valid late
replacement that was cleaned up without becoming accepted live authority.

## Ownership API

Add privately constructed `PublishingBandwidthProbeOperation`,
`PublishingBandwidthProbeRetirement` and `PublishingBandwidthProbeContext` types.
An operation exposes `value()`, `renew()`, nonjoining `cancel()` and shielded
joining `retire()`. Retirement returns the opaque cleanup receipt, not an asserted
boolean. Context captures verified encoder-configuration ownership; it supplies
no health, capacity, candidate admission or backoff credit.

Publisher actor factories `beginOwnedBandwidthProbe(in:bitRate:policy:)`,
`replaceOwnedBandwidthProbe(after:in:bitRate:)` and
`restartOwnedBandwidthProbe(after:in:bitRate:)` validate and reserve ownership,
retain an operation, start its task immediately, then return its handle without
awaiting native allocation. The owned route always uses staged, repeatable probes.
Session stores the handle before cancellation checks or awaiting `value()`.

The upper publisher similarly stores its lower owned-operation handle before
awaiting the lower value. A thrown value never loses cleanup responsibility.
Retirement joins initial allocation and any captured renewal before joining the
lower retirement. Failure cleanup inside an owned allocation/renewal task uses only the
lower-layer leaf, never its own retirement or shutdown. A public `value()` or
`renew()` wrapper whose final validation fails revokes and joins retirement before
throwing; that external waiter is not the task captured by the retirement join. Keep a bounded current operation/continuation record;
completion can mutate slots only when their identity still matches.

`cancel()` is async and nonjoining: revoke the operation's live admission state
first, then request exact lower/native cancellation when its target is known.
It may await that request without waiting for allocation, renewal or wake-task
completion. An allocator that has not returned its identity can still finish
late; capture and clean that result before further health reads. Only `retire()`
proves the complete native join. Renewal never creates a new owner, so malformed
renewal fields must not redirect cleanup away from the already-owned allocation.

## Configuration context and the downshift case

Do not confuse `probeRevision` with configuration ownership: cancellation and
retirement increment that revision. Add a separate publisher instance identity
and configuration epoch, invalidated before encoder mutations and stop suspend.

Use the existing native verified bitrate receipt as the configuration proof.
`VideoCodec.lastBitRateChange` already checks running state, pending replacement,
failure and the current encoder-session invalidation identity. Settings changes
clear its recorded receipt. `OutgoingStream.lastVideoBitRateChange` exposes it
inside the package. Add a narrow read-only `SRTStream` accessor pairing that
receipt with its current publishing generation, rejecting mutation, finish,
failure and close. It performs no encoder write or new property measurement.

`captureOwnedProbeContext(matching: expectedSessionReceipt)` reads that current
native receipt and compares generation, configuration/encoder IDs, bitrate,
acceptance time and source PTS. The supplied receipt is a selector; the opaque
issuer/epoch and actual native read establish ownership. Upper capture retains
the lower context and rechecks its own state after suspension. Session still
requires fresh source/delivery/configuration diagnostics; this read is not fresh
capacity evidence. Do not use immutable first-frame startup or an adapter's cached
old write as a substitute for current encoder identity.

Context is verified at a native read; it is not a continuously valid encoder
permit. Input-format changes and system notifications can invalidate
`VideoCodecInvalidation` without changing the adapter epoch or revoking a probe's
authority. Before native dispatch and after allocation/renewal or any intervening
health await, compare the actual native receipt again and recheck local ownership
after suspension. Capture a raw allocation before these checks so rejection can
still revoke and join it. Never upgrade cleanup lineage into current configuration
authority.

Both adapters expose `validateOwnedProbeContext(_:)` as an explicit point-in-time
recheck. Native health is read before the final actual native receipt; each actor
rechecks its local issuer, epoch and lifecycle after suspension. The upper context
retains its private lower context and validates through the trusted lower
capability. Injected capture/validation capabilities default to disabled.

Session transfer must freshly check native configuration and then recheck its
token, applied revision/receipt, source/delivery diagnostics, candidate and probe
authority after suspension. A read alone cannot close the later read-to-write
race. Before enabling owned application transfer, add either a revocable native
configuration permit or an expected-configuration check at native mutation
admission. The [guarded native admission plan](2026-09-25-owned-application-admission.md)
chooses the latter, including a replacement-to-bitrate continuation and typed
safe rejection. This is a separate application gate, not a reason to expose new
probe allocation authority in the read-only accessor checkpoint.

Joined native cleanup lineage survives encoder changes in the same publication.
An old context and its Session lease do not. After a downshift and verified write,
Session registers a new Core attempt from fresh readiness, captures a context for
the new receipt, and restarts from the exact old joined native predecessor using
that new context. The broadcast connection stays alive. Stage replacement is
restricted to the same configuration context as its campaign; only a new campaign
may cross configuration epochs. Stop/new publication forbids continuation.

## Allocation and retirement validation

Retain three distinct facts: raw identity for cleanup, validated allocation lineage
for continuation, and accepted live authority after health/context checks. Capture
raw returns before any validation or further await. An initial allocation must
have a strictly positive lease no longer than 300 ms. A late valid allocation can
retain lineage even if cancellation already revoked live authority.

The joined SDK terminal snapshot must match the validated allocation's UUID,
generation, stage, campaign, origin, policy, rate and stage start. Require the
same non-nil native authority object, now revoked, and a terminal reason. Verify
aligned, nondecreasing bounded counters, preserved prior-stage carry and consistent
cumulative growth, plus historical time/last-acceptance relationships. An expired
terminal lease is expected; do not impose live freshness on cleanup. Never obtain
missing ownership from a global probe snapshot.

Native acceptance can finish after the lease deadline: `SRTBandwidthProbe.offer`
deliberately counts that send and records its late completion before terminating.
Do not reject joined cleanup solely because `lastAcceptedAt > leaseDeadline`.
Require a valid historical completion within the observed join boundary and
nondecreasing accounting; separately reject late evidence for live admission or
capacity credit. A renewed deadline can also extend up to 300 ms beyond the
campaign limit even though no new send may start beyond that limit.

For valid late returns, authority may already be revoked. Their lineage must come
from the lowest handle's direct trusted SDK result and the upper handle's retained
private lower owner. Requiring the identical terminal authority then preserves
provenance without interpreting `permits == false` as proof of identity. Arbitrary
externally supplied snapshots cannot establish that trust root. If an interface
ever accepts them, an immutable native identity matcher would also be required.

Each retirement receipt has one-shot continuation state bound to its issuer and
retained native predecessor. Validate request/context before consuming it,
atomically with reserving the successor operation. Record the predecessor before
any await. Duplicate old retirement joins must not cancel that successor.

Because owned stage replacement starts from a joined predecessor, the new stage's
zero-byte initial snapshot must carry exactly that predecessor's final total.
The legacy `isValidReplacement` allowance for a greater total applies to an
unjoined prior snapshot and is insufficient here. A failed cross-configuration
restart must also retain the predecessor's original campaign context when
reissuing its receipt; it cannot relabel that campaign for replacement under the
new configuration.

A canceled first operation may positively establish that nothing was allocated:
native dispatch never occurred, or a trusted allocator threw before installation.
Its receipt permits a fresh begin. A failed restart before allocation retains the
already joined predecessor and issues a new continuation; its consumed input is
never re-enabled. Unknown mutation, malformed lineage, mismatched terminal receipt
or failed joins cannot authorize continuation. Cleanup completion and eligibility
for another attempt remain separate results.

The upper route must preserve this behavior for a known lower-factory rejection
before reservation. The actual non-suspending lower factory has all throwing
guards before its atomic reserve/start/return. Preserve a typed module-private
proof of that rejection through the trusted bridge, including the unchanged exact
lower predecessor when present. An arbitrary injected factory error supplies no
such proof. A safe pre-allocation context race must not force a reconnect merely
because the upper caller never received a lower handle.

## Integration boundary

Explicit owned opt-in is exclusive for the publisher lifetime. Reject it when a
legacy probe owner already exists; never adopt a legacy snapshot. Once owned,
legacy allocating/mutating probe APIs reject busy, and their void cancellation
cannot control this separate route. Owned handles supply cancellation/renewal.
Diagnostic reads remain observational. Internal encoder invalidation and stop
route directly to owned handles, bypassing legacy entry-point guards. Legacy
callers that never opt in retain their existing behavior.

Context capture performs that opt-in: reject legacy ownership and reserve owned
mode before its first suspension. A failed capture does not reopen the legacy
route. This allows context checks to be delivered before owned operation handles
without exposing a second competing allocator. Context-only delivery does not
create or claim a probe. Admitted encoder mutation attempts advance the
configuration epoch before suspension even if subsequently canceled; fresh capture may select the
unchanged actual receipt, but previously issued contexts remain obsolete.

Reuse the existing command-reservation and cleanup machinery where practical;
do not wrap the legacy public APIs in a second independent coordinator. No global
busy flag may block a downward encoder change while cleanup waits. Add trusted
owned factories to injected operations with disabled defaults, not fake receipts.

## Verification

- [x] Native current-receipt read: absent before verified write, exact after it,
      nil during/after invalidation, replacement, failure, finish and close; no
      write side effect. Verify maintained SDK patch and original hashes.
- [x] Context-only adapter capture/validation: exact selectors, separate issuer
      and epoch, actual native read after health, mutation/stop suspension races,
      disabled defaults and lifetime exclusive opt-in; no probe allocation.
- [x] Canceled initial operation before dispatch and after a late valid return;
      lower replacement rejected without ever reaching upper `value()`.
- [x] Held renewal/allocation joins, duplicate/canceled retirement waiters,
      immediate revocation, no completion mutating a newer owner.
- [x] Three distinct stage UUIDs through retire-before-replace; exact cumulative
      campaign accounting; stage replacement cannot cross contexts.
- [x] One-shot/concurrent receipt use; failed restart creates a new continuation;
      malformed, foreign, substituted authority, live authority, counter rollback
      and failed cleanup receipts cannot restart.
- [x] Same-publisher downshift plus verified write and fresh context restarts the
      exact old terminal predecessor as a new campaign. Old context cannot
      restart, renew or replace even if numeric bitrate/profile values match.
- [x] Context acquisition racing mutation, profile-before-bitrate interval,
      implicit native encoder invalidation and stop rejects; cleanup still joins.
- [x] Actual native context checks surround allocation/renewal and health awaits;
      same numeric settings with a changed encoder identity reject live admission.
- [ ] Session transfer additionally closes the native read-to-write race before
      the owned application route can be enabled; see the guarded admission plan.
- [x] Exclusive owned routing, unchanged legacy tests, focused/full SDK and
      Streaming suites, independent specification and code-quality review.

Session token/lease integration and a fresh four-phase media experiment remain
separate gates. These components must not enable production upgrades by themselves.

### Native current-receipt checkpoint

`SRTStream.verifiedVideoBitRateReceipt` now reads the existing actual native
receipt without an encoder write or property readback. It rejects unverified and
passthrough input, pending mutation/replacement, implicit encoder invalidation,
active encoder failure, finish and close. A canceled mutation before its write
can expose the unchanged prior receipt again; the pending interval cannot.

Verification passes **65 focused tests / 335 full SDK tests**, with all jobs
joined. The maintained patch verifies **162 original upstream hashes** and an
exact round trip. Logs:
`artifacts/qa/verified-bitrate-receipt-focused-4-20260925.log` and
`artifacts/qa/verified-bitrate-receipt-full-20260925.log`.
This is a point-in-time configuration read. Owned operation handles and Session
transfer protections remain separate implementation gates.

### Adapter context checkpoint

Both publisher adapters now capture and revalidate the opaque
`PublishingBandwidthProbeContext`. Native validation compares the actual current
receipt after health reads, including exact source-PTS representation. Each actor
checks its own issuer/epoch/lifecycle after suspension. Admitted encoder changes
invalidate the epoch before awaiting native work; pre-canceled calls rejected
before admission preserve the existing context. Stop invalidates it immediately.

Capture reserves lifetime exclusive owned mode before suspension. Even failed
capture leaves legacy probe mutations disabled; legacy cancellation becomes
inert. Existing legacy callers that never opt in retain their behavior. Neither
capture nor validation allocates probes or establishes capacity.

Verification passes **62 focused / 213 full Streaming tests**, including 11 new
context cases. All jobs joined; independent specification and code-quality
reviews approve the checkpoint. Logs:
`artifacts/qa/owned-probe-context-focused-3-20260925.log` and
`artifacts/qa/owned-probe-context-full-20260925.log`.
No operation handles, terminal continuation receipts, Session lease or automatic
retry scheduler are implemented by this checkpoint. The next implementation is
the exact owned operation/retirement path described above.

### Owned operation checkpoint

Both publisher adapters now reserve and return a privately constructed operation
before native allocation. The operation retains the exact lower owner or direct
native result, revokes stale live admission, and joins allocation, renewal and
cleanup before issuing an opaque one-use continuation. Cancellation and duplicate
retirement cannot cancel a successor. Terminal validation separates completed
cleanup from eligibility to restart, preserves exact cumulative byte accounting,
and accepts valid historical sends that completed after lease expiry.

A verified encoder downshift can start a fresh campaign on the same SRT
publication using the exact old terminal predecessor and a newly captured
configuration context. Stage replacement cannot cross configuration contexts.
No-allocation continuations require actual pre-dispatch or trusted pre-reservation
proof; arbitrary downstream errors and foreign handles cannot establish it.
Downward encoder changes remain available while cleanup waits.

Verification passes **82 focused / 233 full Streaming tests**, including 20 new
cases. All jobs joined; independent specification and code-quality reviews approve
the checkpoint, and `git diff --check` passes. Two real native loopback tests exercise three stages, actual raw encoder
replacement from 360p to 240p, and restart on the same connection under both
local-zero-loss and recovery-budget policies. This validates the native plumbing;
it is not a fresh decoded-media or automatic recovery qualification. SDK source
is unchanged from the verified 335-test accessor checkpoint.

Review regressions first reproduced early wrapper error return without cleanup
and eligible lineage from a zero-length initial lease. Final wrappers join before
throwing, and initial allocation requires a positive lease. The terminal live
authority regression independently includes a terminal reason, so it verifies
revocation as well as terminal shape.

Logs: `artifacts/qa/owned-probe-route-focused-final-2-20260925.log`,
`artifacts/qa/owned-probe-route-full-20260925.log` and
`artifacts/qa/repeated-live-checkpoint-owned-probe-native-loopback-20260925.log`.
The guarded mutation path, Session lease integration, automatic retry scheduler
and fresh four-phase media experiment remain separate gates.
