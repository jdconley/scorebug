# Guarded native admission for owned quality increases

This is the application-transfer gate identified while implementing
[owned probe contexts](2026-09-25-owned-probe-operations.md). A context read is
point-in-time. Implicit input-format or notification invalidation can change the
native encoder after that read without changing adapter epochs or revoking probe
authority. Close this gap before enabling the owned Session application route.

## Expected configuration selects the native mutation

Use an explicit guarded path through Media, Streaming and the native SDK. Keep
Media independent of Streaming. Suggested Media signatures:

```swift
enum PublishingVideoMutationExpectation {
    case verified(PublishingBitRateChange)
    case replacement(PublishingVideoProfileChange)
}

func setVideoBitRate(_ rate: Int,
    expecting: PublishingVideoMutationExpectation) async throws -> PublishingBitRateChange

func setVideoProfile(_ profile: PublishingVideoProfile,
    expecting: PublishingBitRateChange) async throws -> PublishingVideoProfileChange
```

These protocol capabilities default to disabled. Owned upward application must
never fall back to an unguarded mutation. Existing methods remain available to
legacy callers and downward actions. The expected selector supplies no enduring
authority; the actual native state must match it when the mutation is admitted.

Compare generation, configuration ID, encoder-session ID, bitrate, acceptance
time and optional source PTS before reserving mutation or revoking a probe. After
joining any pending submission, compare again before native work. Pass the
expectation to `VideoCodec.setVerifiedBitRate` or `prepareReplacement` and compare
against the actual current receipt and observed invalidation revision there.
Preserve the existing post-write invalidation and replacement-commit checks.

This binds admission to the selected encoder and prevents silently switching to
another baseline. It cannot promise zero native calls when a notification races
an already admitted write. Such uncertainty still cannot produce a successful
acknowledgment.

## Profile replacement and the following verified write

A profile replacement has no new verified bitrate receipt until the following
write. Its guarded follow-up must therefore select the actual replacement receipt
and current new encoder, rather than the old context's receipt.

Retain one bounded native replacement continuation. Invalidate it on intervening
configuration mutations and consume it with its verified write. Merely comparing
the new encoder-session UUID would miss a same-encoder configuration change. The
existing profile receipt's generation, previous/new encoder IDs and first-new
source boundary must match the retained continuation. Never reconstruct missing
continuation ownership from a global diagnostic snapshot.

## Distinguish safe rejection from uncertain mutation

Introduce a typed stale-admission result that can only arise when no encoder
mutation occurred. Release only that operation's reservation and timer. This
rejection must not stop a healthy newer publication or cancel another operation.

Both `PublishingSession.performUpdate` and `mutate` currently stop on broad
mutation failures; the adapter profile-change catches also stop. Thread the safe
pre-write rejection through all of these layers without converting it to an
uncertain generic failure. Preserve shutdown for cancellation, native write
uncertainty and post-mutation errors.

If profile replacement has already succeeded, rejection of its following bitrate
write leaves a partially completed application. Preserve the existing stop path
for that case. A pre-write rejection of the second write does not undo the first.
`PublishingSession` owns one mutation call at a time; the broader
`PublishingQualitySession` owns the profile-plus-bitrate application. Preserve
that distinction: the latter retains whether its exact current application has
already changed profile and joins shutdown for partial application. Do not infer
ownership of a partial application merely from an old `.replacement` selector;
a stale selector must not stop newer healthy work. Session must settle/retire the
measurement according to its exact current token and configuration ownership;
stale completion must not consume a newer token.

## Verification gates

- [x] Same bitrate with a different configuration ID rejects before native work;
      identical numeric settings on a different encoder also reject.
- [x] Recheck expectation after a held pending-submission join. Mismatch makes
      no property writes or replacement drains and preserves newer work.
- [x] Notification invalidation before admission rejects; invalidation during a
      verified write or replacement drain cannot acknowledge success.
- [x] Exact replacement continuation permits its guarded bitrate write once;
      an intervening same-encoder write invalidates that continuation.
- [x] Missing guarded capability never invokes legacy mutation methods.
- [ ] Safe pre-write mismatch preserves the broadcast and clears only its own
      timer/reservation; cancellation, uncertain effects and partial profile
      application retain joined shutdown behavior.
- [ ] Focused/full affected suites, SDK patch provenance, independent spec and
      quality review before wiring the owned Session transfer route.

The native SDK and publisher-adapter checkpoints below implement guarded mutation
and explicit adapter propagation. Session handling remains open; the read-only getter and
probe context alone cannot authorize application. Automatic post-restoration
quality increases remain gated.

## Implementation checkpoints

Deliver this gate in three reviewed steps. A passing native checkpoint does not
expose or enable the guarded Session route by itself.

