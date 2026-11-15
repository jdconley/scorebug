# Fresh decoder-stall minimum reset

Continue the approved progressive-streaming design with a downward-only decoder
watchdog input. Do not convert arrival windows into source loss or healthy FPS.
The worker must explicitly observe at least one second without advancing decoder
PTS. Only a fresh, currently associated publication may supply that observation.
A missing response, old sample, changed encoder or pre-transition sample cannot
manufacture a stall.

Use a separate `QualityController.DecoderStall` input with current attempt/revision,
shared decision sequence and conservative sample-time lower bound. Require that
bound to be at least one second after the actual encoder acknowledgment, and its
age to be at most 250 ms (an initial qualification budget, not a proven deployment
setting). This does not claim the worker's observation was an exact local window.
A valid stall uses the existing sticky minimum-reset state machine, including
in-flight upward-write revocation and minimum/no-op behavior. It cannot accumulate
healthy coverage or authorize an increase.

The native telemetry adapter binds the freshness helper to current ingress match,
broadcast, publishing attempt, native receipt and transport generation. The session
tracks decoder scope/progress independently from source-window ownership, deduplicates
one stalled PTS, rejects regression and invalidates recovery on scope changes. The
capture model stores/clears the helper with the current publishing attempt and passes
it through both control and local health ticks. The driver processes this signal
before source-window adaptation; legacy behavior remains explicitly unchanged.

- [x] Write failing Core tests and add the scoped, downward-only stall admission.
- [x] Write failing native telemetry/session tests for age, post-ack timing,
      ownership, duplicate/regressed progress and scope changes; implement adapter.
- [x] Wire helper ownership through capture/driver and test signal priority and
      absent/stale response behavior without fabricating healthy windows.
- [x] Run affected Core/native tests and Apple builds. Assess actual existing report
      ages against the budget; do not claim live reaction qualification from tests.
- [x] Freeze evidence, update the main plan and commit.

Files: QualityController.swift, ProgressiveStreamingPolicy.swift, new Core stall
policy tests; PublishingQualityTelemetry.swift, PublishingQualitySession.swift,
PublishingQualityDriver.swift, CaptureStreamingModel.swift and focused native tests.
Use the established local worktree and Xcode 26.2. Physical device, live short-report
reaction time, expected-source/lateness and candidate-headroom qualification remain
separate required gates before activating automatic progressive streaming.

## Verified checkpoint

The explicit decoder-stall input now reaches the progressive controller through
native publication/receipt binding and the coalesced capture health driver. A valid
worker observation must prove at least one second without advancing decoder PTS,
with a conservative sample-age bound no greater than 250 ms and the complete
interval after the current native acknowledgment. Wrong attempts, generations,
receipts, stale reports and regressed PTS reject. Scope changes revoke recovery or
trial evidence. Repeated stalled PTS does not issue another encoder write. Stalls
have priority over source adaptation and cannot fabricate frame counts or healthy
coverage. Windows crossing the stall receipt boundary cannot count toward recovery.
Capture stores the helper independently of optional source-history instrumentation
and clears it on mismatch, missing cadence, expiry and stop. Event traces preserve
the admitted ordinal, revision, scope, progress and sample-time lower bound separately
from source windows. Legacy behavior remains unchanged.

Verification: all 348 Core and 246 native model tests passed, as did the ARM64
simulator build-for-testing and unsigned combined iPhone/Watch Release build. New
policy and native tests first failed against stubs. Regression tests also caught
pre-stall recovery credit and an unnecessary source-history dependency. A full-suite
failure exposed a test timestamp initialized before the suite; the fixture now
creates fresh report timestamps at delivery, and the complete suite passes. Failed
runs remain in the evidence directory.

Evidence: `artifacts/qa/decoder-stall-final-verification.json`, with runtime source
hashes, test/build logs, joined process results and a report-budget assessment.
These are controller and native-binding results, not an actual adaptive media run.
The normal worker waits 1,000 ms between completed reports; that delay is included
in its conservative timing-token bound and already exceeds 250 ms. Experimental
100 ms reporting/polling needs real timing qualification. The saved minimum-startup
status snapshots contain no decoder-cadence age fields; their older five-second
video-window age results cannot qualify this watchdog. Production progressive
adaptation stays gated on that measurement, expected-source/lateness reconciliation,
candidate cost/headroom and actual automatic transitions. Physical phone/Watch and
remote-worker qualification remain outstanding.
