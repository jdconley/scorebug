# Ordinary upload recovery budget comparison — September26

Starting checkpoint aedd639 on codex/local-validation, authoritative worktree
`/Users/jd/.codex/worktrees/scorebug-local-validation`.

The preceding goal turn made progress: current phone/Watch builds passed, the
physical attempt established a separate Watch lock blocker and joined without
camera capture, and failed720media was preserved and localized to upstream loss.
No live jobs remained at this turn's start. Hardware unlock remains pending;
independent streaming work can proceed.

## Hypothesis and scope

Observed120ms publishing-hop recovery is shorter than the congested network's
RTT/queue residence. Compare explicit700ms against retained120ms run with the
same ordinary720 app,600s source,750kbps cap, encoder, queues and strict1500ms
capture-to-decoder contract. Existing pressure classification derives thresholds
from negotiated SRT delay, so that parameter also changes its derived limits;
policy logic is unchanged. This is not a pure isolated retransmission-only test.
Do not attribute a result solely to recovery margin without examining reactions.

Implemented explicit bounded local-lab option, using the existing control-plane
setting. App launch environment contains no policy override. Setup/result record
requestedPublishPeerLatencyMs; native telemetry must prove negotiated delay.
Causal red: two missing-option assertions failed,23existing tests passed. Green:
all25focused tests pass, zero skips. Logs under
`artifacts/qa/ordinary-transport-budget-validation`.
Spec review approved four exact source blobs; quality review approved the same blobs. Root verified hashes in review-verification.json.

Prior low-latency/frame-delay property experiments are unsupported on the tested
simulator. Existing opt-in source-cadence pacing removes drain batching but has
not qualified live recovery; no duplicate implementation was introduced.

Source committed f9c5b26 after both reviews; root verified all four source hashes.
Started simulator runner73720, artifact `ordinary-native-3ux2FX`, command:

```sh
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane recovery720 --publish-peer-latency-ms 700
```

Only installed runtimes are used. No capture/build/media work runs concurrently.

## Actual result: strict deadline blocks the comparison

Runner73720 joined exit1; cleanupFailures[], workerExit0/not forced, receiver
finished and owned simulator removed. Run `ordinary-native-3ux2FX` /
`device-lab-Jc3NLf`, runtimef9c5b26. Native failed `initial-minimum`10s gate,
policyReady:false, sourceRejection:time, current revision0/240p. All five captured
delivery windows have0on-time frames and24–26late frames under strict1500ms.
No controller cap/restore exchange occurred. Therefore this is NOT a720p
collapse comparison or evidence that700ms solves the earlier loss.

Requested700ms is bound in result/setup and source-reviewed server propagation.
No applied transition occurred, so the existing ACK-bound witness does not retain
an actual negotiated sender-delay readback. Do not label the requested value as
an independently observed socket value.118attachments preserved; phase JSON
`77AA39FA-F60D-42D6-A958-0D004102A4D4.json`.

Collected the actual27segment native MP4 export. Offline wrapper45635 joined0:
archive1505sequential IDs0–1504; both live1237identical IDs145–1381; all30freshfps,
zero frame-ID or audio timestamp errors, archive continues123frames after live.
Waveform/glyph checks pass12archive/10perlive probes; live0–0→1–0 and clean archive.
Worker geometry is a single actual426×240 run with1237frames. Uplink forwards
all6454packets, no overflow/close discard, peak queue1packet1360bytes.
Native/transport/recovery geometry replay correctly FAILS the missing recovery
phases. Independent three-output media PASS does not relabel that failed workflow.
Root recomputed all44 producing-manifest hashes (5inputs/8code/31outputs);
`root-media-verification.json` explicitly limits the result to initial240p media.

## Next action

The arbitrary strict1500ms contract rejects intact media when recovery time is
increased. Select a coherent reliability-first production timing budget using the
already tested3000ms profile as a starting point; preserve strict1500 as an explicit
benchmark. Keep report freshness250ms, no-progress detection and quality/loss
checks independent. Record timing identity/budget in ordinary diagnostics so
future results cannot silently change contracts. No further unchanged700/strict1500
run. Use same footage/cap for a fresh full ordinary720 recovery after source review.
Do not infer that deadline adjustment itself fixes overflow or the earlier audio loss;
media recovery remains the decisive gate. All jobs are terminal/joined.
