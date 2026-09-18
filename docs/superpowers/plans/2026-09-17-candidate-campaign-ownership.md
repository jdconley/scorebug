# Fresh candidate campaign ownership implementation plan

> **For agentic workers:** Use one independent bounded Streaming owner implementation agent; parent owns native identity/adoption and all heavy jobs. Then independent spec and quality reviews. Work only in the local-validation worktree and preserve prior evidence.

**Goal:** Permit fresh paired candidate encoder/AAC measurements under one continuing publication, with joined retirement and campaign-exact native admission.

**Architecture:** Add a bounded reusable owner whose current entry contains one single-use measurement and transport. Replace the fixed audio observer with this owner's synchronous current-entry router. New measurement creation is refused until prior startup and terminal work have joined. Native candidate ownership remains revocable; beginning measurements never changes live settings or grants recovery credit.

**Tech stack:** Swift actors, short synchronous NSLock routing, existing PublishingCandidateMeasurement/Transport, native capture model XCTest, iPhone simulator.

## Design decisions

Reinitializing the existing measurement/transport would violate their permanent cancellation and closed-result contracts. Keeping all old owners alive would accumulate native work and permit stale callbacks. Instead, retain only one entry and one retired identity scalar, allocate a fresh pair per begin, and explicitly retire it before creating another. Recovery scheduling remains a separate caller policy; this ownership operation makes the required fresh measurement possible.

The user has already authorized autonomous implementation of repeated ramp-up. No additional routine approval is needed. This advances the full streaming/Watch goal; it is not a substitute for the remaining repeated native cycles, physical devices or portable-host qualification.

## Streaming owner contract

Create `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/PublishingCandidateCampaignOwner.swift` and matching tests.

```swift
public actor PublishingCandidateCampaignOwner {
    public struct Handle: Sendable, Equatable {
        public let id: UUID
        public let scope: VideoFrameObservationScope
        public let profile: PublishingVideoProfile
        public let publishingGeneration: UInt64
    }
    public init()
    public func begin(scope: VideoFrameObservationScope, profile: PublishingVideoProfile,
                      publishingGeneration: UInt64) async throws -> Handle
    public nonisolated func offer(_ sample: CapturedMediaSample, id: UUID) -> Bool
    public nonisolated func observeAudio(_ frame: SRTPublisher.CompressedAudioFrame)
    public nonisolated func cancel(id: UUID, reason: PublishingCandidateMeasurement.Reason)
    public func result(id: UUID) async -> PublishingCandidateMeasurement.Result?
    public func retire(id: UUID, reason: PublishingCandidateMeasurement.Reason) async
    public func stop() async
}
```

- One factory creates a fresh measurement/transport pair; internal injectable operations supply id/start/offer/audio/cancel/result for deterministic tests. Generation must be nonzero. Busy/closed/invalid/stale results are explicit errors or nil as appropriate, never silently reused.
- Reserve the entry before awaiting startup. One owned startup task and one terminal task (terminal waits for startup completion before calling result) are shared by all callers. The retained entry blocks begin even after natural measurement completion until explicit retirement joins it. No detached or per-frame tasks.
- Synchronous routing admits video only after successful startup and only for the exact current id. Audio reaches only the current live transport, including its bounded following-audio allowance after raw closure. Routing holds no media queue and invokes underlying operations outside its short pointer lock.
- Cancel synchronously withdraws routing and native raw admission for the matching id. Retire also cancels startup and awaits the one terminal task before clearing this exact entry. Concurrent retire/stop calls share terminal work; a late old retire cannot clear a newly installed owner. Caller cancellation during begin cancels the specific owner/startup and joins cleanup. Stop permanently closes admission, revokes first, then joins. Failed startup also joins before freeing the slot.
- Preserve the single-use lower-level contracts and public production defaults. Native publication/recording never waits on candidate retirement in its raw append path.

## Tasks and verification

- [x] Streaming agent writes failing tests for fresh paired attempts, concurrent begin rejection, retained completed owner, old-id replay/offer/cancel rejection, blocked startup/terminal joins, caller cancellation, duplicate retire/stop, stop during startup and late cleanup. Parent runs RED before agent implementation. Implement contract above; parent runs focused GREEN and full Streaming tests.
- [x] Parent writes failing native tests for campaign mismatch among binding/current/receiver expectation and full UInt32 audit preservation. Add exact equality and include campaign only when present, preserving v2 diagnostic shapes. Files: `PublishingCandidateAdmission.swift`, `NativeCandidateFixture.swift`, `NativeCandidateLifecycleAudit.swift` and related FilmModelTests.
- [x] Adopt the paired owner in the real `NativeCandidatePublisher` construction and `CaptureStreamingModel` AAC observer. Existing single-run fixture uses one handle through immutable or synchronized closure state; offer/result/cancel use its exact id and joined stop releases it. Keep injected fixture operations and existing v2 route compatible. Prove cancellation and audio routing regressions with tests and compile.
- [ ] Add explicit native remeasurement only after a newer v3 campaign is locally owned, old candidate work joined and current publication/profile are verified. Allocate new candidate authority and diagnostics; stale appends/reads/results may not enter the new attempt. If scheduler dependencies require a further interface, record the exact remaining integration boundary without claiming repeated ramp-up complete.
- [ ] Review spec then quality, run affected model/Core/Streaming regressions and existing native media regression, verify patches unchanged if untouched, rehash frozen evidence and commit the verified checkpoint.
- [ ] Continue to recovery-driven repeated probe/candidate scheduling and versioned independent replay, then run at least two complete native ramp/reset/recovery cycles before production activation.

## Test commands