1. **Native SDK:** add explicit expected-configuration selectors and guarded
   bitrate/replacement overloads. Keep one private replacement continuation in
   the codec and its actual matching receipt in `SRTStream`. The public selector
   is a comparison value, not proof that a replacement happened. Compare the
   complete retained receipt and pass the private native continuation down to
   the codec. Rebuild and verify the maintained SDK patch after focused/full tests.
2. **Media and publisher adapters:** add the disabled-by-default guarded protocol
   methods, exact scalar conversion, and explicit guarded closures in injected
   operations. Check configuration before local mutation reservation and probe
   revocation; recheck after health/other suspension and at native admission.
   Retain the exact native-to-Media replacement mapping so an arbitrary profile
   receipt with a substituted acknowledgement time cannot select a continuation.
   Invalidate this bounded mapping on intervening admitted configuration work.
   Use the SDK's read-only `validateVideoMutationExpectation(_:)` for native
   replacement preflight too: the verified bitrate getter is intentionally nil
   between replacement and its following write. The read consumes no continuation
   and does not replace the guarded setter's final checks.
   Preserve legacy/downward behavior and exercise the real loopback route.
3. **PublishingSession:** carry the expectation with its owned mutation request.
   Only a guarded request may interpret the typed no-effect rejection as safe.
   Resolve its exact timer/reservation without stopping healthy publication;
   never overwrite an already committed stop, deadline or cancellation. The
   broader `PublishingQualitySession` application owner must separately distinguish
   rejection before any application mutation from rejection after a successful
   profile change. Partial application still joins shutdown. Integrating the
   Core measurement token and Session campaign lease follows these protections.

Notification invalidation stays a thread-safe scalar revision change.
`VideoCodec` continuation fields remain owned by the stream execution path;
notification callbacks must not mutate them concurrently. Comparing the captured
revision invalidates a continuation immediately, even before its stored record
is cleared by the owner.

At the Session layer, both `performUpdate` and its external `mutate` waiter need
explicit handling. The internal task must not wait on shutdown that joins itself.
A proven safe rejection should mark only its own mutation resolved before a timer
can turn the same failure into a timeout; the external waiter cancels and joins
that timer before returning. If cancellation, deadline or shutdown has already
won, preserve that terminal outcome. Do not clear a newer mutation's state.

Regression cases for the upper layers include absent guarded capabilities making
zero legacy calls; same numeric bitrate with a substituted configuration or
encoder; changed configuration across a held health/native await; a forged
replacement mapping; stale rejection with a held timer; concurrent cancellation
or deadline; and profile-success followed by guarded bitrate rejection. Tests
must distinguish continued healthy publication from a partially applied change
that requires joined shutdown.



## Required settlement after guarded rejection

The Core transfer currently consumes `ownedMeasurement` in
`beginApplication(_:for:at:)`. Its old measurement failure method therefore
cannot settle a later guarded rejection. Calling `acknowledge(applied: nil)` is
also insufficient: that path can require a minimum-profile reset despite the
rejected call making no encoder change. The app currently keeps the transferred
policy only in a local copy until success; special-casing its catch without
persisting ownership would lose the transfer and failure accounting.

Before enabling the owned application route, retain one private transferred
record containing the exact measurement attempt and admitted application. It is
separate from the revocable active application slot, which failure telemetry may
clear while cleanup joins. Add an explicit rejection settlement for that pair:

- Check exact controller/attempt/application identity, unresolved ownership,
  current applied revision and baseline before reading or changing policy time.
- Call it only after the trusted guarded no-effect rejection, with no earlier
  profile mutation in that application, and after exact native cleanup joins.
  Do not introduce a caller-supplied `joined` or `noEffect` boolean.
- Consume once, count the existing failure episode once, clear strong/recovery
  coverage and advance the earliest healthy boundary monotonically. Clear the
  active application or pending advice only when they belong to this owner.
- Preserve newer downward work, existing reset intent, trial/settings/revision,
  cooldown, and source/delivery/candidate watermarks. Do not fabricate a reset.
- Keep unresolved transferred ownership a barrier to new measurements/upward
  work while downward work remains available. Successful acknowledgement removes
  it normally. A real revision change permits exact non-counting bookkeeping
  retirement; stale completion must not change time or cancel newer work.

The app must publish its transferred policy and private application owner before
its first suspension. After cleanup, settle against the current authoritative
policy only if that owner still matches. Never overwrite intervening telemetry
or downward decisions with the pre-await policy copy, and never keep global
`busy` set merely while failed measurement cleanup joins.

