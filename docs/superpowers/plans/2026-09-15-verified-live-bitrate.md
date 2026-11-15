# Verified live bitrate application

Continue after the ingress-observation native qualification. Use bounded
implementation with independent specification/quality review; keep one owner for
native/media execution. This is the next diagnostic/control primitive, not approval
to enable automatic adaptation or change resolution.

## Source findings and bounded design

`SRTPublisher.setBitRate` currently reads/modifies the generic SDK settings. The
`VideoCodec.settings` observer calls `VideoCodecSettings.apply`, which discards the
native property-write status and accepts a missing session. In average-rate mode,
`makeOptions` resolves default data-rate limits from bitrate, but `apply` changes
only the bitrate property. A later update can therefore retain the previous native
burst cap. These are source findings, not measured causes of past media failures.

Add a dedicated synchronous throwing update through the SRT actor, outgoing stream
and codec. Preserve initial generic configuration separately. Require the matching
publishing lifecycle, open input, a running compression session, no pending session
invalidation and no publishing/finishing failure before attempting a write. The
codec's `passthrough` flag controls timestamp handling and is true for the current
raw encoder; it cannot identify compressed passthrough. SRT compressed input bypasses
the codec, and must not receive a false update acknowledgment.

Start with the configured average-bitrate mode. Validate the requested rate before
mutation. Share effective data-rate-limit resolution with initial options: default
`[0, 0]` resolves to `[bitRate / 8 * 1.5, 1]`, explicit limits remain explicit and
`nil` remains absent. Check native status on all required writes, then read back
bitrate and applicable limits with strict type/value validation. Commit stored
settings only after verification, without triggering a second unchecked write via
`settings.didSet`.

A preflight rejection leaves a healthy stream running. A failure after an attempted
native mutation leaves applied state uncertain: return a typed error, acknowledge
nothing, and terminate only live publishing through its existing failure latch.
Keeping the old settings value does not prove native rollback. The local archive
must remain independent.

Two boundaries require explicit design before implementation:

- Codec notification selectors currently mutate session invalidation outside the
  SRT actor. Serialize or otherwise synchronize invalidation with the update path;
  an actor method alone does not establish lifecycle safety.
- Native property readback establishes accepted settings, not achieved output rate,
  transport capacity or the exact frame where a change becomes effective. Do not
  assign already queued encoder completions to a new profile revision. Attempt and
  caller ownership must be rechecked across adapter awaits, and policy activation
  still requires a separate transition/source-boundary design.

## Implementation and evidence sequence

1. Specify the synchronous update result/error and invalidation ownership boundary.
   Use a narrow internal session/property fake with native production defaults.
   Add failing tests for absent/decompression sessions, pending invalidation,
   invalid requests, native write/readback errors, malformed or mismatched readback,
   second-property failure and unchanged-request verification.
2. Implement shared limit resolution and verified settings commit. Test default,
   explicit and absent limits against initial options, exactly one commit, and
   terminal uncertainty after any attempted mutation fails. Preserve initial
   configuration behavior and existing encoding/finish tests.
3. Integrate SRT publishing/finishing identity guards and the app adapter. Use the
   existing SRT finish tests and `SRTMediaPublisher.Operations` seam for cancellation,
   overlapping stop and late-success suppression. No controller enablement.
4. After focused/full affected suites and independent review, extend the existing
   small native codec fixture: create an encoder, verify changed properties, continue
   encoding and drain. Check real output continuity separately from configuration
   acceptance. Run Apple builds for simulator and device configurations. A further
   long native workflow needs a concrete unresolved concern; do not repeat it merely
   because the setter has a new isolated test.

A bounded read-only source review agrees with this direction and identified the
notification-invalidation and profile-boundary limitations above. That review preceded
implementation; the completed evidence is recorded below.
Runtime adaptation remains disabled.

## Lifecycle design decision before implementation

A read-only lifecycle review approves a narrow revision owner for codec invalidation.
Only that owner is lock-protected; notifications replace its revision, and session
creation records the revision it actually consumed. A concurrent invalidation must
remain pending instead of being cleared by session creation. No lock is held during
native property operations or callbacks. The verified update rechecks invalidation
and the asynchronous codec failure latch before committing stored settings.

SRT ingress must separately track the latest raw/compressed input representation:
compressed input bypasses the outgoing codec and can leave an earlier raw encoder
alive. Encoder output must not change this ingress state. Reset the state per
publishing generation and require raw input for a verified update.

