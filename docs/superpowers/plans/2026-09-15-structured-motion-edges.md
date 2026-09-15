# Structured-motion export and terminal audio diagnosis

Use systematic debugging and bounded subagent implementation with independent
specification/quality review. Parent owns isolated native/media execution.

## Ten-minute run: export deadline failure

`native-app-dUHHoC` at `d85ac44`, with direct RTMP recording and a 600-second
blocks16 hold, exits 1 after 761.157 seconds. The UI workflow fails its unchanged
45-second export-ready assertion at test time 706.82 seconds. The recording UI
shows Completed / 10:33 and remains on Preparing and checking video. No final
qualification result was produced; this is not a ten-minute pass.

Archive diagnostics report finished, 37,952 accepted/written samples and zero
rejections/drops. Failure preservation copies 641 files / 952,493,479 bytes and is
explicitly incomplete under its 1 GiB cap. Metadata inventory finds 318 consecutive
bundles (initialization plus 317 media segments), matching all manifest entries and
payload sizes. The two skipped files are assembled/export MP4 intermediates.
Source payloads total 952,188,452 bytes; metadata agreement alone does not prove
hashes, successful export, decoded frame continuity or A/V quality.

Worker evidence is complete with 12 events and no omitted/invalid/oversized lines.
The decoder reports 18,577 fresh frames and EOF. Encoder exit is 255 after SIGTERM;
the direct recorder exits 0 without requested termination. Clean final delivery
requires the saved-frame comparison below; the existing qualification allows
exit 255 when the one scoped SIGTERM precedes matching terminal and exit events.
The exit code alone is not another failure.

Artifact-only replay preparation is in this run's `export-replay/` directory.
Measure hash-checked recovery, assembly, remux and full decode in isolated macOS
and iOS 17.5 processes before deciding whether the fixed UI allowance is adequate.
The original exporter source matches the three-minute replay. No deadline or
production exporter change has been made.

### Same-source export and media diagnosis

Source-hashed, artifact-only native export replays both succeed. macOS takes
21.841 seconds: recovery 0.766 s, assembly 1.442 s, remux 8.145 s and validation
11.151 s. An owned iPhone 14 / iOS 17.5 standalone simulator process takes
42.656 seconds: recovery 0.484 s, assembly 0.988 s, remux 5.149 s and validation
34.666 s. Both recover the preserved source hashes and fully decode 18,976 video
frames plus 30,362,560 audio samples before publication. The simulator is shut
down and deleted. Replay paths are `export-replay/mac-e81hicab` and
`export-replay/sim-2f5ddwi2`; `replay-summary.json` preserves stage timings.

The simulator replay is close to the 45-second UI allowance, suggesting inadequate
headroom for longer exports. It does not reproduce or conclusively explain the
full app's timeout. Full validation remains required. Measure in-app stage progress
before changing the test allowance; do not classify the original run as passed.

Independent archive checks pass: 18,976 consecutive frames 0–18975 at 30 fps,
zero source loss, 316 matched complete audio markers with maximum offset
0.020833 ms, and audio ending 20 ms after video. All 126 complete five-second
payload windows pass the frozen 6–18 Mbps band; mean 12.018853 Mbps, minimum
11.827096 and maximum 12.129547 Mbps. This archive is the native replay export
from preserved original segments, not an original successfully published UI export.

The initial artifact diagnostic runner reaches its generic helper's 4 MiB stdout
limit while reading frame metadata. Its failure is retained. A separate diagnostic
uses a bounded 64 MiB buffer and preserves the same frame, sync and payload checks;
archive/live probe outputs are measured, with no production runner change.

The live file fully decodes and has 18,577 consecutive video identities 218–18794.
Its marker check fails on the raw first pulse: onset 25.270833 ms, duration
57.9375 ms, exclusive end 83.208333 ms. This fragment is wholly before the first
video PTS of 1.084 s. All 310 subsequent complete markers, IDs 4–313, are consecutive
and match video with maximum offset 65.25 ms. Audio ends approximately 26.98 ms
after video; decoded audio timestamp gaps remain below 0.159 ms. These diagnostic
facts do not override the original marker failure.

Existing observation and direct-delivery predicates pass against saved evidence:
capture/encoded identities 158–18794 (18,637 each), exactly 60 acquired encoded
frames before the saved live range, and no missing encoded tail. Worker decoder
and output counts equal the 18,577 saved frames; the archive continues 181 frames
after live detach. These additional predicates do not include independent API
report-age checks or replace the failed media/workflow prerequisites. There is no
evidence here requiring a worker shutdown change.

The proposed detector correction leaves only the raw first segment unqualified
when it is shorter than 150 ms and ends strictly before validated video coverage.
Do not infer its identity/frequency. Keep all-sample finiteness checks, the current
20 ms edge rule, complete/long prefix validation, all subsequent pulse checks,
sequence checks and projected fully covered-marker requirements. Boundary tests
must reject a short segment ending at/inside video, a second short segment, missing
covered markers and nonfinite prefix samples. No production media is modified.

