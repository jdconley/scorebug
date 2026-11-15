# September 28 — crash-boundary packet evidence

Starting `640aee3` plus the preceding simulator-first documentation edits. Previous
turn changed the handoff/iteration policy; this turn makes the next reproduction
answer a missing boundary question. No hardware, agents or broad suite.

## Change

The existing FFmpeg packet diagnostic kept only the first128 packets per lane,
so it could not explain an interrupted stream ending. Format2 preserves that
prefix and adds a separate128-packet circular tail with validated numeric packet
durations. Memory stays bounded, snapshots return chronological independent data,
and terminal logs split tails into small allowlisted records.

An opt-in guardian artifact now survives worker SIGKILL: private0600, unique,
non-overwriting JSON in an explicit existing diagnostic directory. It contains
parsed numeric fields and process exit identity, never raw stderr/argv/URLs.
`--packet-timing on` enables it in the headless native runner; default remains off.
The local Docker adapter rejects this option until its diagnostic mount is wired.

## Focused verification

Six parser regressions failed before implementation. The real worker-kill test
failed because no terminal artifact survived. After the batch,99checks pass across
packet parser, terminal logger and process lifecycle (10589 exit0,15.77s). Worker
typecheck passes. Ten existing lab-option checks pass; the new rejection test
initially omitted the prerequisite software encoder, then passes after correcting
its fixture. Syntax/diff checks pass. No unrelated app/UI/scoring checks.

## One targeted live run

Capture50975 exit0: `headless-native-tC9YyK`, lab`device-lab-ikwV2E`:

```
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-headless-streaming.mjs --host 192.168.1.130  --source <checkout>/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov  --duration 70 --quality 1080 --timing-audit off --worker-encoder software  --worker-crash-after 15 --packet-timing on
```

The interrupted guardian persisted an ended report after worker death, actual
FFmpeg exit255, zero malformed/oversized/incomplete rows and no pipe/drain error.
Demux video end14.7120113s, audio14.7626663s: audio already50.655ms ahead at input.
Mux video end14.6786773s, audio14.7626752s:83.998ms ahead. Thus the output extends
roughly one fewer video frame than the demux input. This localizes two contributors;
it does not isolate where the upstream lead or internal frame loss originated.

Saved proxy/mock interrupted MP4s fully decode and have84.224/86.605ms tails;
recovered files fully decode with16.886/27.995ms tails. Cleanup[]. One recovered
packet report has a malformed row; it is explicitly invalid and not used for
boundary inference. Initial analysis rejected it, then was scoped explicitly to
the valid interrupted report while retaining the invalid report status. No capture
was repeated. Media analysis29067 exit0.

`packet-tail-analysis.json` binds all four media files, diagnostics, config,
shutdown and analysis script. `diagnostic-source-binding.json` and
`producing-diagnostic.patch` bind the unchanged producing diagnostic implementation.
No archive re-export, source-frame identity or full-feature qualification is claimed.
The prior107ms and simulator500ms cases remain open; this run is not their fix.

## Next

Trace publisher TS A/V emission relative to encoder completion using this actual
input lead. Inspect `vendor/HaishinKit/SRTHaishinKit/Sources/TS/TSWriter.swift` before
considering bounded interleaving; current evidence does not justify extra buffers,
timeout tuning or dropping audio. The proxy's lost final video frame is a separate
shutdown boundary. Reuse these files before another live capture. No jobs remain.
