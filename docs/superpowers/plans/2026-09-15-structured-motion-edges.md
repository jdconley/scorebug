# Structured-motion export and terminal audio diagnosis

Use systematic debugging and bounded subagent implementation with independent
specification/quality review. Parent owns isolated native/media execution.

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
