# Observe uplink queue pressure over time

Continue from a52a443, a progress checkpoint. The 400 ms recovery experiment
preserved the archive but still failed 24-fps/identity qualification, with more
queue overflows than the preceding 120 ms run. All prior owners are terminal.

Add opt-in bounded diagnostic bins to the local UDP impairment queue. Record
100 ms half-open windows of receive/forward/drop counters, maximum queued bytes
and maximum forwarded residence time. No packet payload/header parsing or media
retention; no new timers, pacing, rate/queue limits, or default behavior changes.
Store at most 8192 sparse windows, then count omitted events/bytes explicitly.
Snapshots are detached; invalid/reversed times remain rejected before mutation.
Native fixtures enable the diagnostic; other users default off. Evidence must
reconcile retained counters plus omitted counters with terminal queue totals.

This establishes timing within the proxy clock, not exact native frame/packet
causality. Native encoded-frame size/IDR evidence and a proven clock mapping remain
separate next work if packet timelines alone do not resolve the loss mechanism.

- [x] Causal tests for disabled defaults, boundary placement, residence/queue peaks,
      conservation across all dispositions, bounded omission and detached snapshots.
- [x] Implement queue-only observation and native-fixture opt-in; test real sockets
      and full tooling; review. Existing queue behavior must remain unchanged.
- [x] Run unchanged 240-second native fixture (slice decoding, 400 ms publish delay)
      and compare overflow timing/rates with delivered media and intact archive.
- [x] Preserve all failed gates; join owners, verify cleanup/source snapshot, hash
      terminal evidence, document findings and commit. Keep production adaptation off.

## Verification before native run

Three causal tests fail on the absent timeline option. Final tooling passes 990
tests, including real UDP sockets, bounded omission, detached snapshots and queue
result equivalence with observation enabled/disabled through rate/delay/overflow
and close changes. Review identified and fixed late-bin pre-dequeue occupancy,
impossible chronological counter placement and inconsistent omitted byte counters;
regressions cover all three. Final review reports no blockers.

The timeline records sparse **event-observed** queue peaks before/after packet
dispositions; missing bins are not continuous occupancy samples. The independent
verifier checks retained counter chronology and byte/packet bounds as well as
aggregate retained-plus-omitted reconciliation. Existing native uplink verifiers
validate optional timeline evidence; legacy snapshots remain supported. No Swift,
encoder, transport or quality-policy settings changed.

## Native result and next action

`native-app-4J8Soo` has identical saved native/media/network settings to
`native-app-wkcOi6`: slice decoding, 400 ms publishing delay, unchanged 240-second
rate4m schedule and adaptive profiles. The native UI workflow passes; full live
qualification fails on −145.3 ms A/V end coverage and also on source identity.

The independent archive preserves all 8165 consecutive 1080p/30 frames over
272.167 seconds, all 135 audio markers, 2.7 ms end-coverage difference and zero
rejected/dropped queue samples. Native publishing preserves 7798 consecutive
frames. All 66 local pressure evaluations replay and all four native profile
receipts meet admission/completion deadlines. The 998 observed native recovery
delay gauges all read 400 ms; median accepted receiver age is 1.625 seconds
(range 1.502–1.824), still under the unchanged two-second limit.

Live media remains failed: minimum five-second receiver window 22 fps, 7682 decoded
pictures across 7738 positions (56 count deficit), 102 absent unique source
identities, 46 repeated observations, 38 non-increasing barcodes and 43 identity/
cadence anomalies. The worker reports 231 decode-error messages; these are message
counts, not damaged-frame counts. Positive audio-PTS gaps total 171.9 ms.

Both queue timelines independently reconcile all counters with no omitted events
(2610 sparse bins each). Forward loss is 1190 overflow packets; reverse loss is
zero. All overflow occurs during the limited phase, in clusters bounded by
60.581–62.381 and 117.681–119.881 seconds after the first proxy packet. The busiest
100-ms bin receives 373780 wire bytes while forwarding 50832. The 262144-byte queue
fills; maximum observed forwarded residence is 525.680 ms, exceeding the 400 ms
configured recovery delay. Sparse bin bounds are not exact packet-loss instants,
and these clocks are not asserted to align exactly with native frame callbacks.
UDP counters include retransmissions/control traffic, so this is not a measurement
of compressed video bitrate or a causal assignment of particular lost frames.

Four partial relay snapshots preserve the same connection identities. Publishing
counters advance from zero to 829 observed loss events, 430 retransmissions and
398 receive drops, then stop increasing after recovery. The worker connection's
observed loss/drop counters remain zero. Native retained sender-drop gauges all
remain zero. Read-only inspection of the exact GoSRT dependency confirms receiver
drop counts include old, previously acknowledged and duplicate queued packets;
neither those drops nor observed sequence gaps equal unique missing-media packets.
No source dependency was modified.

The next concrete path is **sender pacing**, not a larger queue or looser freshness
limit. Inspect actual native SRT maximum-bandwidth/input-bandwidth settings and
separate original data from retransmitted/control traffic before selecting a
bounded pacing experiment. The current native grant/SDK code does not explicitly
set maxbw; its runtime value is not yet observed. SRT documents default maxbw -1,
relative-input mode 0, and warns that abrupt bitrate changes complicate automatic
input estimation: https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md#SRTO_MAXBW .
Do not assume changing to relative mode is sufficient. Encoded-frame size/IDR
correlation and recovery after damage remain open if pacing alone cannot qualify.
Production adaptation, physical devices, long soaks and other hosts remain open.

Evidence: `artifacts/qa/uplink-timeline-*`, `native-app-4J8Soo` native/residual/queue
analyses, and filtered relay captures. Workloads/analysis are terminal and joined.
The finalizer verifies exact owned simulator/container removal, stopped collectors,
unchanged runtime source snapshot and matching stopped QA before hashing terminal
artifacts. The full-live failure is preserved.
