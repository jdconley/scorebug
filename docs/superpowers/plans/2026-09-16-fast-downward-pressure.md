# Faster downward pressure response

Continue the authorized portable streaming/Watch plan in the existing validation
worktree. Local recording and all live-media qualification gates remain unchanged.

Design: introduce an explicit core local-pressure entry point with a 0.25-second
minimum. Require absent source, receiver and capacity evidence, unknown connectivity
and worker pressure, and at least one unhealthy local metric. Ordinary evaluations
retain their one-second minimum. Reuse all ownership, revision, freshness, monotonic
clock and nonoverlap validation; local observations cannot establish recovery.

Use the same quarter-second window in the app adapter, retaining actual enclosing
samples after acknowledgment and independent metric endpoint selection. Add an
explicit transport-limit opt-in for the simulator: compare each sample's RTT with
min(caller RTT limit, positive measured sender delivery delay / 4). Missing/zero
delay means unknown unless another explicit transport condition proves pressure.
The rule is conservative admission guidance, not a delivery guarantee: Haivision
recommends roughly four RTTs on a fairly good network:
https://doc.haivision.com/SRT/1.5.4/Haivision/latency . Actual sampling and native
profile completion still bound response time; no claim of a 120-ms response.

Version four raw evidence replays this policy independently. Versions one/two
retain five-second local windows, version three one-second windows, and all three
retain their fixed RTT classification. Source windows remain 1–5.25 seconds.

- [x] Causal core/app/replay tests for subsecond reduction/rollback, forbidden
      healthy/source input, recovery-aware RTT, unknown delay, per-sample binding,
      post-ack boundaries and cross-version rejection.
- [x] Implement the explicit local path and opt-in transport classification;
      wire simulator driver and independent version-four replay.
- [x] Run core, app-model, tooling and unsigned combined Apple build; review diff.
- [x] Run unchanged 240-second native rate4m fixture. Independently verify archive,
      actual response timing, receipt binding and live-media gates. Record failures
      candidly, join owners, verify cleanup, hash terminal evidence and commit.


## Verified checkpoint

Causal tests reproduce quarter-second rejection, missing-delay false health,
late fixed-limit RTT classification, and unrecognized evidence version before
implementation. Final checks pass: 294 core tests, 208 app-model tests, 979 tooling
tests, unsigned combined iPhone/Watch Release build and read-only review. Runtime
source matches the pre-run snapshot. The new policy is enabled in the simulator
fixture; production automatic adaptation remains disabled.

The unchanged 240-second rate4m run `native-app-QEo8uZ` completes its UI workflow.
All 74 local quarter-second windows independently replay; all four actual native
profile applications bind to their admitted operation and native receipt. First
local pressure evaluates at bootstrap +59.903 seconds and the lower profile
acknowledges at +60.371, about 0.95 seconds earlier than the preceding run. The
higher trial at +116.539 rolls back at +117.438 (0.900 seconds, previously 1.70).
Native completion itself still takes 451–470 ms. The first eligible post-ack RTT
pressure sample is +59.844, RTT 79.792 ms, sender buffer 23 ms, delay 120 ms.
An earlier retained startup sample precedes bootstrap; it is diagnostic only and
is excluded from this eligible-pressure comparison.

All 999 distinct retained collections report 120 ms delay; collection cadence is
255.55 ms median, 264.50 ms p90. The 38 accepted source windows remain 1.713–1.936
seconds old, median 1.803. No receiver freshness or source duration gate changes.

The independent archive passes: 8116 consecutive 1080p/30 frames over 270.533
seconds, all 135 A/V markers, 14.67 ms end difference, no rejected/dropped samples.
Native publishing retains all 7768 consecutive source positions across five
encoder phases. The live file contains 7672 frames spanning 7708 positions, a
36-frame count deficit (0.467%, previously 1.687%). Crucially, that is not identity
loss: it contains 7641 unique identities, 67 absent positions and 31 repeated
observations, with 11 non-increasing adjacent barcodes. All 17 cadence/identity
anomalies cluster around the two downward transitions, starting at source 1972
and 3684. No anomalies appear around the final upward transition at 5605.

The worst five-second receiver window improves from 14.2 to 25 fps. Live A/V end
coverage passes; audio PTS gaps total 43.27 ms (maximum 21.52 ms). Full live
qualification nevertheless fails: presentation cadence does not match source
identity, and the independent profile/identity check rejects repeated/regressed
barcodes. No replacement qualification or fabricated profile proof is supplied.
The owned ingest logs two invalid-PES decoding events and normal end-of-stream;
these diagnostics do not establish the packet-level cause of every absent frame.

Runner exit 1 is the unchanged media gate; independent retained-artifact analysis
exits 0. All owners are terminal/joined, collector stopped, owned simulator and
container absent. Terminal evidence manifest:
`artifacts/qa/fast-downward-final-verification.json`.

## Next investigation

This change fixes the local decision delay and crosses the measured 24-fps floor
in this single run; it does not qualify production adaptation. Preserve it as a
measured checkpoint and investigate the remaining damaged access units around
downward geometry changes. Distinguish missing source identity from total frame
count: concealment/repeats account for 31 observations in this run.

Relate packet/PES loss and decoder recovery to the exact encoder-transition and
IDR boundaries before changing transport settings. A longer negotiated SRT delay
may protect the native replacement interval, but it would also consume receiver
freshness headroom. Any experiment needs an explicit bounded model of intentional
transport delay versus evidence freshness, independently replayed and tested;
do not silently extend existing deadlines or weaken frame identity/cadence gates.
Physical iPhone/Watch, paired networking, long camera/storage/thermal soaks, other
GPU/cloud hosts and production adaptation remain open under the main plan.
