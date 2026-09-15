# Structured native motion calibration

Use brainstorming and writing-plans, then bounded subagent implementation with
independent specification and quality reviews. Use TDD and verification before
claims. Parent owns isolated native/media execution; do not overlap qualification
with builds/tests/media work.

## Evidence and objective

The original pixel-noise motion fixture is efficient enough to preserve all
1,190 local archive frames at 30 fps in `native-app-KIC4hs`, but the archive averages
55.369 Mbps against 12 Mbps requested. Its live output averages 47.144 Mbps against 6 Mbps,
has corrupted frame identities and fails A/V tail coverage. The first run also
restarted its worker. These overload failures remain open; the pixel-noise mode
and artifacts must remain reproducible. Do not classify the live path as reliable
or enable adaptation based on a lower-demand fixture passing.

Offline replays of the intact archive alter only its middle region, preserve the
identity and score backgrounds, and re-encode through local VideoToolbox. Each
case has 300 packets in two complete five-second windows. They establish a candidate
workload, not native or transport qualification:

| Spatial treatment | Cell | Requested 6 Mbps | Requested 12 Mbps |
| --- | --- | --- | --- |
| Area average, then nearest expansion | 8 | 6.071880 | 12.108207 |
| Area average, then nearest expansion | 16 | 5.825442 | 8.565807 |
| Point sample, then nearest expansion | 8 | 12.521762 | 12.655786 |
| Point sample, then nearest expansion | 16 | 6.260794 | 12.062671 |

All values are measured video payload Mbps, excluding audio/container/transport
bytes. Artifacts: `native-app-KIC4hs/structured-replay-95GnNt` and
`structured-point-twTnPb`, with commands, logs, packet metadata, rates and scripts
that always write fresh sibling directories. Offline input is already encoded;
its sampling grid only approximates exact 16 pixel cells. The native candidate
requires its own measurement. Choose point-sampled 16 pixel cells: it retains broad
color/contrast variation while staying near both requested rates in this experiment.

## Explicit pattern selection

- [x] Preserve absent/empty native flag as the original barcode source. Preserve
  `SCOREBUG_TEST_MOTION_FIXTURE=1` as the existing pixel-noise mode, including exact
  texture bytes and seed. Add one explicit value, `blocks16`, for the new pattern.
  This intentionally extends the original single-value flag contract; no other
  nonempty spelling is accepted. Runner explicit empty remains invalid.
- [x] Record `fixtureWorkload: motion-blocks16` for the new value; keep `motion`
  and `barcode` labels unchanged for existing artifacts. Validate both enabled
  patterns before resources and require streaming plus the direct receiver.
  Pass the validated flag through Xcode/UITest/app without collapsing it to 1.
  Release and physical-camera source selection remain unchanged.

## Bounded source implementation

- [x] Add a typed pattern selection inside the DEBUG fixture implementation.
  Existing callers/tests default to pixel noise; the camera selects the explicit
  blocks16 pattern only after flag validation during prepare.
- [x] Generate the same eight seeded NV12 noise textures as before, then transform
  each texture in place during prepare for blocks16. Retain the 32 MiB checked
  ceiling and 24,883,200 byte 1080p total; do not allocate another image or generate
  pixels after the capture clock starts. A few scalar cell samples are sufficient.
- [x] Treat luma as 16×16 pixel cells within the existing central band, starting at
  that band's lower row. Use the center sample at start + floor(clipped length / 2) on each axis
  (the upper middle for even lengths) from each clipped cell,
  and repeat its value across that cell. For NV12 chroma, use 8 rows×8 UV-pair cells
  (same physical 16×16 pixels), sample U and V separately and repeat each pair.
  Clip at width/band boundaries and respect the existing protected chroma boundary
  pairs. No averaging, colorspace change or writes outside the allowed rows.
