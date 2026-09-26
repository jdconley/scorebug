# Collapse packet diagnosis — September26

Start5634bea in the authoritative local-validation worktree. Previous goal turn is
progress: full3000/700ms native recovery and independent media verification changed
next action from timing correction to loss attribution. No active owners remain.
Watch unlock is pending; no unchanged hardware retry.

JZQQai confirms both live outputs share collapse damage while independent archive
passes. Existing packet diagnostics are available but ordinary recovery does not
enable them, and its only origin is first peer packet. Add explicit constraint
anchoring for bounded diagnostics; preserve all transport and media behavior.

Causal red:16existing/invalid-route tests pass,2new real-socket tests fail solely
because constraint-anchored windows are unsupported. Implemented origin validation,
exact control-boundary anchor and pre-origin exclusion accounting. Explicit25s
capture is enabled only inside the recovery lab.132focused packet/UDP/lab/ordinary
runner tests pass; source/log hashes in collapse-packet-validation/verification.json.
Read-only spec review requested against frozen three source/test blobs. No media
jobs active and no app source changed.

Both independent reviews approve the exact three blobs. Root rehashed all source/log
entries; no source edits after green tests. Source ready for matched native capture.

Committed source3128283. Active runner67841, `ordinary-native-uDznjI`, same verified600s
source/recovery720/requested700ms. All source test/review jobs joined before launch.
No heavy concurrent analysis/builds during capture.

Runtime lab9fjCGU, disposable simulator8C9D4A19-33A4-4393-910A-44F991F7975D.
Observed runner source3128283 and exact verified fixture hash.

## Joined capture and attribution

Runner67841 joins0: ordinary workflow passes, cleanupFailures:[]. Actual native
export174segments. Native/actual750kbps transport/pre-scale geometry replay pass;
phase attachment9A636314-0320-49A2-AF70-038AA82AD491.json. Runtime3128283.

The new25s packet capture is complete, with no event/byte overflow, invalid headers,
truncated NAK ranges or observer errors. Origin244019.354084ms exactly matches
both the audit receipt and proxy constrained phase; terminal control time covers
the window. It contains all261run overflow drops:228original data plus33ACKACK
control packets,238908wire bytes. No retransmitted data appears in this window.
None of the228dropped data sequences is subsequently queue-forwarded in-window.
First drop895.352ms, last3711.312ms after constrain; max queue residence2795.893ms.
Payloads are encrypted, so PES/source-frame attribution is unavailable.

First missing sequence1279965514 is requested by reverse NAK3685.895ms after cap,
2790.544ms after drop; sender Message Drop Request covers the same range at
3686.565ms. The [SRT specification section3.2.9](https://haivision.github.io/srt-rfc/draft-sharabayko-srt.html#section-3.2.9)
defines that response for requested packets absent from sender buffer. It does
not establish the precise eviction mechanism here. This localizes failed repair
to loss discovered after lengthy FIFO residence; it is not a retransmission storm.

Constraint-relative800–900ms arrivals105272bytes,900–1000ms80416bytes. First
native decrease evaluation is bracketed863–891ms, ACK1324–1352ms; second
1823–1851ms/2295–2322ms. Burst and replacement overlap, but encrypted headers
cannot prove encoder-drain content. Before800ms,290128wire bytes arrived; even
750kbps service plus full16KiB burst allows only91384bytes out, leaving at least
198744bytes backlog. Smoothing replacement alone may therefore be insufficient.

Offline helper review caught/fixed four issues: early close mislabeled complete,
retry counting including the dropped retry itself, missing three-way provenance,
and parser-level malformed/truncated rows. Eight regression checks pass; rereview
approves the frozen helper. Artifacts: collapse-packet-analysis.json,
collapse-control-correlation.json and collapse-packet-validation/helper-review.json.

## Media outcome

Wrapper10986 exits1. Archive10349sequential IDs0–10348,30freshfps/no audio gaps.
Both live outputs9992frames, identical IDs138–10229, one discontinuity4679→4780
(100missing source frames),23audio gaps and maximum video gap3.367s. Archive119
frames past live satisfies continuation. Separate AV59215 exits1: archive71audio
waveform probes and clean glyph checks pass; live summed-audio coverage fails by
about1105ms, not proof of permanent playback offset. Live waveform/glyph checks
are not reached. Original failed manifest remains unchanged;57files are hashed
in failed-media-evidence-manifest.json. No media mapping/qualification is claimed.

All jobs joined. Physical Watch unlock remains pending; no unchanged retry.

## Next bounded intervention

Read-only code/evidence review recommends existing source-cadence pacing as the
smallest controlled comparison, with faster pressure sampling/evaluation likely
needed next if backlog remains. The historical pacer spread replacement tails
but that run admitted an over-capacity trial; current admission removes that
confounder. Wire the existing immutable pacing option in the ordinary constructor,
prove propagation and lifecycle/ownership/freshness, keep3000/700ms/ladder/cap/gates
unchanged, then fully qualify all outputs. Do not claim pacing fixes media from
reduced burstiness alone. If it remains lossy, test faster sampling/local tick
while retaining250ms evidence window and thresholds. Direct minimum saves the
second replacement but not first burst. Preliminary in-place bitrate needs a
larger receipt/partial-application redesign; do not swap mutation calls casually.
