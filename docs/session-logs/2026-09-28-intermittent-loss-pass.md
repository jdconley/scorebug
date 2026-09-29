# Intermittent packet loss — September 28

Starting7467e56. Previous turn made concrete progress: native congestion/media pass.
No active jobs carried over; no production settings/code changes this turn. Reused
the existing bounded UDP impairment queue and header-only packet observer, adding
`--packet-loss-every` to the short headless lane. No new fixture implementation,
unit-suite repetition, hardware, agents or unrelated regression runs.

## Integration

The option selects everyN-th datagram loss in both directions, N50–1000,30–120s,
1080source, audit off and no other fault modes. Native capture and adaptation stay
normal. Cleanup joins sockets and preserves counters/trace; asserts actual drops,
exact periodic counts, no foreign publisher, unexpected queue drops or errors.
One surviving publisher is required. Syntax/format/diff checks pass.

`headless-native-MUpcfR`, lab`device-lab-pKql78`. Capture9406 and nativeexport/media83451
joined0; cleanup[]. Producing revision/harness hashes saved in source-binding.json.
Scoped Xcode26.2 command:

`node scripts/test-headless-streaming.mjs --host 192.168.1.130
--source <checkout>/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov
--duration 90 --quality 1080 --timing-audit off --worker-encoder software
--packet-loss-every 100`.

Forward16,794datagrams/167injected drops; reverse6,324/63drops. No overflow,
oversize or close-discard loss. Header trace contains46,006events, closed and
untruncated with no invalid/omitted events or observer errors. All124dropped forward
data events have a later forwarded retransmission with the same sequence;128actual
retransmissions forwarded. This establishes repair at the fixture boundary; decoded
media independently establishes continuity downstream.

Native export reuses the current bundle.47segments verify metadata/sequence/hash.
Archive2,724consecutive1080p30 frames0–2723; both outputs2,643consecutive frames62–2704.
All three fully decode; zero missing/nonincreasing source IDs or audio timestamp
gaps. Every complete5s window has30freshfps; maximum video gap34ms, A/V ends≤15ms.
The archive continues19frames past live. One native publisher/generation throughout,
one Start/final Stop. No new changing-score/Watch/UI claim; their retained passes
remain separate.

`loss-acceptance.json` binds results, repair trace, source, verifier, MP4s and cleanup
hashes. `packet-repair.json` records exact repair counts. Scripts and per-file reports
are in artifacts/qa/intermittent-loss-20260928 and the run's loss-media directory.
No native rebuild or decode rerun after this result.

## Next

Finish interrupted output-tail handling and sustained/backend qualification. Read-only
inspection confirms guardian immediately SIGTERMs FFmpeg on worker IPC loss; input
decoder threading defaults toautomatic and already supports explicitslice mode.
Retained hard-crash output had508–548ms extra audio. A short controlled decoder-mode
comparison can test whether buffered decoding contributes before changing shutdown
or adding output latency. No root cause is yet established and no setting changed.
Avoid another broad phone/Watch or adaptive capture for that isolated question.
All jobs terminal; no active processes from this work.
