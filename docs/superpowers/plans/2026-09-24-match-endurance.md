# Thirty-minute native recording and CPU-stream endurance

## Declared contract

Extend the passing two-minute local CPU route to **1,800 seconds / 54,000 frames**
per case. Run 1080p first; only after complete media, audio, image and cleanup
acceptance may the 4K case run. Stop on the first failure and preserve evidence.
No production limits, queue capacities, bitrate recipes or sender shutdown behavior
change. The native source is file-driven, not a phone camera. Both cases use the
direct loopback SRT listener, production CPU proxy/overlay, RTMP independent recorder
and a concurrent clean native segmented archive. The publication relay and automatic
adaptation are outside this contract.

Read-only thumbnail inspection selected original 1080p seconds **1200–3000** and
4K seconds **0–1800**. The 1080p samples show match play, a rally and natural pauses;
the 4K samples include initial team activity and later match play. Store new private
derived sources in `artifacts/qa/match-footage-n6n1f13m/endurance/`. Originals remain
untouched and local. Normalize to H.264 SDR BT.709 30 fps / mono PCM 48 kHz, tone-map
4K HLG, and add the existing 16-bit identity strip to derived video only. Independently
decode all source IDs and confirm 86,400,000 source audio samples before replay.
The 54,000-frame range stays below the unambiguous 65,536-ID limit.

Acceptance preserves the two-minute thresholds:

- Normal joined sender/proxy/recorder exits and released owned ports. No grace delay
  before native publisher stop. Harness sender/proxy deadline **1,920 seconds**.
- Native archive and submitted-live counts exactly 54,000 video / 86,400,000 audio
  samples; zero archive rejection and live queue loss/rejection. Every proxy decoded
  source event accounted for. Full A/V decode of both output MP4s.
- Every archive/live ID 0–53,999 exactly once, with strictly increasing decoded
  video times, gaps at most 35 ms and duration within 35 ms of 1,800 seconds.
- Every audio timestamp/sample count checked against previous and cumulative sample
  timelines (2 ms rounding allowance), with 100 ms startup/tail coverage allowance.
- Compare source audio at **10, 300, 600, 900, 1200, 1500 and 1790 seconds**, one second
  each. Exhaustive fractional correlation uses the tested estimator: ≥0.98, interior
  and unambiguous peak, absolute A/V lag ≤100 ms and across-window spread ≤20 ms.
  Use actual matched video PTS and each output audio origin. Decoded PCM duration
  difference must be ≤100 ms. This remains sampled content evidence.
- Inspect matching source/archive/live frames at 900 and 1200 seconds for the clean
  archive, expected score overlay and representative scene. Keep all visual evidence.
- Retain source/executable/runner hashes, commands, failed outcomes and cleanup.

Only offline harness budgets scale with this predeclared duration: fixture preparation
and each full decode/probe/export at most 1,800 seconds; the replay runner's ffprobe
JSON and decoded 8 kHz PCM child-output buffers at most 64 MiB. This is not a total process-memory cap:
the audio checker converts PCM to Float64 and retains a reference plus target
(about 230 MB together), in addition to subprocess buffers and metadata. Native/proxy combined stdout/stderr/metadata remains capped
at 32 MiB per process; the replay runner's FFmpeg decode/barcode error output is capped
at 4 MiB. Preparation instead streams its encode log to disk, collects barcode/probe
stderr without a byte cap, and checks the written probe JSON size after process exit;
those are not runtime output-memory bounds. The prior two-minute 4K archive probe
is 2.35 MB, so the 15× duration fits 64 MiB. PCM is 57.6 MB per stream at 8 kHz float32.
Capture progress and diagnostic histories remain bounded exactly as before: native
512 encoder/submission rows and 4,096 transport rows are incomplete prefixes, with
explicit overflow/omission fields. No whole-run encoder attribution is inferred.

Report source scheduling lag and elapsed capture time separately; recorded PTS and
complete content do not prove viewer wall-clock deadlines. One successful local
30-minute run is endurance evidence for that route, not universal full-match,
physical-device thermal, camera, HDR60, GPU/cloud or automatic-upgrade qualification.

## Execution

- [x] Exercise the reusable verifier across the high 16-bit IDs and long timeline.
- [x] Prepare and independently validate the 1080p source with versioned scripts;
      inspect the runner changes and freeze sources before the first network case.
- [x] Run and assess the complete 1080p case. Preserve failure if any.
- [ ] If the first case passes, prepare/validate and run the 4K case serially.
- [ ] Review exact evidence and update the main plan; retain all outstanding gates.

## 1080p result

Frozen `f4e3117`, `artifacts/qa/match-footage-n6n1f13m/endurance/1080p-cpu`,
passes the complete declared case. The wrapper exits zero and is joined; sender,
proxy and recorder exit zero naturally. Both owned ports are bindable, sender/proxy
PIDs are gone, and all **1,191** source/input/runner/executable hashes match.

Both outputs fully decode and retain **54,000 frames, IDs 0–53,999**, with maximum
video gaps of 33.334 ms (archive) and 34 ms (live). Every audio frame passes continuity
and cumulative-timeline checks. Native archive and publisher counts are exactly
54,000 video / 86,400,000 audio samples, with zero archive rejection and live queue
loss/rejection. Maximum source scheduling lag is 12.158 ms; sender elapsed time is
1,801.378 seconds. These are not viewer latency measurements.

All seven audio windows pass. Minimum archive/live correlation is
**0.999206 / 0.998351**. Archive A/V lag is zero; live lag is **65.219 ms**, with no
sampled drift beyond numerical rounding. Decoded PCM padding is 20 ms / 34.125 ms.
The 512 encoder/submission and 4,096 transport rows explicitly overflow: they are
diagnostic prefixes, not whole-run encoder/transport attribution.

Matched source/archive/live PNGs at frames 27,000 and 36,000 were inspected; each
extracted PNG's barcode independently confirms its selected identity. The first
scene shows serve preparation and the second an active rally. The archive is clean
and the live score overlay is readable. Live images are visibly softer/blockier
after the scheduled reduction to 2 Mbps; this is continuity qualification, not
maximum sustainable quality or whole-video perceptual qualification.

The high-ID/long-timeline verifier has 20 passing tests and the complete tooling
suite has 3,483 passes. Detailed media, audio, hash/cleanup and visual results are
retained in `result.json`, `post-run-assessment.json`, `preview-extraction.json`,
`visual-assessment.json` and the final `acceptance.json`. The 4K case remains pending.
