# Classify decoder damage before changing recovery

Continue the autonomous portable streaming/Watch goal after daa255f. The previous
turn made progress: shorter pressure response reaches a worst receiver window of
25 fps, but source identity remains damaged near downward geometry changes.

Investigation: publisher logs report invalid PES twice. Its decode-error callback
only logs; it does not signal the downstream H.264 timing helper. That helper
checks timing headers, not complete picture/reference integrity. Worker terminal
counts report zero decode errors but seven unmatched warning lines. Those zero
counts do not prove correct decoded pictures. FFmpeg's source reports missing
reference pictures/MMCO failures separately, and concealment at INFO level.
Sources: https://ffmpeg.org/doxygen/8.0/h264__refs_8c_source.html and
https://ffmpeg.org/doxygen/8.0/error__resilience_8c_source.html .

Add fixed missing-reference, invalid-slice and concealment counters to the bounded
line parser. Preserve optional counters in the independent native evidence reader;
legacy absence stays absent, malformed values fail, arbitrary text never escapes.
Only opt-in terminal diagnostics raise FFmpeg logging to repeat+level+info, allowing
concealment messages without duplicate-log compression. Keep default warning level,
4 KiB line bounds, fixed storage, pipe ownership and media behavior unchanged.
Counts describe diagnostic lines, not damaged frames or proof of packet causality.

- [x] Red tests for exact categories, split lines, noise/credentials, optional legacy
      evidence, malformed counters and opt-in log-level selection.
- [x] Implement and run worker tests/build, tooling tests and read-only review.
- [x] Repeat unchanged native 240-second rate4m fixture with the existing policy.
      Analyze archive, live identities, real diagnostics and transport pressure;
      preserve failed media gates, verify cleanup and hash terminal evidence.
- [x] Choose the next recovery experiment from the observed categories, not from
      absent log counts. Production adaptation and device/host/soak work stay open.

## Verified checkpoint

The parser/log-level/evidence regressions fail before implementation and pass
after it. All 341 worker tests, worker TypeScript build, 980 tooling tests and
read-only review pass. This checkpoint changes diagnostics only; it does not
change transport settings, encoding, recovery policy or media qualification.

Run `native-app-OY8jUj` repeats the unchanged 240-second rate4m native fixture.
Its UI workflow passes. The worker now reports 175 decode-error lines and 30
concealment lines, zero classified missing-reference/invalid-slice lines, 163
unmatched INFO/warning lines and no oversized/incomplete diagnostic lines. These
are message counts, not affected-frame counts. Its timestamp telemetry still
counts all 7647 accepted frames as fresh with no timestamp duplicates/reordering.
This directly demonstrates that timestamp uniqueness alone does not prove visual
frame integrity; the independent barcode/media gate remains necessary.

The live file contains 7647 pictures spanning 7710 source positions: 63-frame count
deficit (0.817%), 7612 unique identities, 98 absent positions, 35 repeated
observations and 32 non-increasing adjacent barcodes. Its 39 identity/cadence
anomalies again cluster around downward changes (first source 1970 and 3537).
The worst five-second receiver window is 18.2 fps, contradicting any claim that
the preceding single run's 25-fps minimum established sustained reliability.
Full live qualification fails on duplicate/regressed markers. Live A/V end
coverage passes; audio PTS gaps total 64.72 ms, maximum 21.81 ms.

The clean archive independently preserves all 8123 consecutive 1080p/30 frames
for 270.767 seconds and all 135 A/V markers, with a 16 ms end difference and no
rejected/dropped archive samples. Native publishing has 7770 consecutive frames
across five phases. All 94 local windows independently replay, and all four actual
profile applications bind to their bounded admissions and native receipts.
The first decrease completes at +60.179 seconds; trial +111.351 rolls back at
+112.413 and a later trial starts at +206.548. Receiver window age remains
1.732–1.970 seconds (median 1.824). All 998 retained native delay samples are 120 ms.
A separate filtered live relay API snapshot also observes 120 ms on both sender
and receiver delay gauges for both SRT connections; the worker leg does not have
an assumed one-second negotiated buffer.

The ingest retains one invalid-PES decoding report. Worker terminal code 255 is
recorded under the fixture's SIGTERM shutdown; it does not erase decoder damage
or establish a separate spontaneous process failure. Runner exit 1 is the failed
media gate; independent analysis exits 0. All owners are terminal/joined, collector
stopped, and owned container/simulator absent. Runtime source matches its pre-run
snapshot, and stopped quality evidence matches the final copy. Terminal hashes:
`artifacts/qa/decoder-damage-final-verification.json`.

## Next experiment: separate decoder buffering from transport recovery time

The damaged pictures reach the worker decoder, before overlay/output encoding.
Do not infer that remuxed PTS or successful downstream re-encoding repaired them.
The existing H.264 timing helper checks headers; it cannot validate all reference
picture data. Raising transport delay blindly remains inappropriate because
actual accepted receiver evidence is already near the unchanged two-second cap.

The worker currently leaves FFmpeg decoder threading at its default. FFmpeg's
[codec documentation](https://ffmpeg.org/ffmpeg-codecs.html#Codec-Options) explains
that frame threading adds decoding delay, whereas slice threading operates within
a picture. Native publishing explicitly disables frame reordering. Measure an
opt-in input decoder slice-threading configuration against the current default,
with identical source media, complete PTS/identity checks and processing-throughput
checks. Keep output encoder settings unchanged. If measured receiver evidence age
falls without damaged media or throughput loss, use that measured headroom to
design a separate bounded transport-recovery-delay experiment. Do not extend the
freshness cap, shorten upward probation or relax barcode/cadence/loss gates.
Physical devices, paired Watch networking, long camera/storage/thermal soaks,
other GPU/cloud hosts and production adaptation remain incomplete.
