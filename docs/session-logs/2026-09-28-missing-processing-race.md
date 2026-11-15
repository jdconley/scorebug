# Decoded-window / processing-report race — September 28

Starting4076db2. Previous turn made progress by isolating simulator4K encoding and
capturing the native sourceScopeChanged reset. No live jobs survived that turn.

## Concrete race

WorkerSourceIntervalTracker can return a decoded window before its matching
processing report arrives, then enrich that same sequence on a later status poll.
PublishingQualityDriver already waited for pending processing frames, but consumed
a window immediately when its report was absent. That unknown-pressure window
could revoke probation, and the later complete report was discarded as consumed.
The source scope includes optional processing identity, so report absence can also
produce sourceScopeChanged. We have not recovered the exact differing field from
the previous long run's compact witness; the independent focused reproduction
establishes the premature-consumption bug directly.

Fix: extend the existing processing wait to absent reports. The original capture
age bounds waiting; freshness, trial deadline, delivery, ownership and actual scope
changes remain unchanged. Unknown/malformed reported backends do not gain credit.

## Focused evidence

`artifacts/qa/missing-processing-20260928/`:

- before.log: new regression fails three assertions—missing report consumes the
  window, later matching report cannot be evaluated, no recovery credit follows.
- verified.log: five affected model tests pass (0.064seconds). Covers same-sequence
  completion, no credit while waiting, probation confirmation after report arrival,
  original capture deadline fallback, backend validation and actual identity changes.
- Initial trial regression used a future fake freshness clock against the driver's
  real clock. Corrected the fixture using its existing useActualInstant helper.
  Two first-pass selectors used the wrong XCTest class and selected no tests;
  verified.log uses PublishingMeasuredCandidateSessionTests and executes all five.

## Native checkpoint

`headless-native-s6jknJ` runs390seconds of the unchanged real4K fixture with native
archive/publishing, local SRT/overlay/proxy/mock outputs and production policy.
Optional detailed timing audit is off; all production checks remain. Producing
HEAD/patch hashes are retained. Joined successfully with no cleanup failures.
360/720/1080 confirm with no reset; native recording and publishing remain active.
4K candidates now complete encoding, but receiver authority is unavailable, so
4K does not apply. This is a diagnostic pass, not full media acceptance.

## UHD receiver accounting fix

The valid v4 sender can accept up to 64 MiB per campaign, but
WorkerReceiverProbeTracker still hardcoded 16 MiB for local accepted bytes. It
quarantines the valid high-rate observation before 4K admission. Snapshot validation
already had the correct v4 cap. Both checks now use one version-specific property;
legacy 16 MiB, v4 64 MiB, packet alignment, pending reservation and identity rules
remain intact.

Two regressions reproduce four failures on the old tracker (tracker-before.log).
They cover forming a receiver pair across 16 MiB and accepting/rejecting local
bytes at the respective v3/v4 caps. All 57 affected receiver tests pass in 0.098s
(tracker-after.log). No unrelated suite was rerun.

One 420-second native checkpoint, headless-native-gZctuL, checks both fixes together.
Its producing patch and HEAD hashes are retained before subsequent doc edits.
Joined0, cleanup[].360/720/1080confirm.4K trial applies at24Mbps and receiver
observes444actual3840×2160frames. At sample530, probation resets with
missingCapacity,trialRollback:148captured,146encoded/received,2lost; local transport,
thermal and worker are nominal. UHD receiver PTSsteps peak6000/90000; the earlier
lower profiles have exact3000steps. Thus the v4 accounting fix works; sustained4K
still fails with real observed gaps. The exact local drop cause is not proven.
Recording and publishing remain active through recovery360→720. Elapsed422s.
transition-summary.json and geometry-summary.json retain compact evidence.

The new opt-in testExportExistingDiagnosticArchive calls the real RecordingLibrary
against a completed retained recording. It passes in28.647s;212segment metadata/
size/SHA256 checks pass. No camera/network recapture. Began the existing all-file offline decoder, then
stopped it after the geometry already proved real loss: the first whole4K ffprobe
alone took over two minutes and further decoding could not grant a UHD pass.
Owned Python76367/ffprobe76410 were terminated, exec36697 joined143; raw media and
partial files preserved. offline-decode-status.json explicitly records incomplete,
unqualified output. Do not interpret native export success as decoded-media success.
Also print elapsed seconds and selected transition cause fields at profile changes
for future quick diagnostics. These test-only additions were made after this run
compiled; the capture's original producing patch is retained.

## Faster iteration and plan cleanup

Collapsed the delivery plan into requirements, current status, grouped completed
workflows and outstanding local/hardware tasks. Detailed experiment history and
commands stay here and in prior session logs. Preserved all open acceptance areas.
Reused the qualified 1080p and native scoring workflows; no blanket rerun.

Coverage inspection finds existing focused stale/no-progress/thermal/queue and
terminal-retention checks in QualityControllerTests, ProgressiveQualityTests,
NativeCandidateFixtureTests and PublishingQualityDriverTests. The continuous
consumer's retained 600-poll/300-owner tests establish independence from finite
audit storage (2026-09-25-continuous-delivery-control.md). This does not close the
remaining real media/fault matrix or optional complete-audit qualification.

## Checkpoint outcome

Two production bugs fixed; real UHD admission/receiver geometry now demonstrated,
with truthful probation fallback on observed loss. Five model/57receiver tests and
one native checkpoint pass their scopes; one retained native export passes. No
hardware, additional full simulator run or blanket suite. All owned processes joined.
The goal remains active. Next work uses retained evidence for the remaining fault
matrix and native4K performance, rather than another unchanged long capture.
