# Startup audio provenance implementation plan

> **For agentic workers:** Use bounded independent review under the existing subagent-driven development workflow. Work only in the local-validation worktree.

**Goal:** Locate the live audio startup offset without changing media timing or acceptance limits.

**Architecture:** Instrument only the direct local RTMP recorder. Collect the first eight demux and pre-mux packet timestamps per audio/video stream from FFmpeg timestamp diagnostics. Discard raw logs, bound line storage, report unsupported/incomplete evidence explicitly, and persist a separate immutable JSON file when the child closes. Cross-stream log order is not causal evidence. Preserve recorder lifecycle, copy mode, MP4 flags and all qualification gates.

**Tech stack:** Node test harness, installed FFmpeg, native iOS simulator integration.

## Existing evidence

Both native C and D admit and dequeue aligned initial audio/video with no mailbox drops. D's live MP4 has a 429 ms audio empty edit; C has a 413 ms video empty edit. Ignoring edits removes these offsets, which does not establish that either edit is incorrect. The independent local archive remains aligned. No demonstrated phone codec/mux race explains D. The installed FFmpeg emits `stats_mux_pre` for encoding but no rows for stream copy; `debug_ts` does provide demux and mux rows with copy mode. Use diagnostics rather than changing the encoding path merely to obtain statistics.

## Tasks

- [x] Add failing tests in `scripts/test/recorder-packet-timing.test.mjs` for chunked diagnostics, bounded first-eight retention, numeric validation, unsupported/truncated lines, independent snapshots and redaction. Implement `scripts/recorder-packet-timing.mjs` with a 2048-byte line cap and fixed field extraction only. Run `node --test scripts/test/recorder-packet-timing.test.mjs` before and after implementation.
- [x] Add opt-in `packetTiming` to `scripts/direct-rtmp-recorder.mjs` and enable it in `scripts/native-streaming-fixture.mjs`. Test lifecycle persistence, output collision refusal, stderr draining and unchanged default behavior in `scripts/test/direct-rtmp-recorder.test.mjs`. Use `-debug_ts -nostats` and a stderr pipe; expose no raw stderr. Persist `direct-rtmp-packet-timing.json` exclusively after child close. Unsupported diagnostics do not silently become valid evidence.
- [x] Verify installed FFmpeg against synthetic local A/V with known positive/negative startup offsets using the actual recorder and compare demux, mux and saved MP4 timestamps. Diagnostics establish offsets, not raw packet completeness or inter-stream emission order.
- [x] Run tools regressions and independent review. Freeze runtime sources and run one full native recovery diagnostic to answer whether the observed live offset exists before the recorder's MP4 muxer. Preserve every failed run. Rehash prior frozen evidence, document findings and commit the bounded checkpoint.

## Limits

FFmpeg diagnostic text is not a stable protocol; recognize the tested format explicitly and report missing/malformed data. Do not infer exact rational clocks from decimal diagnostic seconds. Do not use these observations to grant production quality increases or replace raw recovery qualification. No retiming, silence insertion, start trimming, relaxed audio limit or reinterpretation of old failures.

Reference: [FFmpeg timestamp and encoding statistics documentation](https://ffmpeg.org/ffmpeg.html).

## Diagnostic verification checkpoint

The parser and recorder tests first failed on their new contracts and now pass.
All 2,276 tool tests pass. Independent review found no actionable issues. Real
loopback RTMP cases preserve an incoming audio lead of 456 ms and an incoming
audio lag of 427 ms through the pre-mux observation and saved MP4 within 2 ms.
This validates the diagnostic boundary; it does not explain the previous native
startup failure. All 10,609 frozen previous evidence files still match their
recorded hashes. Fresh native run `native-app-Ic6DDc` completed with exit 0 using frozen runtime
sources and diagnostics enabled.

The complete measured native recovery gate passed on the iPhone 14 / iOS 17.5
simulator: measured 240p→360p admission, a 1,996 ms owned decoder pause,
decoder-stall-triggered reset to 240p, and 10.0001 seconds of independently
qualified healthy recovery. The maximum usable report gap was 146 ms. Both MP4s
fully decoded. The independent 1080p archive contains 3,651 consecutive frames
at 30 fps with no source loss and all 60 audio markers; the live output contains
3,275 consecutive frames with no source loss.

The recorder diagnostics recognized all four lanes. Incoming audio starts at
0 and video at 0.507 seconds; the pre-mux observations and saved MP4 preserve
those times. This run does **not** reproduce D's 429 ms late-audio failure and
cannot resolve its cause. D remains failed; no threshold or media timing changed.
Production upgrades, repeated ramp-up and network-loss recovery remain explicitly
unqualified. The passing recovery run is a local laboratory checkpoint only.

Next add bounded first-AAC and mux startup observations on the phone, then worker
audio-boundary observations if needed, so a future late-audio recurrence can be
localized upstream of the recorder. The older aggregate control-maintenance delay
also remains unresolved. Continue repeated fresh candidate campaigns, longer
sessions and physical-device/other-host verification after those boundaries have
adequate evidence. Evidence is indexed by
`artifacts/qa/startup-audio-provenance-final-verification.json`.
