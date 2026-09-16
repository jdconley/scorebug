# Matched source interval measurements

The native app now compares capture, encoding completion and worker decoder counts
over matched source intervals. Its worker-status loop uses bounded source history,
the actual native mux clock and authenticated relay publication association.
Automatic quality adaptation remains disabled.

`VideoSourceHistory` stores exact rational source PTS and monotonic callback time in
separate preallocated capture and encoder rings. Default capacity is 2,048 entries
per stage; valid capacities are 1...8,192. Append updates one slot, without shifting
history, retaining media or creating tasks. Callers must serialize access. Snapshot
creation copies chronological scalar entries; retained snapshots cannot change.
Evicted counts remain explicit. Invalid/reversed callback time, invalid/nonzero-epoch
PTS, duplicate/reordered source PTS or overflow quarantines the entire diagnostic
history. Closing freezes it. Neither invalidity nor closure controls media recording.

`PublishingSourceInterval.match` works on copied history away from the capture path.
It uses the SDK's existing `TransportClock` projection with the actual native origin
and relay ingress origin, preserving exact rational floor arithmetic. Modular matching
handles 33-bit wire wrap and signed/unwrapped decoder coordinates. It also requires
the exact unwrapped endpoint distance, rejects histories spanning half a wrap,
rejects projected collisions, and requires every encoded timestamp in the interval
to occur in capture history. Missing or evicted endpoints produce no result.

The measured interval is **(previous decoder endpoint, current decoder endpoint]**.
For example, if the previous report ended at frame 149 and the next report contains
frames 155–299, the expected encoder count is 150, not 145. All five missing frames
before the current first decoded frame remain counted. The result separates:

- Actual capture callbacks in that source interval.
- Actual encoder completions in the same interval.
- The supplied current decoder fresh-frame count.
- Capture samples not encoded and encoded samples not decoded.
- Missing encoded samples before the first current decoded sample.

Counts describe advancing source timestamps, not unique image content, missing
camera callbacks, worker output or viewer receipt. Closed history remains useful
historical evidence; the result carries no current health or freshness claim.

The caller must independently require two consecutive valid nonempty worker windows
with the same native attempt/profile, worker epoch/attempt, actual reader/publisher
and authenticated clock association. The primitive does not authenticate those
inputs. First acquisition, missed reports, empty windows, stale status, changed
scope, and unavailable evidence must stay unknown or explicit gaps. Capture callback
boundary times and receiver window times are different clocks; no quality-policy
window may silently equate them.

## Native integration

The observation owner samples one uptime value under its existing lock for both
aggregate observation and source-history admission. Production publishing opts into
2,048 entries per stage; other callers default to no history. Invalid diagnostic
history does not reject ordinary media callbacks. Control polling copies history;
no projection, network operation or per-frame task runs on the callback path.

`WorkerSourceIntervalTracker` requires an open native history and clock, authenticated
publication, recognized decoder clock and a valid freshness helper. It binds native
recording/profile/attempt and clock to worker identity/epoch/attempt, reader, publisher
and relay origin. The first report establishes a baseline. Only the next sequence
can produce a match. Skipped sequences re-baseline; rewinds and contradictory
same-sequence contents discard the baseline and keep the sequence high-water mark.
Repeated identical reports cannot refresh a measurement's original freshness lease.

A fresh report may keep a historical baseline available while the five-second
worker window ages. Expiring the report lease discards the baseline, including when
a new response arrives before the local health timer runs. A completed measurement
carries its own freshness helper; it is not current health or policy permission.
Capture replacement clears current evidence immediately. Stream/capture stop snapshots
bounded fixture history before clearing live state and exports it after joined drain.

The debug fixture exports at most 128 runtime intervals, binding every entry to the
closed observation scope and actual native clock. The offline qualifier requires
at least two entries and exactly one independently authenticated worker publication
scope. It checks consecutive immutable decoder reports and exact BigInt source-to-wire
projection against the actual relay origin, then compares the same source interval
with decoded archive and live frame identities. The known fixture has contiguous
30-fps capture/encode timestamps: this oracle qualifies leading/interior decoder
losses, not arbitrary production camera cadence or encoder-loss scenarios. Unit tests
of the lower-level matcher separately cover encoder losses. Missing runtime evidence
cannot be replaced by offline reconstruction.

## Qualification

The foundational matcher passed 39 Streaming tests and the combined unsigned
iPhone/embedded Watch Release build. Current owner integration passes 177 Media
tests (122 XCTest + 55 Swift Testing). The native model suite passes 123 tests,
including consecutive matching, leading loss, duplicate age, contradiction, rewind,
missing reports, scope replacement, lease expiry, invalid history and both stop paths.
The tooling suite passes 646 tests, including 35 independent source-interval tests.
The independent fixture checker covers healthy counts, leading/interior losses,
signed/unwrapped PTS, repeated report ages and malformed/mismatched evidence.
Independent review found no blocking issue and prompted a valid-but-nonconsecutive
sequence regression, which now exercises the intended continuity check.

Foundation evidence remains in `artifacts/qa/source-interval-final-verification.json`.
Runtime integration evidence is in
`artifacts/qa/source-interval-runtime-final-verification.json`. The complete iPhone 14 /
iOS 17.5 fixture `native-app-D1xobo` passed: 1,905 archive frames and 1,463 live frames
at approximately 30 fps, seven independently checked runtime intervals of 150 frames
each, no losses within those intervals, complete encoded drain and score changes.
Sixty startup encoded frames remain explicit acquisition. A/V pulse offset was
0.021 ms archive / 65.25 ms live. The final unsigned iPhone/Watch Release build passes.
This finite synthetic-video run does not qualify camera hardware, sustained physical
thermal load, radio transitions or other-host GPU behavior. Detailed evidence is in
[the integration plan](superpowers/plans/2026-09-15-matched-source-intervals.md).
Usable video capacity, thermal/worker pressure, monotonic policy-window alignment
and applied-profile boundaries remain necessary before runtime quality changes.
