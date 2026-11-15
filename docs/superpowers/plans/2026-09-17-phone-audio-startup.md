# Phone audio startup evidence implementation plan

> **For agentic workers:** Use bounded subagent implementation for the SDK observer and independent spec/quality review. Parent owns adapter/fixture integration, sequential Apple/native tests, and final evidence. Work only in the local-validation worktree.

**Goal:** Expose encoded AAC and emitted MPEG-TS startup timestamps for the live phone publisher so the intermittent live audio-head gap can be localized.

**Architecture:** Retain scalar first-eight audio observations in the existing DEBUG publishing-format fixture. Add an optional synchronous, scalar SDK observer after a PES write is accepted by the local mux output queue/sink. Give each emitted packet its publishing generation, media kind, source PTS/DTS and projected transport PTS/DTS. The DEBUG fixture retains the first eight per media plus counts and invalid flags; no payloads, per-frame tasks, waits or I/O. Wire the observer through both adapters and retain the existing candidate-audio observer alongside it. Persist only after joined stop, as the existing fixture already does.

**Tech stack:** Swift, vendored HaishinKit TS writer, existing publisher adapters and native simulator verification.

## Evidence and decisions

Previous checkpoint `a67fe3e` passed the complete local measured recovery gate and 2,276 tool tests. Its recorder diagnostics preserved a 507 ms audio lead before/after MP4 muxing. The older 429 ms audio-lag failure did not recur and remains unresolved. Current phone evidence aligns first PCM/video at admission/dequeue, while first AAC and TS emission timestamps are absent. Observing only AAC would leave mux behavior ambiguous; packet payload capture is unnecessary for this timestamp boundary. Preserve exact CMTime values, 90 kHz transport integers and publishing generation; never compare unrelated wall clocks.

## Tasks

- [x] SDK observer: add `SRTStream.MuxedPacketFrame` and optional `muxedPacketObserver`. It reports only successful local output admission, never delivery; no observer call when no queue/sink exists or output fails. Capture the generation at publish start. Test buffered startup flush, source/transport timestamps, mixed media, failed output, absent output, clear/reuse and optional observer behavior. Maintain `scorebug.patch` and verify all original upstream hashes and exact round trip.
- [x] Adapter/fixture integration: forward the observer through `SRTPublisher` and `SRTMediaPublisher`. Extend `NativePublishingFormatFixture` with bounded audio/mux records and separate validity flags without changing existing video validity or qualification. Wire audio observation to both the existing candidate owner and the fixture. Add failing tests first for exact fields, bounded retention, invalid generation/timestamps, overflow and no retained payload.
- [x] Verify focused SDK and film-model tests sequentially, then relevant regressions and independent review. The optional observer defaults to nil outside the diagnostic route. No media mutation, reordering or timing changes.
- [x] Freeze runtime source; run one full native recovery gate with phone and recorder diagnostics. Compare codec/mux/recorder startup coordinates using the exported transport clock. Preserve failures, rehash prior frozen evidence, update the investigation and commit. Keep production upgrades disabled and the overall goal active.

## Acceptance limits

This is diagnostic evidence, not network delivery proof. A passing rerun does not resolve a prior intermittent failure. Keep the 100 ms late-audio limit, frame floor, deadline freshness and archive checks unchanged. Physical devices, repeated ramp-up, broader network impairment and other proxy hosts remain required follow-up work.

## Review refinement

The added fixed startup sample exceeds the former 4 KiB format-file allowance.
Both harness routes now share a 32 KiB diagnostic JSON bound. A populated
24-packet metadata regression first reproduced the old rejection and now passes;
over-limit input still rejects before JSON parsing. This changes only the
artifact envelope, not media completeness, quality or timing limits.

Focused RED/GREEN tests pass, followed by all 274 SDK tests and 396 film-model
tests. The maintained SDK patch still round-trips against all 162 original
upstream file hashes. All 2,278 tool tests pass. Independent spec and quality reviews approved the
changes after the diagnostic envelope fix. The full native gate remains pending.

