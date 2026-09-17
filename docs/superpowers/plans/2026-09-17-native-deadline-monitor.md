# Native deadline monitor implementation plan

> Execute inline using test-driven implementation and independent review under the approved progressive-streaming design.

**Goal:** Run source/deadline classification against the live native capture loop and qualify the resulting evidence with a loopback simulator/relay experiment.

**Architecture:** A bounded monitor schedules nonoverlapping windows independently for the one-second FPS and two-second loss checks. Each window is consumed once; a later report cannot repair it. Native/worker/publication/configuration changes start a new schedule. The quality driver reads a caller-owned current input provider after awaiting its state, preventing captured asynchronous inputs from reviving retired evidence. The monitor observes only; no quality action consumes its result yet. Debug export contains scalar source/configuration, authenticated timeline and classification evidence for independent reconciliation.

- [x] Add failing scheduler/monitor tests for windows, deadlines, duplicate polls, missing evidence, ownership changes, clock reversal and bounds. Implement `PublishingDeliveryMonitor.swift` and integrate the existing classifier.
- [x] Add a current-input provider to `PublishingQualityDriver` and supply it from `CaptureStreamingModel` under the existing publishing/recording/tap/attempt guards. Test provider lifetime and teardown. Enable the monitor only in the explicit cadence/controlled-stall simulator fixture.
- [x] Export bounded `delivery-deadlines.json` on joined teardown; include proof inputs and outcomes without credentials or media. Extend the native harness to preserve and independently verify it. Test the verifier with damaged variants.
- [x] Run native model/tooling tests and a real loopback simulator capture/relay experiment with the owned decoder pause. Compare late/missing/floor observations, archive continuity, complete output decode and authenticated freshness. Keep any failed evidence and correct demonstrated causes.
- [x] Run required Core/model/tooling suites and simulator/unsigned iPhone/Watch builds; request independent review, preserve all previous frozen evidence, freeze new hashes and commit. Leave controller activation, candidate headroom/recovery, devices and remote workers gated as appropriate to actual evidence.

The initial experiment uses an explicit one-second capture-to-decoder deadline and 250 ms maximum sample-age uncertainty, not a claim that these are universal streaming defaults. The distinct window lanes must not later be counted twice as recovery health.

## Measured result

Actual iPhone 14 / iOS 17.5 simulator run `native-app-AG9LAw` used fixed
240p30 publication, independent 1080p recording, 400 ms SRT peer latency,
relative pacing, slice decoder threading and an owned 2.040-second decoder pause.
The native monitor emitted 150 windows; independent raw-report reconstruction
agrees with all 124 classified windows. Another 26 remain unknown due to freshness.
Across overlapping lanes there were 27 late, 68 missing-at-deadline and 4,855
uncertain frame observations; these are not unique frame counts. No window proves
healthy delivery with the experimental one-second budget. One completely classified
window proves below-24 on-time FPS. Eventual live output has zero source loss;
buffered catch-up cannot repair a deadline failure.

The archive fully decodes at 1920×1080 with 3,658 frames, 60/60 audio markers and
successful recording finalization. The live output fully decodes with 3,263 frames,
54/54 markers and approximately 30 FPS. Matched arrivals in classified one-second
windows have conservative upper latency p50 1.133 s, p95 1.180 s and p99 1.201 s;
this population includes the pause but excludes unavailable arrivals and rejected
windows. Detailed bounds and limitations are preserved in
`artifacts/qa/native-deadline-latency-analysis.json`.

Next test a separately recorded 1.5-second deadline, leaving the 250 ms freshness
cap and controlled pause unchanged. This measured margin is an experiment, not a
production latency promise. Healthy baseline, recovery, controller integration,
actual candidate cost/headroom, reconnect, physical devices and remote workers
remain unqualified. The monitor currently observes without taking quality actions.

Verification: 372 Core tests, 273 native model tests, 1,313 tooling tests, ARM64
simulator build-for-testing and unsigned combined iPhone/Watch Release build pass.
Review regressions preserve an older decoder anchor during silence and make the
Node verifier's owner-history exhaustion permanent like the Swift tracker. A
separate boundary regression ensures clock-reconciliation tolerance cannot reduce
the age bound used for freshness, coverage or arrival classification. The
final verifier independently replays the immutable actual-run exports; its source
hash is separate from the earlier verifier loaded when the live run started.
Frozen evidence: `artifacts/qa/native-deadline-final-verification.json`.
