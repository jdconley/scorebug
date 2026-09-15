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
seconds, both exit0 with all 6,407 frames and 10,251,200 audio samples. Original
archives are retained; replay destinations are fresh. The owned simulator is
shut down and deleted. This does not reproduce the app's export delay or explain
the failed 45-second wait. Next diagnostic: trace the same stages inside the full
native workflow while retaining the original wait and all export validation.

## Terminal marker correction

The detector already waits for 40 ms silence to close a pulse, bridging zero
crossings and AAC ringing. Explicitly distinguish the one segment still open at
EOF. Preserve the current 20 ms edge rule, and additionally omit only a short
(under150 ms) still-open terminal segment. Complete/long terminal segments remain
subject to duration/frequency validation. Internal short segments remain failures.
Do not widen the 100 ms synchronization/coverage budgets, sequence checks, or
projected fully covered-marker checks. This leaves the incomplete terminal fragment
unqualified; it does not establish its full content or duration.

Independent design review approves this scope. TDD covers a short terminal pulse
with measured padding, quiet-tail boundaries immediately below/at40 ms, a complete
200 ms final pulse with30 ms quiet that still counts, internal shortened pulses,
and a missing fully covered final marker followed by a late short EOF blip. The
last case must fail projected coverage, preventing the exemption from hiding loss.
Then run focused/full tooling tests and independent reviews. Reanalyze saved media
as a separate diagnostic; never replace the original failure verdict.

Implemented and independently reviewed with no findings. Focused red has three
expected failures out of53; focused green passes53 and full tools pass369, all
terminal green runs exit0. The seven new tests cover the contract above. Logs are
`structured-terminal-audio-{red,green,tools}.log`. The saved live PCM passes the
corrected helper in `terminal-audio-recheck.json`, with99 matched complete markers;
the original export timeout and original post-run detector failure remain recorded.

The upcoming native export trace is an artifact-only experimental patch: copied
source is hashed, adds bounded phase/counter output to stderr, and activates only
for DEBUG simulator blocks16. It changes no export operations or deadlines and
will be removed after diagnosis. It is not a production fix or evidence that the
original intermittent delay has been resolved.