## First native diagnostic

`native-app-P4nb6h` used unchanged frozen runtime sources and exited 1 at local
archive export. The UI's `ArchiveExportError` code 6 maps to `insufficientCapacity`
in the matching Swift enum declaration. All 63 original segment payloads were
rescued and verified against their sizes and SHA-256 values; they total 187,273,762
bytes, requiring 460,383,764 bytes of temporary export headroom. Exact free space
at that failure was not recorded. The archive diagnostic reports finished,
complete persistence with no queue drops. This is not a full decoded-media pass.

The harness's ordinary failure preservation was incomplete, so the owned
simulator's QA files and original recording were rescued separately before
cleanup. The post-run device inventory confirms that owned simulator is gone.
Keep the original failed exit and partial snapshot unchanged. Do not accept a
new Xcode license merely because automatic diagnostic collection reports one.

The new 7,888-byte startup export is valid: all eight retained AAC timestamps
match the audio mux observations, and all sixteen retained mux source-to-transport
projections match the independently exported exact clock. There are 5,212 accepted
AAC packets, 3,336 video packets and 8,548 local mux admissions. First audio is at
10919 transport ticks and first video at 9000, a 21.322 ms audio delay at the phone
mux; the recorder's audio starts 254 ms before its acquired video. These are
separate acquisition boundaries. The prior 429 ms late-audio issue did not recur
and remains unresolved.

## Host recovery and further native verification

Docker's host logs at 23:41:11 and 23:41:21 UTC confirm `no space left on device`
during the first run, including failure of the engine's diagnostic log writes.
The second run, `native-app-UdjIOO`, exited 1 at relay-image setup because Docker
could not start; it never reached app or media verification. Both original failed
results remain unchanged.

Only verified ignored compiled caches were removed, preserving source, package
checkouts, recordings and test evidence. Docker's normal restart timed out while
stopping its remaining processes. The documented forced-stop command succeeded,
followed by a successful start. Read-only preflight confirmed a healthy engine,
no running containers, and the required existing staged-probe relay image.

The third run, `native-app-QNIPnd`, starts with 5,126,242,304 free bytes and frozen
runtime sources. Its wrapper requires at least 4 GiB before admission and samples
free space once per second. This is a measured local test preflight, not a general
product storage requirement.

## Complete native checkpoint

`native-app-QNIPnd` exited 0 with all 855 frozen runtime source hashes unchanged.
The iPhone 14 / iOS 17.5 simulator passed native scoring, clean archive export,
and full decoding of both MP4s. The measured 240p-to-360p trial, owned 1,985 ms
decoder stall, reset to 240p, and 10.00001 seconds of independently healthy
recovery passed. The maximum usable report gap was 193 ms. Minimum free disk
space during the 215 recorded storage samples was 3,639,672,832 bytes.

The 7,882-byte startup export verifies the first eight AAC timestamps unchanged
at mux admission and all sixteen exact source-to-transport clock projections.
Phone audio begins 21.322 ms after video in the shared transport timeline. The
recorder acquires audio 272 ms before video, consistently before and after MP4
muxing. Its clock and acquisition boundary remain distinct from the phone's.
The previous 429 ms late-audio failure did not recur and is not resolved by this
passing run.

All 396 film-model, 274 SDK and 2,278 tool tests passed; spec and quality reviews
approved the implementation. The maintained SDK patch round-trips against all
162 original upstream hashes. Preserve the earlier storage and setup failures,
the rescued original recording, and all prior frozen evidence. Final evidence is
indexed in `artifacts/qa/phone-audio-startup-final-verification.json`.

Next continue repeated fresh candidate campaigns and longer adaptive sessions;
retain these boundary diagnostics if the intermittent startup gap returns.
Production automatic upgrades, repeated ramp-up, network-loss recovery and
physical/other-host qualification remain open. The overall goal remains active.