- [x] Preserve source PTS, audio, callback order, fresh output buffer ownership,
  destination strides, joined stop, raw queue capacities and encoder settings.
  Test small even dimensions with partial cells and odd band boundaries as well
  as 1080p; all barcode/scoring pixels remain unchanged.

## Tests and native calibration

- [x] Red/green tests: exact original-mode bytes remain unchanged; malformed flags
  fail; each luma/chroma cell is constant with independent UV; center sampling and
  clipped cells agree with original seeded noise; frames/seed vary; static regions
  and prior emitted buffers remain intact. Cover new runner/UITest flag mapping.
- [x] Run focused source, full Film, focused/full tools and combined iPhone/Watch
  Release build, then independent specification and quality reviews.
- [x] Run the same short native workflow with explicit `blocks16`. Keep every
  existing frame-identity/cadence, A/V marker/coverage, native scoring, clean
  archive, report-age and terminal-delivery gate unchanged. Record exact revision,
  workload, per-window payload and bounded diagnostic scope; preserve failures.
- [x] Review the measured native workload before freezing acceptance. Existing
  initial 6/3 Mbps archive/live demand targets are calibration observations only;
  also examine upper rates against 12/6 Mbps settings. Never infer a hard bitrate
  ceiling, wire throughput or visual quality from those settings.
- [ ] Only after calibration passes, freeze the workload contract and run 180 then
  600 second holds. Physical devices, real sports footage, thermal testing and
  network impairment remain separate gates. Original high-rate corruption and
  shutdown/delivery behavior remain an open overload diagnosis.

## Missing diagnostic boundary

Existing native completion hooks count frames before compressed-queue acceptance;
app publishing state does not establish remote pixel correctness or delivery.
SRT has send-loss/retransmission/drop/occupancy counters, while compressed queues
already latch failures, but these are not preserved together in attempt-scoped
native artifacts. If corruption recurs on blocks16, first add bounded scalar
encoder/mux/SRT counters and a separately bounded pre-SRT compressed/TS artifact
for independent decode. Design capture/retention overhead before enabling it;
never perform file I/O in capture callbacks or silently change transport policy.

Independent design review approves this separate calibration candidate.
Source and tooling are implemented; the first short native blocks16 calibration passes as recorded below.


## Tooling verification

The runner accepts the exact new `blocks16` spelling, records `motion-blocks16`
and forwards the validated spelling to the native test. Original labels and flag 1
behavior remain unchanged. The focused red run rejected the newly supported mode
as expected; green passes 37 tests and the full tooling suite passes 355, both with
normal exit 0. The runner syntax check and independent specification review pass.
Evidence: `artifacts/qa/structured-motion-options-{red,green,format}.log` and
`structured-motion-tools.log`. Native verification is recorded below.


## Native source verification

The new typed pattern transforms disjoint cells in place after each original noise
texture is generated, preserving seed progression and the original mode's bytes.
Eight frozen FNV-1a hashes pass on both the unchanged red baseline and final source.
Red completed normally with Xcode exit 65 and five expected tests rejecting the new
flag. Focused green passes 12 tests and full Film passes 85, both with normal exit 0.
Tests cover centered/clipped cells at 322×244 and 1080p, odd protected chroma
boundaries, source identity, audio, fresh buffer ownership, joined stop, capacity,
diagnostics and actual recording/export. The combined unsigned iPhone/Watch
Release build passes. Logs are under `artifacts/qa/structured-motion-source-{red,green}.log`,
`structured-motion-film-full.log` and `structured-motion-release.log`.
Combined specification and independent quality reviews approve with no findings.


## Short native calibration at a4a5c25: passed

