# Downshift GOP loss investigation and repair

**Goal:** Preserve decodable live video through a profile decrease under the
existing impaired-link test, without weakening archive, frame-loss, delivery or
freshness requirements.

**Observed failure:** Frozen native run `native-app-kEQWC0` at `1c311f0` passes
its UI workflow and full A/V decoding but fails the live frame-loss gate. The
archive contains 7,518 consecutive identities, 0–7517. Live output contains
7,001 identities, 232–7292, missing exactly 2928–2987. All missing identities
were captured and compressed locally. ID 2928 is the first new 240p sync frame
after the downshift; decoding resumes at the next sync frame, ID 2988. Worker
source evidence independently counts 150 encoded versus 90 decoded frames in
the affected five-second interval. The original failed verdict is preserved.

The independent worker-status lane supplies 331 classified delivery rows with
maximum sample age 155.987 ms, below the unchanged 250 ms limit. This fixes the
specific observed polling dependency; it does not qualify complete recovery.
The run joins with exit 1, preserves all 1,264 frozen hashes and deletes only its
owned temporary iOS 26.2 simulator. No runtime was installed.

Two hypotheses need distinct evidence:

1. The first new IDR coincides, within all causal clock brackets, with a burst
   containing configured dropped datagram 26000. Adjacent packets spend 158–386 ms
   in the shaped queue, while negotiated SRT delivery delay is 400 ms. The next
   native counter samples show 1,360 additional retransmitted bytes. This is
   consistent with an unrecovered IDR packet; the existing payload-free ledger
   cannot identify that packet's media or retransmission sequence.
2. `TSWriter` resets the video PID continuity counter when its format changes,
   without signaling a transport discontinuity. It also resets the audio counter
   on format changes. A format replacement within one continuous publication
   should retain transport continuity. This is a separately testable protocol
   defect, not yet proof of the saved run's GOP loss.

[ITU-T H.222.0 sections 2.4.3.3–2.4.3.4](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.222.0-201808-S%21%21PDF-E&lang=f&type=items)
define continuity counters and explicit discontinuities. Preserve the existing
continuous timeline rather than introducing a new discontinuity at each profile
change. The [SRT protocol draft](https://haivision.github.io/srt-rfc/draft-sharabayko-srt.html)
defines sequence, message and retransmission header fields. Diagnostic observation
must not alter datagrams, queue behavior, qualification or healthy credit.

## Work

- [x] Preserve compact, reproducible raw-hash-bound diagnosis of kEQWC0.
- [x] Reproduce incorrect PID continuity with byte-level mux tests across video
      format changes, including wraparound and clear/new-publication behavior.
      Check audio format changes as well. Preserve the reset in `clear()`.
- [x] Fix only the demonstrated counter reset and run the relevant vendored suite.
      Independently review continuity and unchanged startup behavior.
- [x] Add bounded, opt-in SRT header diagnostics around proxy queue dispositions.
      Capture data packet sequence/message/timestamp/retransmission and relevant
      control loss/drop ranges, never handshake contents, stream IDs, credentials
      or media payload. Bind rows to existing queue ordinals and monotonic times.
      Preserve truncation/overflow explicitly; diagnostics grant no qualification.
- [x] Test header parsing, bounds, immutable export, ordinal/disposition binding,
      unknown/malformed packets and unchanged default proxy behavior. A successful
      UDP send is not proof of remote receipt or successful late-packet recovery.
- [ ] Review and freeze the next native run with unchanged 400 ms peer latency,
      1,500 ms delivery deadline and media gates. Use installed runtimes only.
      Inspect any loss with packet identities before changing transport settings.
- [ ] Update the main plan with the actual result. Autonomous repeated measured
      probes, the wider ladder, physical devices and remote hosts remain separate.

If transport recovery is still insufficient, derive a prospective latency/pacing
experiment from measured queue and recovery times, preserving the user-facing
frame-rate and archive requirements. Do not relabel old evidence or assume that
removing a mux defect proves reliable loss recovery.

## Verified component checkpoint

`artifacts/qa/native-app-kEQWC0/live-gop-loss-assessment.json` preserves the
original failed result and 18 unchanged raw-file hashes. Re-running
`artifacts/qa/assess-live-gop-kEQWC0.mjs --stdout` reproduces it byte for byte.
The saved failure grants no native media or recovery qualification.

The continuity regressions fail before the two setter-reset removals and pass
afterward. All 38 focused writer tests and all 324 vendored SDK tests pass.
Independent review approves the change. Rebuilding `scorebug.patch` also repairs
pre-existing stale provenance for the already committed probe policy and guard;
this introduces no additional runtime change. All 162 upstream source hashes and
the exact current reverse/forward patch round trip verify.

Header diagnostics are explicitly partial: the selected capacity route observes
from five seconds before its limit until twenty seconds afterward (85–110 s for
`capacity750k`), relative to the first owned UDP packet. Export includes that
origin, requested bounds and excluded-before/after event counts. It records SRT
sequence/message/timestamp/retransmission and bounded ACK/NAK/drop fields, plus
aligned plaintext TS PID/continuity/flags and locally available PES timestamps.
It retains no media, handshake, extension or credential bytes. Observed queue
forwarding remains distinct from remote receipt and successful decoding.

The observer caps retained rows at 131,072 and serialized export at 32 MiB, with
sticky overflow and explicit omissions. It cannot throw into queue forwarding;
legacy queue snapshots and default proxy behavior remain unchanged. Closure joins
pending UDP work before immutable `wx` export. The native route explicitly opts
in; no qualifier reads these diagnostics. All 34 parser tests and 62 integration,
queue/socket/export tests pass. The complete tooling suite passes **4,748 tests**,
joined exit 0 in
`repeated-live-checkpoint-transition-packet-tools-20260925-exit.json`.

A fresh native run is still required. Transport peer latency, deadline, bandwidth
schedule, packet-drop schedule, frame-loss gates and source-health policy remain
unchanged. Packet observations may help identify a later failure; they do not
retroactively supply the missing packet identity in kEQWC0.