The app adapter owns the captured SRT generation and rejects startup/stopping/stale
operations. A single update may be in flight. Preserve the stop policy's underlying
transport health predicate after marking the adapter stopping; otherwise graceful
drain would be skipped. Pre-dispatch cancellation makes no encoder call. If native
verification completes before cancellation is observed, first commit that verified
native state, then suppress caller acknowledgment and close the live publisher so
an abandoned change cannot leave the policy believing old settings remain applied.
The clean archive is outside this path. No profile revision or source-frame boundary
is reassigned by these changes.

## Implemented native verification and lifecycle checkpoint

The dedicated SDK path now checks native writes and typed exact readback for average
bitrate and effective data-rate limits, then commits backing settings without a
second unchecked write. Boolean/nonfinite/malformed and lossy integer readbacks fail.
The initial generic configuration path retains its prior option-resolution behavior.
Native write/readback uncertainty latches live codec failure; preflight rejection
makes no property call. Codec notification invalidation uses a narrow locked revision
owner and cannot be erased by overlapping session creation.

SRT checks publishing generation, finishing state, live failure and actual raw-input
representation before reaching the encoder. A raw-to-compressed transition cannot
update the retained raw encoder. The app adapter captures its generation after
startup and retires it before stop while preserving the stop policy's drain health
predicate. The media wrapper allows one update at a time, rejects pre-cancelled work,
and closes live publishing when a dispatched update is abandoned by cancellation.
No profile revision, source-frame boundary, controller enablement or archive path
changes are included.

Verification so far has actual exit 0:

- 16 native-property helper tests, with a failing precision regression before the
  exact Int64-to-Double comparison fix.
- 9 codec lifecycle tests after 21 behavioral-red assertions; 10 SRT finish tests
  including the three new identity/passthrough/finishing tests after 8 red assertions.
- Full SDK: 105 Swift Testing tests. Real native encoders accept/read back 1 and
  3 Mbps plus matching burst limits, then emit/drain all 20 expected frames. The
  SRT fixture independently verifies continued transport of final frames after a
  real update. These tiny fixtures do not establish achieved target bitrates.
- Full ScorebugStreaming: 21 XCTest tests, after 6 expected adapter-red assertions.
- The no-network SDK smoke now explicitly verifies that a pre-publish live update
  is rejected. The original smoke assumption was corrected after independent review.
- The combined iPhone/Watch Release and arm64 simulator Debug builds pass. Maintained vendor patch verification
  checks all 162 original source hashes and an exact reverse/forward round trip;
  it includes the two added codec primitives and 13 modified upstream files.

Separate specification and quality reviews approve both the property helper and
lifecycle integration. Logs are `artifacts/qa/verified-bitrate-*.log`.

## Five-scenario native dual-output qualification

At implementation commit `48155ea`, `pnpm test:dual-output` exits 0 with evidence in
`artifacts/qa/dual-output-tT1UH7` and `verified-bitrate-dual-output.log`. The existing
14-second Mac harness changes the real app adapter from 6 to 2 Mbps after five
source seconds, exercising the dedicated native write/readback path.

| Scenario                       | Archive frames |      Live frames | Measured video rate before → after | Peak RSS |
| ------------------------------ | -------------: | ---------------: | ---------------------------------- | -------: |
| Record only                    |            420 |                — | —                                  | 75.7 MiB |
| Normal                         |            420 |              420 | 6.135 → 1.982 Mbps                 | 94.5 MiB |
| Normal, source clock +123.25 s |            420 |              420 | 6.068 → 2.016 Mbps                 | 94.7 MiB |
| Stalled receiver               |            420 | Failure reported | —                                  | 81.3 MiB |
| Absent receiver                |            420 | Failure reported | —                                  | 76.1 MiB |

All archives retain source frames 0–419 at 30 fresh fps, with no archive rejections,
complete audio coverage and all six expected audio markers. Maximum archive marker
offset is 0.021 ms and audio tail padding is 14.667 ms. Both normal live outputs
retain frames 0–419 with no source-frame loss; their minimum five-second cadence is
29.8 and 30 fps. All seven live audio markers match, maximum offset is 65.375 ms,
and audio tail padding is 15.988 ms, within the unchanged 100 ms coverage gate.
Maximum producer lag across all scenarios is 9.941 ms (250 ms limit). Archive and
live queued bytes remain below their 24 MiB and 12 MiB budgets. The absent receiver
causes live evictions/rejections while the archive remains complete; those live
losses are expected and are not described as successful streaming.

This is measured output-rate evidence for these short local workloads, separately
from native property acceptance. It does not identify the first affected frame,
qualify available network capacity, prove physical iPhone performance, or extend
the earlier ten-minute app run to this new implementation. Production source-clock
correlation and profile-transition boundaries remain the next prerequisites, followed
by qualified capacity/pressure inputs and impairment tests before policy activation.
