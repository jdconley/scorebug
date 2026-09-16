# Preserve recording and diagnostics when live qualification fails

The scheduled 4 Mbps test at `ab955b6` aborts on its end-of-hold live-state assertion
before stopping/exporting the healthy local recording. Its recovered committed
prefix is valuable but is not proof of normal archive finalization. The worker
collector also saves its bounded status maps only from collect(), which a failing
Xcode workflow never reaches.

## Changes

Share a bounded status-evidence writer between normal collection and fixture stop.
Join the collector first. Independently attempt publishing, worker publication
(when enabled), processing and decoded-window files, so one write failure does
not hide the other maps. Retain the existing per-map cardinality bounds, add a
four-MiB per-file serialization cap, and write only maps already populated by the
scoped/redacted collectors. Record whether the collector failed without persisting
arbitrary error text. Aggregate write errors and continue owned resource cleanup.
Normal qualification must still throw its collector error and use unchanged gates.

In the native UI test, capture end-of-hold publishing/worker checks without raising
an assertion immediately. Stop streaming if its control is available, record the
idle check, then retain the existing three-second local continuation, stop recording
and export. Attach bounded status/finalization evidence and only then assert all
live checks. Successful streaming still requires every original check. This fixes
the known end-of-hold failure path; it does not claim to finalize an app crash or
an earlier recording/setup failure.

## Verification

Red/green writer tests exercise populated/empty histories, write failure isolation,
count/byte bounds and lack of accidental mutation. Run full tooling tests, build
the UI target, a healthy native streaming baseline, and the same scheduled 4 Mbps
pressure diagnostic. A failed live run remains a failure, but must retain all
status files and a normally completed/exported archive. Decode and independently
check complete local video/A/V/diagnostics from that failure artifact. Keep original
failed attempts. No production or Watch behavior changes.

Physical readiness recheck: the paired iPhone 16 Pro and Ultra 2 are available and
two valid Apple development identities are installed. This is not yet provisioning,
deployment or hardware qualification; verify exact team/profile compatibility next.

The detailed phone recheck reports iOS 26.7, pairing and Developer Mode enabled,
but Xcode 26.2 cannot mount its developer disk image. Signing identities alone do
not make this hardware test ready. No device install or Xcode license change was
attempted; local implementation/qualification continues.

## Healthy verification

`native-app-cJhCRD` passes the unchanged pass-through quality-confirmation gates
with the revised finalization ordering. It preserves 3608 local frames (0–3607)
and 3208 acquired live frames (218–3425), both at 30 fps. Native scoring, A/V,
source/processing/publication and export checks pass. The archive terminates
finished with complete persistence and no first failure. One 6.6 Mbps trial is
confirmed; the following 7.26 Mbps trial is unconfirmed at stop. All five bounded
status files survive normal collection/cleanup, including collector status.
All 901 tooling tests pass; the UI target build and actual native UI test pass.

## Failed-live finalization verification

`native-app-MUFZJY` repeats the scheduled 4 Mbps pressure test with a 180-second
hold. Live qualification still fails (`local: failed`, `worker: stale`), and the
schedule verifier still reports missing recovery traffic coverage. The test now
reports that failure only after normally stopping and exporting the recording.
This is not a live recovery fix.

The independent full export analysis passes: 8020 consecutive video frames
(0–8019), exactly 30 fps and 267.333 seconds, 1920×1080 video, mono 48 kHz audio,
complete decode, source lead-in/cadence, configured hold coverage, barcode continuity
and A/V sync. The audio end differs by 14.7 ms. Every accepted audio/video sample
is written; queue rejection/drop and remaining items/bytes are zero. The recording
has a completion timestamp, finished archive state, complete persistence and no
first failure. This replaces the earlier committed-prefix-only evidence for this
known test failure path; it does not establish crash recovery or physical capture.

The joined collector saves one publishing attempt, four worker publication records,
eleven processing windows and twelve decoded windows, with no collector failure.
The UI finalization attachment independently confirms recording stop/export while
retaining false live checks. The live failure remains the command's nonzero result.
Evidence is retained under `artifacts/qa/native-app-MUFZJY`, including
`finalized-failure-analysis.json`; its independent verifier is
`artifacts/qa/verify-finalized-native-failure.mjs`.

Next: distinguish and correct actual encoder output behavior before claiming
bandwidth adaptation/recovery. Physical phone qualification also requires an Xcode
installation whose developer disk image supports the attached phone's iOS 26.7.
Watch networking, physical capture and remote-worker gates remain open.
