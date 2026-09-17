# Fresh candidate audio/video window implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded SDK/adapter implementation and independent spec/quality reviews. The parent owns verifier integration, Apple/native runs, evidence and commits.

**Goal:** Qualify fresh combined candidate H.264/AAC MPEG-TS cost during independent recording and live publishing, with independently replayable accounting.

**Architecture:** Copy bounded actual AAC payloads at the live publisher's compressed-output boundary. A finite source-aligned owner combines those packets with the off-network candidate's video through CandidateTransportMeasurement. Scalar mux input receipts permit an independent JavaScript replay of MPEG-TS/PES/PCR/program-table and per-write SRT message accounting. Production automatic upgrades remain gated on later combined fresh headroom admission.

**Tech stack:** Swift 6, AVFoundation/VideoToolbox, HaishinKit/SRTHaishinKit, MPEG-TS/SRT, Node qualification tools, iOS 17.5 simulator.

## Design

Reuse the live AAC encoder. A second AAC encoder would add work and could produce a different audio cost. Nominal audio bitrate would miss actual frame sizes and packaging. An immutable copied AAC observation preserves actual compressed payload without retaining the codec's pooled buffer. No observation is created when the optional observer is absent.

SRTStream.CompressedAudioFrame records sourcePTS, publishingGeneration, wasEncoded, observedAt, valid, sampleRate, channelCount, framesPerPacket, audioObjectType and payload Data. Validate one AAC-LC packet (at most 8,184 bytes), exact supported rate, 1,024 frames, packet description and host time before copying. Invalid observations contain no copied payload. Native AAC and compressed passthrough are explicitly distinguished. Notify synchronously only after the live mux accepts the packet; do not change the live publisher on observer rejection.

CandidateTransportMeasurement.Result gains at most 633 scalar input entries in actual append order: media type, PTS, optional DTS, encoded byte count, sync flag, and parameter-set bytes including four-byte prefixes. Audio has no DTS or parameter-set bytes. These receipts describe the input to the real mux, not delivery. All prior count/byte/startup limits stay in place.

The new ScorebugStreaming window has immutable attempt scope/profile and binds exactly one candidate encoder ID and live publishing generation. It accepts only fresh native AAC from that generation. The raw candidate video window sets its source range; AAC before its first raw video PTS is ignored. Packets ahead of the latest raw video PTS wait in at most 16 slots / 128 KiB, then drain when that source boundary advances. Audio is selected from first through last video PTS, with a following AAC packet as an end-coverage witness. Accepted packets must be contiguous at 1,024/sampleRate (allow only host-clock quantization (100 ns)), retain only scalar evidence after muxing, and preserve fixed audio format. Initial/final audio coverage may differ by at most one AAC packet from the video boundaries.

Raw-window closure starts a one-second audio-completion allowance. Native video completion remains joined; after it returns, await only the remaining allowance if the following AAC witness is absent. One shared terminal operation and a cancellable joined timer may be used, with no per-packet task. Cancellation/pressure/owner change wakes any audio wait and prevents successful evidence. No window lock may be held while entering the candidate encoder: the allowed lock order is measurement state -> candidate state -> A/V window -> mux counter, with raw range advancement releasing the window lock before SDK offer.

The native fixture opts into this owner, exports version 3 while retaining historical v1/v2 verification, and requires v3 for new qualification runs. Its existing pressure and frame-identity gates remain. The independent verifier replays mux bytes from scalar receipts: exact rational 90 kHz clock, PTS/DTS PES headers, ADTS/AUD/parameter sets, 183-byte first payload (176 with PCR), subsequent 184-byte payloads, 188-byte packets, startup/repeated PAT+PMT, and separately rounded 1,316-byte messages. It joins every video receipt to native encoder evidence and every audio receipt to live AAC evidence, checks audio cadence/coverage/generation/freshness and pending limits, and rejects incomplete or altered totals. Rates remain application-payload cost, excluding control traffic, retransmissions and spare-capacity claims.

## Tasks and verification

