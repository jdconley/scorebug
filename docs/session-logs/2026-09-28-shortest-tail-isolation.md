# Watch recovery review and shortest-tail isolation — September 28

Starting code e40294e with uncommitted delivery-focus documentation. The prior turn
made documentation progress; this turn examined remaining reliability behavior.

## Watch recovery

Read WatchScoringModel, WatchRootView, routed scoring/bootstrap clients and the phone
forwarder. Pending actions already recover every foreground loop through refresh;
Core queries the original receipt before any replay, preserves command identity,
and requires matching fresh authority/revision/age. No missing automatic foreground
retry was found, so no speculative Watch change or model suite was needed. This
source review does not qualify actual WatchConnectivity or radio handoff.

## Interrupted output

Hypothesis: FFmpeg's output-shortest scheduling might constrain the longer audio
tail when SIGTERM interrupts video. Official documentation describes shortest-output
termination and buffering: https://www.ffmpeg.org/ffmpeg.html#Advanced-options

Used a small isolated FFmpeg8.1.2 comparison, not another app/integration run: two
paced synthetic inputs,320x180/30fps H264 and44.1kHzAAC, deliberately offset track
clocks, production-style fragmented MP4 and SIGTERM after4seconds. Both owners were
joined;10second termination deadline with explicit kill/join fallback (not used).

Initial artifact shortest-tail-o4qdrbzy used negative video timestamps; its analysis
failed because the shortest case had no decoded audio. Corrected the fixture to
nonnegative video plus a positive0.5s audio offset and made missing audio explicit.
The initial output is preserved, not relabeled as a pass.

Authoritative artifact: artifacts/qa/shortest-tail-uod24p16/results.json with retained
probe.py, exact argv, logs and outputs. Baseline134video/190audio frames,421.134ms
extra audio. With shortest:7video frames and zero decoded audio; both FFmpeg exits255
follow requested SIGTERM. Probe command95982 joined0 because it records the
comparison; the candidate is a media FAILURE, not acceptance. Full file decoding
alone would not have detected the absent audio; frame inventory did.

Decision: do not adopt shortest from documentation alone. This scoped counterexample
rejects it as a general abrupt-tail fix; it does not locate the production decoder/
scheduler root cause or prove the production pipeline has this specific failure.
No production code/queue/timeout/media setting changed. No more candidate sweep.

## Delivery tracking

Marked the plan's explicit simulator/backend gating task done because the delivery
checkpoint now names the accepted software path and each failing configuration.
Resolution remains in profile/backend qualification; failures were not marked green.
General interrupted-tail qualification remains open. No hardware, container build,
full native vertical or soak was started. All commands terminal.
