# Receiver failure diagnostics

Continue the authorized adaptive-streaming investigation. The first pressure run
ended its initial worker decoder, then could not reconnect to the one-shot output
recorder. Before changing transport or retry behavior, retain bounded diagnostics
that distinguish input read failures, output-open failures and network errors.

Use a fixed classification vocabulary, bounded line framing and saturating counts.
Never retain raw FFmpeg stderr, URL text, paths or credentials. The guardian drains
stderr only when terminal diagnostics are requested; otherwise it remains ignored.
Join stderr closure before reporting the encoder's actual exit. Carry the sanitized
snapshot through terminal logging and the fixture's strict evidence allowlist.
Unknown messages remain counts, not asserted causes. Diagnostic parsing must not
alter stream qualification or turn warnings into capacity evidence.

- [x] Add red parser, process lifecycle and fixture evidence tests.
- [x] Implement opt-in bounded diagnostics with real close/exit ownership preserved.
- [x] Run worker tests/build and tooling regressions sequentially.
- [x] Repeat the unchanged native pressure experiment and inspect classifications.
- [x] Preserve evidence and document the observed failure; choose fixes from it.

## Diagnostic checkpoint

The opt-in guardian retains fixed counts for input read, output open, connection
refusal/timeout, I/O, invalid data, corrupt packet, decoder and EOF messages. It
never emits message text. Framing retains at most 4096 bytes and all counters
saturate. Terminal logging and the fixture allowlist preserve only those counters
and fixed framing/lifecycle flags. Earlier artifacts without the new lifecycle
flags remain explicitly without them; missing flags do not imply successful drain.

Review identified an unbounded stderr drain when a descendant holds the pipe after
the encoder exits, and a missing pipe-error listener. Both were reproduced in
`receiver-diagnostics-review-red.log`. The final implementation preserves default
exit handling, bounds opt-in drain to 250 ms after the actual encoder exit, reports
that original status, and marks a truncated drain. A permanent pipe-error listener
records a scalar flag without exposing errors or changing a finalized snapshot.
The real descendant test explicitly owns and cleans its child. Review approved
both corrections. Full worker checks pass 339 tests, tooling 934, and worker build.

The unchanged pressure repeat `native-app-NeLIkj` failed live recovery again.
An owned-ingest diagnostic snapshot captured publisher PES decode warnings at
12:35:59 and 12:36:00 UTC, then the initial reader closed at 12:36:01 with the fixed
reason `too many reordered frames (29)`. Connection addresses are hashed; no raw
logs, URLs, paths or credentials are retained. Inspection of the exact local
MediaMTX/mediacommon source shows the SRT reader propagates H.264 DTS-extraction
errors as terminal errors. The error is not proof of actual source frame reordering;
packet loss can disturb the extractor's expected picture-order progression.

The first worker terminal confirms 1767 decoded frames and an input I/O failure
(despite process exit 0). Each of 12 subsequent attempts confirms output-open
connection refusals and exit 195. This separates the initial ingest read failure
from the one-shot RTMP destination's inability to accept retries. Native evidence
still contains 8371 frames, a real 1080p → 540p replacement and continued production.
There was no successful recovery trial, so adaptive qualification remains failed.

The repeat ran before diagnostic shutdown hardening. Its exact source hashes,
tracked patch and new source files are preserved inside the artifact. The hardened
implementation is validated by worker tests/build; this is not represented as a
post-hardening native recovery pass.

## Next causal regression and recovery work

1. Reproduce the SRT reader's H.264 DTS-extraction failure using controlled lost
   access units, including unchanged source PTS and a subsequent random-access
   frame. Verify the failure without the phone or long simulator workflow.
2. Investigate a bounded reader resynchronization that preserves the session and
   original source clock, drops undecodable video only until a valid recovery point,
   and keeps audio flowing. Cover timestamp regression, malformed SPS, resolution
   changes, and genuine reordered input. Do not simply ignore extractor errors,
   synthesize timestamps, or weaken freshness/frame-loss checks.
3. Independently make the owned RTMP recording fixture support sequential worker
   connections with distinct recordings and joined process lifetimes. Qualification
   must account for every attempt and the gaps between them; a restarted file must
   never conceal lost frames or failed recovery.
4. Repeat the same adaptive experiment only after those focused regressions pass.
   Keep local archive, exact source coverage, A/V sync, 24fps and receiver-validated
   recovery gates. Production automatic selection remains disabled.

The repeat's independent local export also passed the complete saved-media checks:
8712 consecutive 1920×1080 frames at 30 fps over 290.4 seconds, all 145 A/V markers,
zero archive queue drops/rejections, 0.0209 ms maximum marker offset and 9.33 ms
A/V tail difference. The proxy's applied schedule/conservation check passes; it
still does not qualify adaptive media recovery. Every process and cleanup step was
joined before final evidence hashing in `receiver-diagnostics-final-verification.json`.
