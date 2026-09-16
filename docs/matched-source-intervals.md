# Matched source interval measurements

The Media and Streaming packages provide the bounded history and exact interval
matching primitives needed to compare native capture, encoding completion and
worker decoder counts. They are not yet connected to the app's worker-status loop.
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

## Qualification

Seven history tests and fourteen matcher tests cover bounded eviction, snapshot
isolation, quarantine, close, leading/interior losses, encoding drops, missing
capture provenance, bad counts, wrong origins, signed coordinates, wrap, ambiguous
history, exact 1/29-second quantization, Int64.min origins and overflow. The full Media
suite passes 174 tests (119 XCTest + 55 Swift Testing); Streaming passes 39 tests.
The combined unsigned iPhone/embedded Watch Release build verifies package integration.
Independent review found no blocking issue; its numerical-boundary coverage notes
were added and pass. Evidence is retained in
`artifacts/qa/source-interval-final-verification.json`.

This is foundational unit/build qualification. Production collection, consecutive
report association, native fixture export and independent barcode qualification
remain in [the integration plan](superpowers/plans/2026-09-15-matched-source-intervals.md).
Usable capacity, thermal/worker pressure and applied-profile boundaries are still
required before runtime quality changes.