Parent serializes heavy jobs under `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:

```sh
swift test --package-path ios/Packages/ScorebugStreaming --filter PublishingCandidateCampaignOwnerTests
swift test --package-path ios/Packages/ScorebugStreaming
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination platform=macOS -derivedDataPath ios/DerivedData -parallel-testing-enabled NO test CODE_SIGNING_ALLOWED=NO
```

Use unique `artifacts/qa/candidate-campaign-owner-*` logs. Missing API assertions establish RED; behavioral race tests must also pass after implementation. No original recordings, prior source trees or frozen raw evidence may be overwritten.

## Native integration boundary

The reusable owner now creates fresh measurement/transport pairs, and the real
DEBUG route sends compressed audio through its current-entry router. A
`NativeCandidateAttempt` owns the begin task before a handle exists, so cancellation
can join even a late startup. Final publisher stop retires that attempt and closes
the reusable owner before export. This route still performs one measurement per
publication; the two-attempt native factory test proves resource lifecycle only,
not two streaming ramps.

`PublishingVideoStartupOwner` intentionally freezes first-frame evidence. Its
receipt must not become the current-profile check after a resolution change.
The follow-on native scheduler needs a verified current configuration receipt,
applied revision and publishing generation from `PublishingQualitySession`, plus
fresh recovery evidence. Restart must begin a locally owned newer v3 probe campaign,
join the old candidate work and retirement, then allocate fresh attempt authority
and diagnostics. A suspended append or receiver read must retain its original
attempt revision so it cannot offer to or revoke its successor.

The existing `NativeBandwidthProbePublisher` still starts legacy staged v2 and has
one work task and one diagnostic export. Add an explicit repeated-campaign route
and versioned per-campaign audit/replay before scheduling a second measurement.
Do not overwrite the prior measurement or treat successful resource retirement as
healthy recovery. Require two independently replayed native ramp/reset/recovery
cycles before production activation. Native-only bridge and admission changes do
not alter archive encoding or scoring behavior.

`QualityController` currently keeps `recoveryStart`, `latestStrongHealth`, active
trial/application state and cooldown private. Expose bounded measurement readiness
from that existing policy rather than duplicate recovery timers in the native
scheduler. Such readiness can request work but cannot authorize an increase:
`evaluateCandidate` must still revalidate fresh overlapping receiver health,
candidate identity, measured cost and delivered headroom when the result arrives.
Invalidate pending work on revision, publication, recovery or ownership changes;
recheck the verified current receipt after every asynchronous startup boundary.

Initial parent verification: 14 focused owner tests (including real native paired
startup twice), all 167 Streaming tests, all 405 FilmModel tests. Failing-first logs
cover missing owner/bridge/retirement APIs and campaign mismatch/export assertions.
Evidence namespace: `artifacts/qa/candidate-campaign-owner-*`. Release build,
independent quality review, native media regression and frozen-evidence verification
are recorded below after completion.

## Recovery replay correction found during native verification

The first native run, `native-app-1NvzaV`, exited 1 because the recovery verifier
excluded a preceding report of the same intentional decoder pause. Row 783 was
already stalled at PTS 6835081; row 784, consumed by the policy, retained the same
scope/PTS. Its conservative reaction bound was approximately 1.229 seconds, inside
the existing 1.5-second limit. The prior verifier began its pause allowance only
at row 784 and incorrectly rejected row 783.

The verifier now extends that allowance only through adjacent earlier reports of
the identical stalled PTS/scope. It preserves exact trigger causality and checks
the existing reaction budget and report expiry; full continuity still checks
ownership, 250 ms freshness and 500 ms gaps. This grants no healthy recovery credit
and changes no runtime media behavior. An earlier separate stall, changed identity,
unavailable/stale/expired evidence or excessive reaction time still rejects.

The new positive regression failed before the correction. All 2,289 tooling tests
pass after it. Independent spec and quality reviews approved both changes. Replay
of the unchanged first run now proves 10.0014 seconds of shared healthy recovery;
its original failed harness exit remains 1, and earlier negative fixtures remain
rejected. The fresh full run uses new source hashes and a separate evidence folder.

## Current checkpoint: native recovery gate remains open

The fresh run `native-app-GfdMuX` also exited 1, for a separate valid rejection:
post-reset two-second delivery row 125 contained 59 proven on-time frames and one
uncertain frame. For source PTS 13467/60, the conservative arrival latency interval
was 1.327065–1.503193 seconds, crossing the unchanged 1.5-second deadline. Its
sample-age uncertainty was 176.129 ms. No missing or proven-late frame was reported
in that row. Neither the uncertainty nor the failed native exit is relabeled.

Saved-media replay passes independently: the clean 1080p archive has 3,645 consecutive
frames at 30 fps and all 60 audio markers; acquired live media also passes the
existing frame continuity, sync and coverage checks. Both MP4s fully decoded during
the original harness before recovery qualification rejected the run. This is media
verification, not complete adaptive-recovery qualification.

All 167 Streaming, 405 FilmModel and 2,289 tooling tests pass, as does the combined
unsigned iPhone/Watch Release build. The scoped code reviews approved the owner,
native adoption and recovery-verifier correction. Tasks 4 and 6 remain open; the
native verification portion of task 5 is not complete. Prior raw evidence is
rehash-verified in `candidate-campaign-owner-final-verification.json`; both new raw
failures and the separate replay results are preserved.

Next trace the uncertain frame through native capture/submission, relay and worker
arrival timestamps, and the original delivery receipt timing. Determine whether
latency or the conservative sample bound needs attention; do not trim evidence,
change the 1.5-second budget, or count uncertainty as healthy delivery. Preserve
strict policy invalidation and require a fresh complete pass before proceeding to
repeated-cycle qualification. The autonomous goal remains active.
