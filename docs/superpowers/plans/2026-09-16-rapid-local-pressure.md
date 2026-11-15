# Reduce live quality promptly on independently measured local pressure

The previous goal turn made verified progress: native profile trials now complete
within a separate bounded execution budget, and the UI/recording workflow passes.
The unchanged pressure run still has an 8 fps receiver window, missing/repeated
pictures and audio gaps. Native trial rollback occurs about six seconds after the
higher-profile acknowledgment. Source inspection finds that local pressure must
wait for a full five-second window after either the acknowledgment or the shared
policy watermark, even when fresh local samples already show congestion.

Reproduce that delay with the actual adapter and known post-ack transport samples.
Use a fixed one-second window for local pressure only, matching the policy's
existing minimum measured duration. Preserve independently bracketed observations,
actual collection timestamps, freshness, scope, configuration, post-ack samples,
non-overlap and unknown receiver/capacity fields. The shorter window may reduce
quality or roll back a trial; it cannot establish healthy delivery or authorize an
increase. Keep all pressure thresholds, native statistics sampling and receiver
health/probation gates unchanged for this experiment, so the effect is attributable
to the decision window.

Version-three quality evidence declares this new local-window contract. The
independent verifier reconstructs its one-second endpoint and raw pressure;
versions one and two retain their five-second local-window requirement and existing
admission behavior. Full A/V, frame identity, loss and cadence gates stay unchanged.

- [x] Reproduce missing immediate pressure decisions after an acknowledgment and
      after a recent receiver window.
- [x] Change only the local pressure duration; cover boundaries, sparse/missing,
      pre-ack, wrong-scope, stale, gapped and overlapping evidence.
- [x] Version and independently replay the shorter window; test legacy isolation.
- [x] Run app-model/tool checks and unsigned iPhone/Watch build; review.
- [x] Repeat unchanged native pressure and verify the independent archive plus
      the remaining live-media failures or success.

If one-second local decisions still cannot protect media, use retained source and
transport evidence to identify the next bottleneck rather than easing qualification.
The native statistics cadence and congestion thresholds are separate future
experiments. Production adaptation, long soaks, devices and remote hosts remain open.

## Verified checkpoint

The causal adapter tests failed before the duration change; the version-three
verifier and producer tests likewise failed before their corresponding changes.
All 203 app-model tests and 959 tooling tests now pass, along with the unsigned
combined iPhone/Watch Release build. Read-only review found no blockers: local
pressure remains reduction-only, post-acknowledgment and nonoverlapping; receiver
probation and legacy evidence contracts remain unchanged.

The unchanged iPhone 14 / iOS 17.5 pressure run `native-app-HAW17U` completes its
native UI workflow. The independent replay validates all eleven one-second local
pressure windows from their raw observations, and native receipts bind all four
profile changes to the actual encoder sessions. The first higher trial rolls back
2.532 seconds after acknowledgment (decision at 2.074 seconds), compared with
about 6.06 seconds in the preceding run. The later higher trial stays at 1080p
through normal stop. Controller confirmation is not independent media qualification.

The archive independently passes: 8110 consecutive 1080p/30 source frames over
270.333 seconds, all 135 A/V markers, 1.33 ms end coverage difference, and no
rejected/dropped archive samples. Native publishing retains 7767 consecutive
source identities across five format phases. After the explicit 60-frame live
acquisition, the recorder contains 7486 frames across 7707 source positions:
a 221-frame count deficit (2.868%), plus 46 non-increasing decoded barcodes.
The count deficit is not full source-identity loss qualification.

Live qualification remains failed: 292.1 ms A/V end coverage discrepancy, worst
five-second receiver window at 5 fps, and the independent monotonic source-identity
gate fails. Audio PTS gaps total 301.1 ms, maximum 43.0 ms. One SRT reader recovers
from initial PES/timing damage, stays connected through further PES damage, and
ends at normal stop. The configured 60-second 4 Mbps phase and subsequent traffic
pass schedule verification; they do not establish media quality. No gates were
relaxed. All owned sessions are joined, the container and simulator are absent,
and the status collector is stopped.

The initial 5 fps window precedes effective reduction. At 59.914 seconds from
bootstrap, native transport reports a 48 ms sender buffer and 135 ms RTT, with no
retransmissions. At 60.915 seconds it reports 279 ms / 488 ms and retransmissions;
the pressure decision occurs at 61.203 seconds, with native reduction acknowledged
at 61.656 seconds. Actual SDK statistics are collected about once per second; the
app's 250 ms health loop reads that cache. Do not retimestamp cached statistics as
fresh. Next isolate earlier congestion detection (actual sampling cadence and
buffer/RTT thresholds as separate experiments), then assess backlog/keyframe
recovery if losses persist. These observations identify a hypothesis, not a proven
fix. Reconnectable destination recording, longer soaks, devices and other hosts
remain open; production adaptation remains disabled.

Terminal evidence and hashes: `artifacts/qa/rapid-pressure-final-verification.json`.
The retained run includes an exact pre-run source snapshot, stopped quality and
format evidence, sanitized ingest diagnostics, independent archive/live analysis,
and verified cleanup. The analysis deliberately does not pass fabricated profile
qualification into the full policy verifier after the real source-identity failure.
