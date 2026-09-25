# September 25 checkpoint: SDK guarded admission and patch provenance

**Imported history, not a reconstructed whole session.** Extracted during plan cleanup from [guarded admission](../superpowers/plans/2026-09-25-owned-application-admission.md#native-sdk-checkpoint) at `b65ca7fe1d58be9ac27e88a63c67867d428f1b10`. Original session boundaries/times are unknown. Implementation commit: `2aa6162`. Results below describe that checkpoint, not a new verification run. Repository-relative artifact paths are rooted at the checkout; ignored artifacts may exist only in the original workspace.

## Recorded commands and results

- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-focused-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel", "--filter", "SRTVideoReplacementTests"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-full-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel"]`; exit `0`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-native-preflight-red-20260925-exit.json`: `["swift", "test", "--package-path", "vendor/HaishinKit", "--no-parallel", "--filter", "SRTVideoReplacementTests.readOnlyMutationPreflight"]`; exit `1`, joined `True`.
- `artifacts/qa/repeated-live-checkpoint-guarded-native-streaming-full-20260925-exit.json`: `["swift", "test", "--package-path", "ios/Packages/ScorebugStreaming", "--no-parallel"]`; exit `0`, joined `True`.

## Decisions, verification, failures and next work (imported)

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

## Current handoff

Both independent reviews approve this checkpoint. Later checkpoint counts supersede earlier counts; full app integration and fresh automatic post-restoration qualification remain open. Current immediate priority is the authorized physical vertical in [NEXT](NEXT.md).
