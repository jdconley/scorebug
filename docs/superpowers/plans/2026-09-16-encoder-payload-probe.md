# Controlled native encoder payload diagnosis

The scheduled 4 Mbps run at `ab955b6` fails live recovery despite six accepted
bitrate reductions. Transport bytes alone do not identify encoder output. The next
gate measures actual compressed sample sizes before the muxer, socket and network.

## Experiment

Add a dedicated iOS simulator unit-test target using the maintained HaishinKit
VideoCodec through its testable module. Reuse the existing DEBUG
FixtureCameraSource video generator and FixtureMotionPattern, including structured
blocks, barcode, NV12 layout and color settings. Expose only the existing generator
inside its DEBUG module; production behavior and encoder properties stay unchanged.

Run at 1920x1080/30 using the same H.264 High, average-rate, two-second keyframe,
no-reordering settings as SRTPublisher. Pace real time and consume the bounded
encoder output concurrently. A dynamic session uses 20 seconds at 6 Mbps, 20 at
1.5 Mbps, then 20 at 6 Mbps. A separate fresh session starts at 1.5 Mbps for 20
seconds. A bootstrap frame creates each session; subsequent changes use the
existing verified write/readback path.

Reuse the exact 600-frame pixel sequence for each phase while preserving advancing
source PTS. Join actual compressed CMSampleBuffer byte counts to the existing
immutable configuration/completion observer by exact rational source PTS. Retain
only bounded scalar rows (at most 2402 frames total), never compressed media or
pixel buffers in the report. Capture accepted write boundaries, configuration and
encoder-session UUIDs, source frame identity, native submission/completion times,
and sample byte count. Join output consumption and completion before export.

Write the scalar report as an XCTest attachment. An owned runner creates one
iPhone14/iOS17.5 simulator, runs only this target, exports the attachment and deletes
only that simulator. It retains failures and command logs. No phone, Watch,
network publication or remote worker is involved.

## Independent interpretation

A JavaScript verifier checks all source frame identities, receipt/configuration
ownership, no omissions/duplicates, valid positive sample sizes and bounded times.
Calculate actual H.264 payload from complete five-second source windows, excluding
the first five seconds of each phase as an explicitly labeled settling region.
Report all windows and comparison ratios, including fresh-low versus dynamic-low.
Preserve both source-time rate and completion lag; do not equate settings readback
with achieved throughput or network capacity.

This is diagnostic: verify evidence integrity without presupposing that 1.5 Mbps is
achievable for the fixture. The measurement must distinguish a persistent dynamic
update problem from a content-dependent rate floor or a downstream bottleneck.
A failure to reduce rate is retained, not corrected by weakening the workload.
If platform behavior differs, qualify the simulator path first; Mac-only evidence
cannot establish the failing simulator's encoder behavior.

## Verification and next work

Use red/green tests for the pure report verifier, bounded design/source review,
full tooling tests, native probe, unchanged-film regression and unsigned Release.
Keep physical-device, production adaptive activation, resolution transitions,
network recovery, longer soaks and remote proxy qualification open.

Separately preserve bounded worker status maps during fixture failure cleanup and
finish/export local recording before reporting live-state failures where feasible.
Those changes must retain explicit live failure and cannot manufacture a pass.

## Frozen probe interpretation

Fresh-low settings are applied before bootstrap, and native AverageBitRate is read
after bootstrap to confirm the starting setting. Bootstrap creation is excluded
from the paced interval. Verified phase writes must fall between the last old
submission and first new submission. Metadata/output joins allow callback arrival
order to differ but reject missing, duplicated, foreign or invalid frames.

Pacing gates: each post-bootstrap submission is no more than 250 ms late (with
5 ms clock-anchor tolerance), adjacent paced submissions are at least 1/120 second
apart, 95% of gaps are at most 50 ms, and whole-run submission cadence is 29–31 fps.
These gates prevent large catch-up bursts from masquerading as a real-time input.
Completion lag is measured separately and is not hidden by source-PTS rate.

Both dynamic-low and fresh-low staying high would rule out a solely dynamic-update
problem. It would not by itself prove a content-dependent floor: shared rate-control
behavior would still be possible. There is no assumption of an instantaneous or
strict payload cap from an average bitrate property.

## Runner ownership and retained first attempt

The runner uses a bounded POSIX process group for each command. Timeout,
cancellation and output overflow kill that owned group, and completion waits for
stdio closure. Cleanup commands remain available after cancellation. Simulator
creation is shielded until the owned ID is captured; failed creation reconciles
only the exact unique device name. Portable tests cover TERM-resistant descendants,
abort, bounded output, command failures and creation committed before client failure.

The first actual run, `artifacts/qa/encoder-payload-sCT76P`, captured all 2402 frames
and passed XCTest, but correctly failed the independent pacing check. Two dynamic
session gaps were 7.71 and 7.86 ms, below the frozen 8.33 ms minimum. It is retained
as failed diagnostic evidence, not qualified throughput. That run used the earlier
runner before simulator creation reconciliation; no cancellation occurred and the
owned simulator was deleted.

The probe now prepares the next pixel buffer before its absolute 30 fps deadline,
then waits until at least 1/60 second after the previous append finished. This
prevents catch-up bursts after scheduling or generation delays. All frozen
qualification gates remain unchanged. Phase writes still occur after the wait and
before the first submission carrying that configuration.

## Qualified isolated result

`artifacts/qa/encoder-payload-xoAsU0` passes XCTest and the unchanged independent
verifier on the owned iPhone 14/iOS 17.5 simulator. All 2402 compressed samples join
their source PTS and configuration receipts exactly. Both runs sustain 30.000 fps;
maximum paced submission lateness is 123.1 ms dynamic and 2.3 ms fresh-low. The
maximum completion lag over each complete run, including bootstrap, is 560.9 and
455.3 ms respectively. Each phase excludes its first five seconds, then measures
three complete five-second source windows:

| Encoder phase                     | Requested Mbps | Actual H.264 Mbps |
| --------------------------------- | -------------: | ----------------: |
| Dynamic: initial high             |            6.0 |             6.020 |
| Dynamic: low                      |            1.5 |             5.576 |
| Dynamic: restored high            |            6.0 |             5.576 |
| Fresh encoder: low from bootstrap |            1.5 |             5.576 |

All three low-window byte totals exactly match the fresh-low and restored-high
totals for the repeated pixel sequence. Fresh-low payload is 3.717 times its
requested rate. Native readback and accepted receipts are correct, but achieved
payload does not track the requested rate under this workload. This rules out a
solely dynamic-update explanation and locates insufficient reduction before the
muxer and transport. It does not distinguish a content-dependent floor from shared
native encoder/rate-control behavior, or establish behavior on a physical phone.
Nor does this isolated probe prove that all network-run stalls have one cause.

Keep adaptive production activation and bandwidth recovery qualification open.
The next diagnostic should record the selected native encoder and relevant supported
rate-control properties, then compare bounded fresh configurations with the same
pixels and pacing. Any proposed rate-control or resolution change needs its own
measured-output proof before repeating the scheduled network test. Independently,
retain bounded worker status maps on fixture failure and finalize the local archive
before reporting a live failure, so future pressure failures remain reviewable.

Verification: all 892 tooling tests and 180 FilmModel tests pass. The new simulator
target builds and its qualified native run passes. The unsigned combined iPhone
and embedded Watch Release build passes; targeted formatting and diff checks pass.
Neither production encoder behavior nor adaptive activation changed in this
checkpoint. Scalar reports, logs, retained failed attempts and exact source/evidence
hashes are recorded in `artifacts/qa/encoder-payload-final-verification.json`.
