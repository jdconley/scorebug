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