`native-app-nX1LnQ` completed with runner exit 0 on iPhone 14/iOS 17.5. The explicit
workload is `motion-blocks16`. Archive: 1,315 consecutive frames 0–1314, 43.8333 seconds,
30 fps, 2,630 accepted/written samples, zero rejected/dropped samples. Live: 918
consecutive frames 214–1131, 30.6 source seconds,approximately 30 fps, zero acquired-frame
loss and complete final encoded frame 1131. Capture 153 precedes encoded 154; the 60
encoded frames 154–213 before receiver acquisition remain explicit. The archive
continues 183 frames beyond live output. Five steady observation windows each have
150 capture/150 encoded frames. Both report-age proofs match independent API evidence.

Archive video payload over eight complete five-second windows averages 12.115732 Mbps
(range 12.090522–12.123202 Mbps). Live over five complete windows averages 7.616506 Mbps
(range 7.592077–7.644997 Mbps), about 27% above its requested 6 Mbps. Archive/live maximum
marker offsets are 0.020833/65.250 ms; tail differences are +5.333/+25.664 ms. Native
scoring changed 693 overlay pixels. Full A/V decode, all archive identities, acquired
live identities and final delivery pass unchanged gates. Worker encoder exit 0 was
preceded by a recorded SIGTERM request; do not call it an unrequested natural exit.
The direct recorder exited 0 without a termination request. No worker evidence was
omitted. This is one short simulator run, not sustained/hardware qualification.

## Frozen workload band for longer holds

Independent design review approves this prospective, inclusive band for each
complete five-second video payload window: archive 6–18 Mbps, live 3–9 Mbps. Both
extremes must hold independently for every window; an aggregate cannot hide an
outlier. The lower bound preserves substantive encoded demand; the upper bound
keeps this particular calibration workload bounded near the selected profile.
These broad bands do not prove delivery at the requested bitrate, real-camera
visual quality, usable link capacity, or a hardware ceiling.

Apply the gate only to `motion-blocks16`. Reject unknown media kinds, malformed or
empty evidence, nonfinite/inconsistent rates, non-five-second or omitted internal
windows and oversized history. Keep the original pixel-noise/barcode modes and all
existing media checks unchanged. Persist band bounds, actual minima/maxima and
window counts alongside the full packet-derived rates. `qualifyStructuredMotionPayload`
in `scripts/video-payload-rate.mjs` is called immediately after measurement by the
native runner. Tests exercise inclusive edges, a single byte outside each bound,
and outlier windows hidden by valid aggregates. The pilot's saved rates pass a
separate `payload-band-audit.json`; its original `results.json` remains unchanged.
Long-run source/profile, seed, flags, media gates and bands are now fixed before
180-/600-second qualification. Any future change requires a new calibration.

Qualifier verification: corrected red has four expected missing-qualifier failures;
focused payload green passes 39. The initial full suite passes 360/361: the unrelated
stuck-readiness-probe test can consume its 15 ms budget during filesystem setup,
before the probe runs. Its original focused rerun passes, consistent with scheduling
sensitivity. The test now uses the existing injected clock to isolate probe timeout;
a separate deterministic case covers deadline expiry before probing and cleanup.
Production recorder behavior and deadlines are unchanged. Combined focused checks
pass 66; full tools pass 362 with normal exit 0. Syntax and diff checks pass.
Independent specification and quality reviews approve the qualifier. Logs:
`structured-motion-demand-red-corrected.log`, `structured-motion-demand-green.log`,
`structured-motion-demand-tools.log` (original failure),
`structured-motion-readiness-reproduce.log`, `structured-motion-demand-focused.log`
and `structured-motion-demand-tools-green.log`.

## First 180-second run: not qualified

At `a2e8141`, `native-app-qlQcKm` reaches recording completion but fails the native
45-second export-ready wait. Its preserved temporary export passes independent
frame, A/V and workload checks; the original workflow remains failed. The saved
live file also exposes a detector edge case at its cut final audio marker.
See the [export and terminal audio diagnosis](2026-09-15-structured-motion-edges.md)
for exact evidence, isolated native exporter replays and next actions. Neither
the three-minute nor the ten-minute blocks16 qualification is complete.
