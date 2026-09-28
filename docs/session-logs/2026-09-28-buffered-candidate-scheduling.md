# September 28: bounded candidate scheduling

Starting revision `a379ef1`, authoritative checkout `scorebug-local-validation`.
Simulator-first; no hardware or agents. Reused previous qualification and ran only
four affected model checks before one native workflow.

## Change and focused evidence

Reapplied the saved four-second peer / six-second decoder experiment, excluding
the already-committed bounded stop policy. Added a production-only scheduling wait
based on actual source period and current arrival phase. Candidate measurement
stays four seconds; admission expiry stays two seconds. The extra wait is capped
at one source period, renews the probe, and grants no admission authority. Actual
fresh source overlap, owner, pressure and receiver checks remain mandatory. Fixed
laboratory ordering and ordinary short-lag production behavior remain unchanged.
A quarter-second scheduling margin on each boundary is an engineering allowance,
not a published platform default. Delays outside the feasible horizon reject.

The real-time model reproduces the original `source-candidate-overlap` rejection
with 5.18 seconds of decode/report lag. The fixture needed pressure history covering
that older source interval; otherwise it rejected missing pressure before reaching
the scheduling fault. Preserved red log `/tmp/scorebug-buffered-candidate-red.log`.
After the fix, buffered production admission, short-lag production, fixed-order
rejection and invalid/bounded scheduling cases all pass: four tests, zero failures,
37.643 seconds (`/tmp/scorebug-buffered-candidate-green.log`). No full model suite.

## Integration

One native run `ordinary-native-kStE7J` uses the prepared real-match source and
`--lane recovery720 --publish-peer-latency-ms 4000`. Log:
`/tmp/scorebug-buffered-native.log`. Result pending; do not treat the experimental
production timing selection as qualified. All old failed media remains preserved.

## Outcome and retained implementation

`ordinary-native-kStE7J` / `device-lab-17vd4L`: full native workflow and cleanup pass.
Independent native, transport, geometry and all five application transitions pass.
Both increases and both confirmations work through 720p, including after the fault.
Minimum acknowledgment occurs 1022–1055ms after the constraint request.

The clean archive passes:12,991 consecutive30fps frames, no audio gaps,32ms A/V end
offset. Both live outputs fully decode and have identical12,583 observed frames,
but fail strict media:149 missing IDs,6 repeated/non-increasing observations,
13 identity discontinuities,15 audio gaps and a4.033second maximum video gap.
Archive continues127frames past live. A/V ends are within97ms in both live outputs,
qualifying the bounded stop change at this actual4second negotiated peer setting.
The packet diagnosis rejects truncated NAK ranges; that evidence remains incomplete.
No waveform/score or phase-media pass is claimed after the strict media failure.
Native process76360 joined0; offline process15938 joined1. No live jobs remain.

This disproves the larger-buffer candidate as an improvement over the prior severe
congestion result. Restored the production factory to3000ms and API/lab peer bound
to120–2000ms, with default still unset. No parameter-only retry. Retain the bounded
scheduling fix and its passing regressions. The explicit6000ms timing contract and
matching independent/native diagnostic guards remain available for scoped experiments;
it is not the production selection and does not authorize a route or relax expiry.
Prior saved patch checks cover these unchanged guards/contracts; the current native
build and selected model checks pass. Changed JS/TS/JSON formatting and Git diff
checks pass. No broad suite or hardware work.

Preserved logs and pre-restoration implementation patch:
`artifacts/qa/buffered-candidate-scheduling-20260928/`. The run also captures its exact
implementation. Main plan closes already-covered relay credential/drain/cleanup work
from the earlier real integration, rather than running it again.
