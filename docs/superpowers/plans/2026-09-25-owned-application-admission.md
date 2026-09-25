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
Session must settle/retire the measurement according to its exact current token
and configuration ownership; stale completion must not consume a newer token.

## Verification gates

- [ ] Same bitrate with a different configuration ID rejects before native work;
      identical numeric settings on a different encoder also reject.
- [ ] Recheck expectation after a held pending-submission join. Mismatch makes
      no property writes or replacement drains and preserves newer work.
- [ ] Notification invalidation before admission rejects; invalidation during a
      verified write or replacement drain cannot acknowledge success.
- [ ] Exact replacement continuation permits its guarded bitrate write once;
      an intervening same-encoder write invalidates that continuation.
- [ ] Missing guarded capability never invokes legacy mutation methods.
- [ ] Safe pre-write mismatch preserves the broadcast and clears only its own
      timer/reservation; cancellation, uncertain effects and partial profile
      application retain joined shutdown behavior.
- [ ] Focused/full affected suites, SDK patch provenance, independent spec and
      quality review before wiring the owned Session transfer route.

No guarded native mutation is implemented by the current read-only getter or
context checkpoint. Automatic post-restoration quality increases remain gated.