The correction is implemented and independently reviewed without findings. Focused
TDD reports five expected failures among 67 tests, then all 67 pass. Full tooling
passes 383 tests. All commands terminate normally; evidence is
`artifacts/qa/initial-audio-prefix-{red,green,tools}.log`.

`recheck-preserved-media.mjs` applies the corrected helper and the original
per-file predicates to the already decoded source evidence, without another full
decode. It additionally extracts the two original overlay crops. Both archive and
live checks pass, with results in `recheck-preserved-media.json`. Live video is
30 fps with zero source loss; all 310 complete overlapping audio markers pass,
maximum offset 65.25 ms, and audio tail 26.975 ms after video. The 123 complete
payload windows pass 3–9 Mbps, mean 7.658093 Mbps, minimum 7.567888 and maximum
7.725250 Mbps. Native scoring changes 710 overlay pixels. Requested live bitrate
is still 6 Mbps; this measurement is not a hard rate-control guarantee.

The initial unqualified acquisition fragment is not claimed to have valid marker
content. The unchanged original UI timeout still prevents complete workflow
qualification. The separate saved-data delivery check is reproducible in
`check-preserved-delivery.mjs` / `preserved-delivery-check.json`. Its success does
not supply the missing independent API report-age proof. Next native diagnostic
should expose bounded export phase progress, preserving full decode and a distinct
original verdict, rather than changing stream shutdown for a normal SIGTERM.

## Original evidence

At `a2e8141`, the 180-second hold `native-app-qlQcKm` fails the unchanged
45-second native `recordings.exportReady` wait. Recording, streaming, scoring,
stream stop and continued recording all complete before that assertion. The
generic export indicator does not distinguish remux from full decode. Preserve
this failure; do not change export/media deadlines merely to obtain a pass.

The failure bundle preserves 223 files / 967,602,639 bytes, with no omissions.
Preservation boots the owned Shutdown simulator once before copying. Archive
diagnostics finish with 12,814 accepted/written samples and zero rejects/drops.
Independent full decode and the original runner's per-file checks on the temporary
export pass: 6,407 consecutive frames 0–6406, 213.5667 seconds, 30 fps, 106 markers,
maximum marker offset 0.020833 ms, and essentially equal A/V endpoints. All 42
complete payload windows pass 6–18 Mbps (11.827096–12.129547 Mbps).

The saved live file independently decodes, but its original marker detector fails
on a terminal 45.3125 ms pulse followed by 20.479167 ms quiet PCM. The existing edge
rule allows 20 ms, missing this case by 0.479167 ms. All 100 preceding complete
markers, IDs 3–102, are consecutive; the last cut marker is consistent with ID103.
All 5,964 video identities 219–6182 are consecutive. The video ends partway through
marker103, so that marker is outside the fully covered-marker requirement. The
99 overlapping complete markers have maximum offset 65.583 ms; A/V tail difference
is 31.021 ms. These are diagnostic facts, not a passing original workflow.

Artifact-only scripts: `analyze-preserved-media.mjs`, `diagnose-audio-pulses.mjs`,
and `export-replay/` under `artifacts/qa/native-app-qlQcKm`.

## Native exporter isolation

Source-hashed copies of the actual exporter/store/profile add only stage/counter
traces. The same saved archive exports and fully validates on macOS in 6.04 seconds,
and through a standalone process in an owned iPhone14/iOS17.5 simulator in 12.06
seconds, both exit 0 with all 6,407 frames and 10,251,200 audio samples. Original
archives are retained; replay destinations are fresh. The owned simulator is
shut down and deleted. This does not reproduce the app's export delay or explain
the failed 45-second wait. Next diagnostic: trace the same stages inside the full
native workflow while retaining the original wait and all export validation.

## Terminal marker correction

The detector already waits for 40 ms silence to close a pulse, bridging zero
crossings and AAC ringing. Explicitly distinguish the one segment still open at
EOF. Preserve the current 20 ms edge rule, and additionally omit only a short
(under 150 ms) still-open terminal segment. Complete/long terminal segments remain
subject to duration/frequency validation. Internal short segments remain failures.
Do not widen the 100 ms synchronization/coverage budgets, sequence checks, or
projected fully covered-marker checks. This leaves the incomplete terminal fragment
unqualified; it does not establish its full content or duration.

Independent design review approves this scope. TDD covers a short terminal pulse
with measured padding, quiet-tail boundaries immediately below/at 40 ms, a complete
200 ms final pulse with 30 ms quiet that still counts, internal shortened pulses,
and a missing fully covered final marker followed by a late short EOF blip. The
last case must fail projected coverage, preventing the exemption from hiding loss.
Then run focused/full tooling tests and independent reviews. Reanalyze saved media
as a separate diagnostic; never replace the original failure verdict.

