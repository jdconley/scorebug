# Native stall profile reset implementation plan

> Use executing-plans and test-driven-development inline; use requesting-code-review before the checkpoint.

**Goal:** Qualify a real progressive 540p-to-240p native encoder reset caused by fresh worker decoder-stall evidence while preserving independent local recording.

**Architecture:** Add exact simulator fault mode `SCOREBUG_TEST_DECODER_STALL=reset540` to the existing fixed-240 worker-output cadence fixture. Only this mode starts native input at 540p; the worker canvas remains 240p and normal app startup remains minimum. Reuse the bounded owned decoder pause and real quality session/driver. Extend existing transition observation with an explicit two-phase `stall540` evidence version; it observes the controller's operation and never schedules a second writer. Pass through the actual first-frame startup receipt from the wrapped publisher.

**Tech stack:** Swift/VideoToolbox, existing native SRT publisher, MPEG-TS/SRT, FFmpeg, Node qualification tools, Xcode 26.2/iOS 17.5 simulator.

## Implementation and verification

- [x] Add failing tests for exact reset opt-in, two-phase format/receipt evidence and rejection of damaged reset proofs. Add Swift tests for bounded two-phase collection and startup delegation.
- [x] Extend `NativeProfileTransitionSequence` with `stall540`: initial `.sd540`, destination `.low240`, phase limit two, format version seven. Record controller receipts, delegate `videoStartup`, and route the publisher without the fixed schedule.
- [x] Configure the progressive quality fixture with qualified 240p/540p descriptors, initial 540p/1.5 Mbps; retain existing 240p/350 kbps minimum. Forward the new explicit mode through UI tests. Keep legacy fixtures unchanged.
- [x] Extend compressed-frame/transition qualification for exactly two phases (540p then 240p), all frames and receipt boundaries. Use that evidence instead of the incompatible fixed-profile cost checker in this mode; this test makes no candidate-capacity claim.
- [x] Share the existing raw stall-report timing join. Require exactly one reset action, old receipt until the decision, one new encoder, the actual profile receipt plus matching new bitrate receipt, revision 0 -> 1, and unchanged new receipt thereafter. Verify admission/ack within the existing two-second native completion deadline. Require the first new-format frame and final tail downstream. Retain the <=250 ms admitted stall age and <=1.5 s decision bound.
- [x] Run targeted red/green tests, full tooling/native model/Core tests, simulator and unsigned iPhone/Watch Release builds. Snapshot exact source hashes before an actual 90-second iPhone14/iOS17.5 simulator/SRT/proxy/RTMP run.
- [x] Decode both videos, reconstruct native dimensions/source boundaries and decision/ack timing independently, retain any failures, and address demonstrated defects without relaxing evidence requirements.
- [x] Review, freeze evidence, update the main plan and commit. Keep automatic recovery, source-lateness/candidate-headroom, physical devices and remote-worker gates explicit.

## Run configuration

Use the prior controlled-stall command with `SCOREBUG_TEST_DECODER_STALL=reset540`, cadence reports/publication/processing enabled, live worker output `240p30`, blocks16 motion, direct RTMP recording, 90-second hold, slice decoder threading, 400 ms SRT peer latency and relative publish pacing. No uplink impairment, candidate probes, scheduled transition driver or automatic recovery trial is enabled. The owned decoder pauses 20 seconds after producing output and resumes after at least 1.8 seconds.

This is a fault-response test, not a startup or upward-admission shortcut. Initial high quality is confined to the explicit DEBUG simulator mode. Frame continuity in saved media does not establish uninterrupted real-time delivery through the injected pause.

## Results

Actual `native-app-1wOipN` finished with exit 0 and joined cleanup. The owned decoder
pause lasted 1,972.919 ms. One fresh native stall signal (137.303 ms conservative
sample age) produced exactly one reset application. Independent raw-report joining
bounds the decision to 1.311001 seconds after last decoder progress. The first
actual 240p compressed frame followed the decision by 461.743 ms; final verified
native acknowledgment followed by 462.874 ms. Application admission to acknowledgment
was 462.511 ms, within the existing two-second deadline.

Native observation contains 3,297 consecutive frames: 882 at 960x540, then 2,415 at
426x240. The old/new source boundary is frame 1,038 -> 1,039, one native encoder
replacement, unchanged publishing generation and zero raw transition drops. Both the
native profile receipt and the matching 350 kbps bitrate-configuration receipt are
bound to that new encoder. Native compressed-output gap was 422.551 ms; this is not
a claim of uninterrupted wall-clock delivery.

Saved live media contains 3,262 consecutive frames (192 through 3,453), after 35
initial acquisition frames. The independent clean 1080p archive contains 3,670
consecutive frames (0 through 3,669). Both full decodes are clean. All 54 live and
61 archive audio markers match, with maximum A/V offsets 65.583 ms and 20.833 us,
respectively. Owned worker, encoder and recorder exits are zero. All 733 settled
native cadence reports over 97.197 seconds meet the 250 ms helper budget; maximum
usable-report gap is 153.388 ms.

Verification: 1,272 tooling, 348 Core and 252 native model tests pass; ARM64 simulator
and unsigned combined iPhone/Watch Release builds pass. The runtime matches 766
recorded source hashes. Only the post-capture checker and its test changed after
Apple builds, and the full tooling suite was rerun before capturing actual media.
Previous fixed-minimum stall and scheduled 240p/540p/240p artifacts replay with exactly
unchanged qualifications.

Review found two evidence gaps: a new encoder completion could precede application
admission, and a bitrate receipt could claim a future source frame outside observed
media. Both have red/green regression tests and independent reconstruction checks.
The reviewer confirmed both reproductions now reject. The independent Python checker
also validates receipt ownership, scoped raw-report timing, complete phase/frame
ranges, first minimum-frame delivery, clean decodes, and six damaged actual proofs.
Source, runtime, process exits and evidence hashes are frozen in
`artifacts/qa/stall-reset-final-verification.json`.

## Next gates

Complete short expected-source/deadline reconciliation so buffered bursts cannot
count as healthy on-time delivery. Then qualify actual candidate cost/headroom and
bounded upward trials, recovery holds, minimum reconnect and longer real automatic
runs. Physical iPhone/Watch routes and remote CPU/GPU/cloud systems still require
separate qualification. This test deliberately starts high; production minimum
startup and production automatic-adaptation/reporting defaults remain unchanged.
