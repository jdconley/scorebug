# Progressive vertical and paired hardware continuation

Starting checkout: `codex/local-validation`, `722e741`, in
`/Users/jd/.codex/worktrees/scorebug-local-validation`.

The active goal remains the complete native vertical including progressive
streaming. The physical phone three-output checkpoint is already retained in
[the preceding session](2026-09-25-three-output-vertical.md); it does not qualify
paired Watch scoring or automatic quality increases.

## Device preparation

The user explained that the first automation attempt in a new session prompts
for the passcode on the phone. Announced this test session before dispatching
automation. No passcode is requested or retained in chat.

Fresh device inventory: `artifacts/qa/goal-resume-devices-20260925.json`.
The physical iPhone is connected and its Ultra 2 is available. LAN address remains
`192.168.1.130`. Both signed `build-for-testing` jobs finished with exit 0:
`paired-resume-phone-build-20260925` and
`paired-resume-watch-build-20260925` (standard QA wrapper logs/exit records).

Initial lab `device-lab-1aWr3l` failed because Docker was stopped (missing daemon
socket). Its shutdown report also records relay cleanup failure; no successful
relay allocation was observed. Opened Docker normally and confirmed server
version 29.2.1 before starting a fresh lab, `device-lab-mmTL6h`.

Paired tests use the reviewed physical test methods, real WatchConnectivity and
private per-lab credentials injected through environment variables. No fixture
credentials are supplied to the Watch. Both use `test-without-building` against
the signed products above and retain separate result bundles in the lab folder.

## Adaptive application work

The app currently lacks owned measurement registration, binding and cleanup;
the existing measurement context is advisory. Implement the bounded guarded
application-owner slice first: exact ownership, safe pre-effect rejection and
joined shutdown after a profile change followed by failed bitrate application.
Do not fabricate transferred measurement settlement or enable production
adaptation from this checkpoint alone. Continue the actual owned measurement
lifecycle and complete media qualification afterward.

## Results and remaining work

The first paired attempt (`device-lab-mmTL6h`) joined: Watch exit 0, phone exit
65. The Watch passed real setup, takeover, HOME point, undo, AWAY point and match
end. The server command ledger independently contains that sequence and the
ended 0–1 score. The phone waited for a status confirmation even though its
screen recording visibly showed “Watch reports connected.” XCTest selected the
Label's Image, which inherited the same identifier as its text. Changed both
physical and simulator paired-test locators to select StaticText; the status
message assertion and all subsequent media assertions remain intact. Independent
specification and quality reviews approve the correction.

Both retained live MP4s from that failed phone run fully decode H.264/AAC:
2,717 frames each, approximately 92 seconds, 1920×1080/~30 fps. Encoded timestamps
increase with no gap above 50 ms. First video starts 1.388 seconds after audio.
Decoded frames at 50 seconds (proxy) and 88 seconds (mock) visibly show the
Watch-driven 1–0 and 0–1 overlays. The camera image is black in these samples;
this run does not qualify representative visible camera motion. Keep the rear
camera uncovered and pointed at a lit scene on the next hardware run.
This is partial evidence only: no archive export or complete phone acceptance
was reached. Lab shutdown joined with worker exit 0, no forced termination and
no cleanup failures. Receiver metadata records `client-socket` on the terminated
connection; the retained MP4s were verified directly. No continuous-delivery or
fresh-frame identity claim follows from encoded cadence alone.

The corrected phone test rebuilt successfully and used fresh lab
`device-lab-SM9KM1`. It selected StaticText and passed its status assertion.
The paired run nevertheless failed: Watch exit 70 during destination preparation,
phone exit 65 waiting for the first Watch point. Xcode requested an unlocked,
nearby Watch to recover from preparation errors. Asked the owner to unlock it;
do not repeatedly launch tests without resolving device readiness. On the next
attempt, wait for the Watch runner to enter its offer wait before starting the
phone so device preparation cannot consume the phone's scoring deadline. The
corrected locator is committed as `3e9d4d2`. The second lab also stopped and
joined with worker exit 0 and no forced shutdown.

Guarded app application checkpoint `064e555` changes only
`PublishingQualitySession` and its tests. The opt-in route publishes exact private
application ownership and authoritative Core state before awaiting native calls,
preserves publication on guarded pre-effect rejection, and joins shutdown after
partial profile application or uncertain effects. Both reviews approve this
bounded checkpoint. Production opt-in remains false. Existing compatibility
`acknowledge(nil)` is deliberately not represented as owned measurement failure
settlement or retry backoff.

Verification artifacts `quality-partial-application-{red,green,regression,full,final-focused}-20260925.log`
retain three initial regression failures and final 54/54 focused pass. The full
596-test run has one failure in the existing
`testLateWorkerFailureAfterStopIsIgnoredAndRestartWaitsForControlCompletion`;
that case passes isolated. Inspection found a possible stop/control-poll race,
so a separate deterministic regression and fix are underway. Do not describe
that original run as passing or discard its failure.

## Stop/restart repair and final checkpoint

`265aa0a` resolves the retained-stop defect: stop could fail offline or yield to
an existing control poll, leaving `shouldStopOwnedBroadcast` set. Replacement
startup then reused the server selection and cleared that intent without a
stop command. Startup now recovers with no active recording and uses the same
scoped stop reconciliation as maintenance before reserving replacement ownership.
It preserves pending-command expiry, exact selection checks, durable ownership
and recording independence. Both independent reviews approve the two-file fix.

`stop-control-race-red-20260925.log` reproduces the missing stop deterministically
with offline stop followed by online restart. Focused capture/control tests pass
112/112. The final `stop-control-race-full-20260925.log` passes **598/598**, including
the final teardown guard; the process joined exit 0. The earlier intermittent
test is unchanged. Added tests also ensure deferred stop cannot target another
device or a newer unowned recording selection.

The signed iPhone `build-for-testing` passes with joined exit 0 at
`repeated-live-checkpoint-stop-control-race-phone-build-20260925{.log,-exit.json}`.
This build does not establish installation or a hardware pass for the new stop
fix. Both test labs and all owned test processes are stopped; Docker has no
remaining `scorebug-device` containers. Source videos and prior recordings remain
untouched.

Next: resume paired hardware only after Watch readiness is resolved, announce
the passcode prompt and keep the camera viewing a lit scene. Start the Watch
runner first, then the phone after it reaches its offer wait. Install the latest
signed phone binary only while capture is known idle. Continue owned measurement
registration, native operation cleanup and transferred application settlement,
then the four-phase full-media recovery experiment and production integration.
The overall end-to-end progressive-streaming goal remains active.