- [x] 1. Add SDK tests before implementation for immutable bounded AAC snapshots, actual native vs passthrough, lifecycle/generation, malformed input and accepted-mux notification. Extend mux comparison tests to assert complete ordered scalar receipts. Run red, implement SDK observer/receipts, run focused green. Files: new `SRTHaishinKit/Sources/SRT/CompressedAudioFrame.swift`, `SRTStream.swift`, `CandidateTransportMeasurement.swift`, SDK tests and README.
- [x] 2. Add independent replay verifier tests before implementation. Mutate receipts, clocks, totals, order, keyframe packaging, audio cadence/coverage/format/generation, size and freshness. Implement `scripts/candidate-transport-cost.mjs` and v3 support in `native-candidate-measurement.mjs`, preserving historical output shapes. Validate exact counts against fixtures and ultimately actual native receipts.
- [x] 3. Add source-window/lifecycle tests, implement the new Streaming owner and optional integration in PublishingCandidateEncoder/PublishingCandidateMeasurement. Forward the optional AAC observer through SRTPublisher/SRTMediaPublisher. Check pending count/byte bounds, delayed audio, missing audio timeout, wrong generation, cancellation while finishing, raw/encoded rejection, no reentry/deadlock, exact terminal joins and unchanged video-only behavior.
- [x] 4. Connect the native fixture via CaptureStreamingModel, pin generation from the existing live startup receipt, serialize v3 evidence and require it in `test-native-app.mjs`. Test model serialization/lifecycle. Update provenance inventory and exact patch round trip.
- [x] 5. Run SDK, clean Streaming, model and tooling suites, simulator and unsigned combined phone/Watch builds. Run fresh simultaneous 1080p archive / 240p live / 360p, 540p and 1080p candidate trials sequentially. Inspect actual archive/live frame identity, audio markers, pressure and candidate A/V receipts; independent replay must match exact mux totals. Preserve every failed run separately and correct root causes without relaxing existing media gates.
- [x] 6. Obtain spec then quality review, fix regressions and rerun affected checks. Freeze new native evidence, verify all 3,612 prior files unchanged, hash final sources/runtime/evidence, update the main plan and commit. Keep the full goal active: repeated headroom admission, upward/recovery trials, long sessions, physical devices and remote workers still require evidence.

Use the existing isolated worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Set `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer` for all Apple tools. Parent owns heavy jobs sequentially; no external stream, deployment or license acceptance. New evidence prefix: `candidate-av-window-`.


Clock verification: this Apple Silicon machine reports a 125/3 ns Mach host tick.
An actual AVAudioTime extrapolation probe at 44.1 kHz measured cadence rounding
from -38.6485 ns to +4.3515 ns. The initial 2 ns proposal was therefore invalid.
The implementation and independent replay allow 100 ns for host tick conversion
and nanosecond CMTime rounding, still far below one audio sample. Both native and
JavaScript positive clock tests failed before this correction; missing-packet,
format, frame, coverage and lifecycle gates remain intact.


## Verified outcome

Fresh iOS 17.5 / iPhone 14 simulator runs `native-app-ul2YK3` (360p),
`native-app-VwPlsL` (540p), and `native-app-ynsGu6` (1080p) passed alongside
independent 1080p recording and 240p live publishing. Every candidate reconciled
121 frames over four seconds. Independent replay matched actual production-mux
cost exactly:

| Candidate | MPEG-TS bytes | SRT payload messages | AAC packets / bytes | Application payload rate |
| --- | ---: | ---: | ---: | ---: |
| 360p30 | 1,962,156 | 1,702 | 188 / 9,836 | 3.925 Mbps |
| 540p30 | 1,933,392 | 1,690 | 188 / 9,836 | 3.867 Mbps |
| 1080p30 | 3,572,376 | 2,934 | 188 / 9,867 | 7.145 Mbps |

These are measured costs for the structured test source, including startup and
packaging; they exclude SRT control/retransmission and lower-layer network costs.
They are not universal bitrate targets, decoded candidate-quality results, or
spare capacity. All saved archive/live ranges were consecutive at approximately
30 fps, all expected audio markers matched, and candidate-window pressure
counters showed no drops or rejections. Initial live acquisition remains separately
accounted for. All candidates peaked at fourteen unresolved raw inputs and
43,606,080 raw bytes, within the qualified bounds.

The first 360p run `native-app-ArGpfb` remains failed and frozen. Its verifier
incorrectly required absent decode timestamps; actual VideoToolbox supplied DTS
equal to PTS for every frame. A red/green regression now permits absent or exactly
rationally equal DTS, rejects unequal DTS, and retains explicit DTS header cost.
Fresh runs above qualify the corrected verifier; replaying the old run did not
change its outcome.

Final checks: 266 SDK, 139 Streaming, 310 native model, and 1,878 tooling tests;
simulator build-for-testing and unsigned combined phone/Watch Release build;
arm64 phone and arm64_32/arm64 Watch binaries; 162 upstream hashes and exact patch
round trip; spec and quality reviews. The final evidence manifest is
`artifacts/qa/candidate-av-window-final-verification.json`. Production automatic
upgrades remain disabled. Next combine fresh candidate cost with repeated fresh
headroom evidence and qualify upward trials/recovery before enabling them.
