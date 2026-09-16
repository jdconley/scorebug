# Measure publish-leg SRT recovery delay

Continue the autonomous plan from 68466c3. The previous checkpoint is progress:
automatic/slice decoding is explicit, healthy media checks pass, and the native
pressure run recovers about 0.50 seconds of receiver freshness headroom while
preserving all clean local archive frames. Full live qualification still fails.
All prior workloads are terminal and owned resources removed.

Design: add optional `SRT_PUBLISH_PEER_LATENCY_MS` (integer 120–2000) to the API.
Unset preserves existing publish and read URLs. The native publishing URL alone
gets `peerlatency` in milliseconds, as consumed directly by the vendored native
SRT socket-option parser. Do not put this value on the FFmpeg read URL (whose URL
latency units differ), alter capability identity, or modify the relay listener.
The negotiated sender delivery-delay statistic remains the runtime authority.

For the experiment retain slice decoding and all prior native settings; request
400 ms publishing peer latency. The additional nominal 280 ms fits within the
observed headroom, but only actual receiver age/media can establish suitability.
The controller already binds RTT pressure to each sample's measured recovery
budget; changing that measured budget is an expected effect, not a separate
threshold edit. Production adaptation remains disabled and the two-second source
freshness cap, archive/media gates, native profile changes and read-leg delay are
unchanged.

- [x] Add failing configuration, grant/lifecycle/HTTP and fixture-option tests.
- [x] Implement explicit propagation and deterministic fixture configuration.
- [x] Run API build/tests, tooling checks and read-only review.
- [x] Snapshot runtime source; run unchanged 240-second native rate4m workload with
      slice decoder and the 400 ms publishing option. Observe negotiated delay and
      ingest diagnostics before cleanup; retain stopped native evidence.
- [x] Independently verify archive, controller evidence/receipts, receiver age,
      live identities/cadence/A/V coverage; preserve failed gates.
- [x] Join every owner, verify exact cleanup, hash terminal evidence, update plan
      and commit the checkpoint. Decide next work from measured results.

Primary protocol reference: https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md
Native URL interpretation: `vendor/HaishinKit/SRTHaishinKit/Sources/SRT/SRTSocketOption.swift`.

## Pre-run verification

Four API tests failed causally on absent parsing/validation and publish URL wiring;
the fixture parser test failed because its export did not exist. Implementation
passes 388 API tests and 982 tooling tests. The API build initially found an exact
optional-property type mismatch; conditional omission fixed it, and the build plus
API suite pass on the final runtime sources. Read-only review found no blockers.
The source snapshot is based on 68466c3. No Swift/worker media behavior changed.

## Native pressure result

`native-app-wkcOi6` completed the native UI workflow but failed the full runner on
non-monotonic decoded source identities. The comparison helper confirms identical
saved fixture settings to `native-app-a0fhIU` except the newly explicit 400 ms
publishing delay. These sequential simulator observations are not a repeated-run
estimate and cannot establish a general latency recommendation.

- Negotiation is verified independently: all 999 retained native sender gauges are
  400 ms. The owned relay API reports publish receiver delay 400 ms and read-side
  sender/receiver delays 120 ms; the unneeded reverse direction on the publishing
  connection remains 120 ms. The recorded configuration alone is not the proof.
- The archive preserves all 8152 consecutive 1080p/30 frames over 271.733 seconds,
  all 135 audio timing markers, 9.3 ms end-coverage difference and zero rejected or
  dropped queue samples. Native publishing observes 7798 consecutive frames.
- All 69 quarter-second local pressure windows replay against retained evidence.
  Four profile applications bind to actual native receipts and meet admission and
  completion budgets (444–472 ms completion). First decrease acknowledgment is
  60.435 seconds after bootstrap; the upward trial rolls back in about 1.12 seconds.
- Accepted receiver source age is 1.616 seconds at the median, range 1.495–1.766
  across 42 windows, versus prior 1.324 median. The two-second cap is unchanged.
- Live receiver minimum improves from 20.2 to 22.0 fps, still below 24. Live A/V end
  coverage now passes, with 107.5 ms total positive audio-PTS gaps (largest 42.5 ms).
  However, 7677 decoded pictures span 7738 source positions: count deficit 61,
  but 142 unique source identities are absent and 81 observations repeat, including
  51 non-increasing barcodes and 57 identity/cadence anomalies. This is worse than
  prior 57 absent/five repeated; count deficit alone understates the problem.
- Damaged identities cluster around the two downward geometry changes. The relay
  reports two invalid PES events; the worker reports 210 decode-error messages and
  zero concealment-category messages. Diagnostic counts are not damaged-frame
  counts. The impairment proxy drops 1184 overflow packets versus prior 943, despite
  unchanged queue limits and schedule. These data do not identify which packets
  carried the missing source frames or prove a specific causal mechanism.

Decision: retain the explicitly configurable option with **unset defaults**; do not
promote 400 ms as a reliability setting or enable production adaptation. Longer
buffering alone has not met the requested 24-fps floor and made identity loss worse
in this run. Next inspect encoded-frame bursts, packet queue/drop timing and
IDR/access-unit recovery around native geometry changes. Correlate those against
source identities and native application receipts before another latency change.
Avoid increasing the freshness cap or treating PTS-only fresh-frame counts as proof
of undamaged pictures. Physical devices, long soaks and other hosts remain open.

Evidence: `artifacts/qa/publish-recovery-*`, runtime source snapshot, independent
native/residual analysis and `publish-recovery-comparison.json`. Owners are joined;
the finalizer verifies exact owned container/simulator removal, stopped collection,
unchanged runtime snapshot and identical retained/final stopped QA before hashing
source and terminal artifacts. The failed full-live gate remains failed.
