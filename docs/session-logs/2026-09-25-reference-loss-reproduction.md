# Controlled reference-loss diagnostic

Continued from `78393a7` in the local-validation worktree. No physical device session or production configuration change.

The user clarified that a new device automation session may prompt for the phone passcode. Announce device testing before launch so they can enter it on the phone. The existing device runbook/handoff already records this; never request the passcode in chat.

## Experiment and result

Artifacts: `artifacts/qa/reference-loss-local-20260925/`. The retained `reproduce.py`, `options.py` and `remux.py` record exact commands and source/PES removal. `manifest.json` verifies all retained files. Original footage and failed native evidence remain untouched.

An eight-second 240p VideoToolbox encoding of actual volleyball, beginning at source2932, produces240 sequentially identified frames. Removing the four transport packets for source2934 produces239 decoded frames. Source2935's PTS decodes to ID2933, and57 decoded frame checksums differ from the clean input until the next keyframe. This reproduces the missing-reference damage mechanism locally; it does not prove the exact encrypted packet contents in `native-app-mAluZi`.

Single-variable decoder experiments did not repair it. `err_detect explode` and `careful` preserve the damage. `discardcorrupt` discards the preceding frame, making barcodes monotonic while source2935 still decodes to the wrong identity; all57 frame checksums still differ. Timestamp-aligned comparison prevents treating this as a fix.

FFmpeg stream-copy remuxing removes the transport corruption warnings while retaining the same decoded damage. `discardcorrupt` after remux has no effect. This explains a plausible silent-failure path. It is not an actual MediaMTX replay: cached relay source and the tracked patch show H.264 access units being read and written into a fresh TS stream, but the exact live boundary still needs captured evidence.

All commands exited0 and joined. This diagnostic intentionally contains damaged media; command success does not qualify it. No app/proxy tests were rerun because no production code changed. The whole native qualification remains failed/open.

## Next work

Use the actual SRT/relay path and bounded pre-decoder capture to verify recovery within the delivery budget. The retained native trace measured retransmission598.6ms after a drop against400ms receiver latency. Compare transport timing before selecting a change; do not add decoder flags or weaken frame checks based on monotonic IDs alone.

Primary references checked: [FFmpeg option semantics](https://ffmpeg.org/ffmpeg-all.html), [SRT latency/retransmission model](https://haivision.github.io/srt-rfc/draft-sharabayko-srt.html), [SRT live-transmit latency guidance](https://github.com/Haivision/srt/blob/master/docs/apps/srt-live-transmit.md). The 3–4×RTT recommendation is a starting point, not a qualified latency for this queued impairment fixture.
