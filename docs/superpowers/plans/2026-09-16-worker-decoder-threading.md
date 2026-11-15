# Measure worker decoder buffering

Continue the authorized autonomous portable streaming/Watch plan from c2c1821.
The preceding turn changed authoritative diagnostics and confirmed decoder damage;
all native jobs and analysis are terminal/joined. Production adaptation stays off.

Design: add an explicit `DECODER_THREADING=automatic|slice` worker setting, default
automatic. Only slice mode adds `-thread_type:v:0 slice` before the input. Leave
output threading, encoder settings, capture/archive, transport and media/freshness
gates unchanged. FFmpeg documents that frame threading buffers additional frames:
https://ffmpeg.org/ffmpeg-codecs.html#Codec-Options . Slice threading may reduce
parallelism for single-slice inputs, so throughput and frame identity must be
measured, not assumed. Forcing a fixed thread count is less portable; changing
transport latency first would consume the currently narrow freshness headroom.

The owned fixtures accept a validated `SCOREBUG_TEST_DECODER_THREADING` option and
record the chosen mode. Native fixtures pass an explicit worker environment value
so ambient worker settings cannot silently alter a baseline. The healthy processing
fixture uses the same mode for independent frame/PTS and encoder timing checks.

- [x] Red configuration, pipeline argv and fixture-validation tests; implement mode
      propagation through the real worker and both owned qualification fixtures.
- [x] Worker tests/build and tooling tests; review the bounded change.
- [x] Healthy real-media slice decode/output verification with VideoToolbox and
      software encoders, including dimension/aspect transitions and source PTS.
- [x] Repeat unchanged 240-second native rate4m fixture with only decoder mode set
      to slice. Compare actual receiver evidence age, diagnostics and delivered
      media with c2c1821; archive and every failed media gate remain independent.
- [x] Join owners, verify cleanup, hash terminal evidence, document results and
      decide whether the measured headroom supports a separate transport experiment.

## Validation completed before the pressure result

The causal red tests failed on the absent configuration default/input argument and
missing fixture parser. The implemented mode passes 343 worker tests, the worker
TypeScript build, and 981 tooling tests. Read-only review found no blockers.

Both healthy real-media runs pass with slice decoding:
`worker-processing-svTbeH` (VideoToolbox) and `worker-processing-PEV2fu` (software).
Each starts with 180 decoded 60-fps source frames and preserves all 90 expected
30-fps output identities and their source PTS through resolution/aspect changes;
89 matched intervals provide actual filter/total processing timing. These short
fixtures establish correctness in their workload, not long-run host capacity.

## Native pressure result

`native-app-a0fhIU` uses the same 240-second rate4m schedule, structured motion,
adaptive profiles, direct local RTMP recorder and iOS 17.5/iPhone 14 simulator as
the preceding checkpoint. The only media-setting change is slice input decoding.
The native UI workflow passes; the full runner fails its existing live A/V coverage
gate. Independent retained-artifact analysis preserves that failure.

- Archive: all 8153 consecutive 1080p/30 frames over 271.767 seconds, all 135 audio
  markers, 18.7 ms end-coverage difference, zero rejected/dropped queue samples.
- Native publisher: 7799 consecutive frames across five profile phases. All four
  profile applications bind to actual native receipts and meet their admission and
  completion deadlines (443–465 ms completion). All 96 quarter-second local
  pressure evaluations replay from retained raw evidence.
- Receiver evidence: 41 accepted source windows, median age 1.324 seconds
  (range 1.238–1.476), compared with 1.824 median in the preceding automatic-mode
  run. This observed ~0.50-second reduction is useful headroom, not a universal
  bound or a controlled repeated-run estimate. All 1000 retained native delay
  gauges still read 120 ms; actual collection median is 255 ms.
- Live: 7687 decoded pictures across 7739 source positions, a 52-picture count
  deficit. Independent barcodes identify 57 missing source positions, five repeated
  observations, three non-increasing identities and 12 identity/cadence anomalies.
  Worst five-second receiver cadence is 20.2 fps, below the required 24-fps floor.
  End coverage differs by −169.8 ms against the unchanged 100 ms limit; total
  positive audio-PTS gaps are 192.3 ms (largest 63.9 ms).
- Worker decoder counters report no decode-error/concealment messages in this run,
  but ingest reports two invalid PES events and one reader timing recovery. Missing
  media and failed barcodes mean zero decoder messages cannot establish intact
  delivery. Terminal input I/O errors and exit code zero occur with source shutdown;
  they do not establish spontaneous worker failure.

The change is an explicit installation option; automatic remains the default.
Production adaptation remains disabled. The measured headroom supports a separate
bounded **publish-leg** SRT recovery-delay experiment next: preserve the read-leg
setting and all media/freshness limits, record the actual negotiated value, then
measure whether fewer discarded packets outweigh the added delay. Do not treat
nominal configuration or clean decoder logs as delivery proof. Longer host/camera
soaks, physical iPhone/Watch networking and other GPU/cloud hosts remain open.

Evidence: `artifacts/qa/decoder-threading-*`, both healthy media artifact trees,
and `native-app-a0fhIU/decoder-threading-{native-analysis,residuals}.json`.
Runtime files match the pre-run source snapshot. The final verification manifest
records source/evidence hashes and exact owned simulator/container cleanup after
all workloads and analysis processes joined.