Implemented and independently reviewed with no findings. Focused red has three
expected failures out of 53; focused green passes 53 and full tools pass 369, all
terminal green runs exit 0. The seven new tests cover the contract above. Logs are
`structured-terminal-audio-{red,green,tools}.log`. The saved live PCM passes the
corrected helper in `terminal-audio-recheck.json`, with 99 matched complete markers;
the original export timeout and original post-run detector failure remain recorded.

The upcoming native export trace is an artifact-only experimental patch: copied
source is hashed, adds bounded phase/counter output to stderr, and activates only
for DEBUG simulator blocks16. It changes no export operations or deadlines and
will be removed after diagnosis. It is not a production fix or evidence that the
original intermittent delay has been resolved.

## Full-app trace and worker evidence exhaustion

`native-app-24q2q0` at `d7b14f2` plus the saved experimental patch completes the
native UI workflow. Export tracing records assembly 1.917 s, remux 3.056 s and full
decode 14.630 s; assembly through final sync takes 19.628 s. The original delay does
not recur. The diagnostic patch has been removed and the original exporter restored.

All per-file media checks pass: archive 6,445 consecutive frames 0–6444 and live 6,024
consecutive frames 220–6243, approximately 30 fps. Archive/live tail offsets are
13.333/30.152 ms; marker maxima 0.020833/65.583 ms. Complete workload windows remain
within the frozen bands. The full run nevertheless exits 1: its bounded worker
event collector retains 256 events and omits 49. Of the retained events, 249 are idle
state reports. The worker's 500 ms idle polling logs the same state repeatedly;
longer post-run media analysis exhausts evidence even when the pipeline is complete.
The original failure remains authoritative; omitted events cannot be reconstructed.

Independent design review approves correcting redundant logs at their source:
add a dedicated worker-state logging adapter that remembers one copied primitive
identity `(state, gameId, generation, reason)`. Emit the first state and every
change, including optional-field removal and A→B→A. Update the remembered identity
only after logging succeeds. Wire only `index.ts`'s state logger through it.
Supervisor callbacks/state behavior, the separate one-second API reporter, pipeline
events, collector 256-event cap and completeness requirements remain unchanged.

TDD: thousands of identical reports produce one log; all state/scope/reason changes
remain; copied values survive caller mutation and property-order differences;
callback failure can retry. Run focused/full worker tests, build/typecheck and
tooling tests, then independent review. Commit before the next uninstrumented
180-second native run. Only a complete passing run permits proceeding to 600 seconds.

Implemented as `apps/home-daemon/src/worker-state-log.ts` and wired only in
`index.ts`. Focused red has seven expected failures; green passes seven. The full
worker suite passes 160 tests, the TypeScript build/typecheck passes, and tooling
passes 369 tests; all finish with exit 0. Independent specification/quality review
approves with no findings. Logs: `worker-state-log-{red,green,full,build,tools}.log`.
The next native repeat uses the original exporter with no diagnostic patch.

## Complete uninstrumented 180-second pass

At `33232fd`, `native-app-xiMqVd` passes the full runner with exit 0 on iPhone14 /
iOS17.5, with the original exporter, original 45-second export wait and all media
and evidence gates intact. The native UI test passes in263.018seconds.

- Archive: 6,382 consecutive frames0–6381, 212.7333seconds at30fps; 12,764 samples
  accepted/written, zero rejected/dropped. It continues195frames beyond live output.
- Live: 5,960 consecutive acquired frames227–6186, 198.6667 source seconds at30fps;
  final encoded frame6186 is present and no encoded tail is absent. The60 encoded
  acquisition frames167–226 remain explicit. Capture166 precedes encoded167.
- Payload: archive42 complete windows, 12.055801Mbps average, range11.827096–12.129547;
  live38 complete windows, 7.643508Mbps average, range7.578968–7.691480. Every window
  passes the previously frozen6–18 /3–9Mbps bands. Live still exceeds its6Mbps request.
- A/V: maximum marker offset0.020833ms archive /65.583333ms live; tail differences
  +1.333333ms /+29.716553ms. The explicit1.042second live acquisition audio lead passes
  the existing allowance. Native scoring changes647 overlay pixels.
- Observations:39 steady windows each contain150 capture/150 encoded frames.
  Both native report-age proofs match independent API evidence. Recorder and encoder
  each exit0 without a termination request; worker wrapper exits0 after its normal
  fixture shutdown. All11 worker events are retained, with no invalid/oversized/
  omitted events or incomplete line; one unrelated startup log is discarded.

The original failed runs remain failed. This pass does not explain the initial
intermittent export delay or resolve high-rate pixel-noise corruption. It permits
the planned600-second blocks16 qualification, with the same profile, source and
workload bands. Physical camera, Watch networking and adaptive runtime remain open.