Tests must cover a same-scope no-effect failure at a nonminimum profile without a
reset; delivery failure plus rejection counting once in either order; telemetry
revocation and downward advice during held cleanup; duplicate/foreign/obsolete
completion with future timestamps; success, partial profile application and real
revision retirement. Core, Media and app suites must pass before wiring a native
owned application transfer. This is additional required work, not implemented by
the SDK or publisher-adapter checkpoints.


## Native SDK checkpoint

Explicit guarded bitrate and profile-replacement methods are implemented. They
compare the complete expected receipt before reservation/probe revocation, after
pending submission joins and again inside the codec before native work. A stale
request cannot silently update a different encoder with the same numeric bitrate.
A retained private replacement continuation permits one follow-up verified write;
public replacement values alone cannot create or restore it.

Native regression tests cover exact scalar/source-time selectors, intervening
same-encoder writes and settings, notification invalidation before/during work,
held submissions, replacement reuse, and old operations resuming after close and
republication. Guarded pre-write rejection clears only its exact reservation and
preserves the newer publication and receipt. Cancellation and uncertain native
write/drain failures keep their prior behavior. Ordinary video frames preserve
the original replacement boundary. Notification callbacks remain revision-only;
recording the replacement's own invalidation revision is atomic.

Final native verification: **10 focused tests / 345 full SDK tests** pass with
Xcode 26.2; all processes joined. The full suite used `--no-parallel`.
Specification and code-quality reviews approve the native slice. The maintained
patch verifies all **162 original upstream hashes** and an exact round trip.
Evidence:
`artifacts/qa/guarded-native-focused-final-02.log`,
`artifacts/qa/guarded-native-full-final-02.log` and
`artifacts/qa/guarded-native-patch-verify-final-02.log`.
Downstream verification also passes **233 full Streaming tests**, including the
two real SRT probe/encoder-replacement loopback cases. The command joined exit 0;
log and exit record are
`artifacts/qa/repeated-live-checkpoint-guarded-native-streaming-full-20260925{.log,-exit.json}`.

The first parallel full run (`guarded-native-full-01.log`) failed an existing
transport-observer assertion: it expected four events and observed six, including
one later outer send attempt that never reached the socket. This appears
scheduling-sensitive; it was not reproduced against the unchanged baseline.
The failure artifact remains intact. No transport code or observer assertion was
changed to obtain the serial pass.

This native checkpoint alone did not deliver guarded Media/Streaming APIs. The
adapter checkpoint below now supplies them. PublishingSession safe-error handling,
owned measurement integration and fresh full-media qualification remain open.


## Media and publisher-adapter checkpoint

Media now exposes explicit guarded methods with disabled defaults. Both Streaming
adapters preflight the actual native configuration before reserving a mutation or
revoking probe authority, then recheck ownership after suspension and at guarded
native admission. Exact retained replacement mappings include source-time fields
and acknowledgment-time bits; a substituted public receipt cannot recreate them.
Guarded methods work independently of opting into owned bandwidth probes.

The SDK adds a read-only mutation-expectation check for the interval between
profile replacement and its following verified bitrate write, when the ordinary
verified receipt getter is nil. Repeated reads do not consume the continuation or
revoke probe authority. Implicit native invalidation is still detected. The real
mutating call performs its own final checks.

Typed pre-write rejection preserves a healthy publication. Cancellation and stop
win over a late safe error, and malformed successful receipts or other uncertain
mutation outcomes retain joined shutdown. Internal mutation tasks do not await
shutdown that must join them. Regression tests include real lower SRT and
production-initialized upper publisher loopback routes with actual replacement
and follow-up writes. These small loopbacks establish component behavior, not
full decoded-media continuity or production quality increases.

Verification, with all processes joined:

- **16 focused / 346 full serial SDK tests** pass; the maintained patch verifies
  all **162 original hashes** and its exact round trip.
- **14 focused / 245 full Streaming tests** pass.
- **257 full Media tests** pass (191 XCTest and 66 Swift Testing).
- Independent specification and quality reviews approve this checkpoint.
  PublishingSession behavior has not yet changed.

Evidence is retained in
`artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-{focused,full}-20260925{.log,-exit.json}`,
`artifacts/qa/guarded-adapter-focused-04.log`,
`artifacts/qa/guarded-adapter-streaming-full-01.log`, and
`artifacts/qa/guarded-adapter-media-full-01.log`.
Behavioral failure evidence remains in `guarded-adapter-red-02.log`,
`guarded-adapter-red-03.log`, and `guarded-adapter-red-04.log`.

Next are exact Core settlement after a transferred application is rejected,
PublishingSession timer/reservation handling, and the broader application owner.
A successful profile mutation followed by a rejected bitrate write still requires
joined shutdown by that broader owner. No automatic retry route is enabled here.
