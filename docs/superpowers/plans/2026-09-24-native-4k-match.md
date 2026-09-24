# Native 4K representative-match implementation plan

> **For agentic workers:** Use `superpowers:executing-plans` for this bounded slice. Run heavy tests serially. User authorized autonomous continuation; routine design choices do not require another approval.

**Goal:** Exercise true 3840×2160 native archive and live publishing with the supplied match content, then CPU and VideoToolbox proxy encoding on this Mac.

**Architecture:** Add an explicit 2160p30 encoder recipe and a qualification-tool configuration that selects it together with an independent 4K archive profile. Existing app startup and automatic policy ladders stay unchanged. Use the existing direct loopback SRT → production proxy overlay → RTMP → independent recorder route.

**Tech stack:** Swift/AVFoundation/VideoToolbox, H.264/AAC in MPEG-TS over SRT, FFmpeg CPU/VideoToolbox, native segmented archive/export, local RTMP recorder.

## Design and scope

The existing native tool silently scales all input to 1080p. A proxy-only 4K upscale would not test native 4K; arbitrary encoder dimensions would unnecessarily widen the production configuration API. Choose one immutable `uhd2160 = "2160p30"` recipe, 3840×2160 at 24 Mbps/30 fps with the same real-time H.264 settings as other profiles. Explicit tool invocation selects it; normal startup remains 240p. Use explicit existing-profile allowlists for debug live (240p/360p/540p) and candidate (360p/540p/1080p) selections so adding a recipe cannot enable an unqualified iPhone fixture.

`DualOutputConfiguration` in SDKProbe owns qualification-only settings: optional profile ID defaults to 1080p30; only 1080p30 and 2160p30 are accepted. Archive stays independently configured at 12 Mbps (1080) or 24 Mbps (4K). At five seconds the deterministic live bitrate change is 2 Mbps or 8 Mbps respectively. These are experiment settings, not researched adaptation thresholds. Scale bounded mailbox bytes by four for 4K (live 48 MiB, archive 96 MiB), retaining 8/24 item caps; encoder/internal allocations remain separate.

Keep the current three/four CLI arguments and accept a fifth profile ID after timestamp offset. Emit the selected profile, dimensions, rates and queue limits for audit. Prepare a separate 12-second, 360-frame, zero-origin 4K30 SDR MOV with mono 48 kHz PCM from the already tone-mapped private source. Originals remain read-only. HDR, 60 fps, camera timing, relay startup, network impairment, automatic adaptation and phone thermal behavior are outside this experiment.

## Tasks

- [x] Add failing tests for `PublishingVideoProfile(rawValue: "2160p30")`: dimensions 3840×2160, 24 Mbps, 30 fps, shared real-time settings, minimum startup still 240p. Run `swift test --package-path ios/Packages/ScorebugStreaming --filter PublishingVideoProfileTests` and preserve the failing log.
- [x] Add the immutable recipe, rerun profile tests, then the full Streaming package suite.
- [x] Add failing SDKProbe configuration tests: default 1080p limits; explicit 4K archive/live/queue/rate choices; rejection of empty/unknown/360p IDs. Run `swift test --package-path tools/media-sdk-probe --filter DualOutputConfigurationTests`, preserve failure, implement the configuration, rerun all SDKProbe tests and build DualOutputSmoke.
- [x] Wire optional fifth CLI argument, archive profile/queue, publisher profile/queue, scheduled rate and configuration diagnostic into DualOutputSmoke. Add 2160p to invalid iPhone fixture tests and make its allowlist explicit. Run FilmModel tests and simulator build serially.
- [x] Prepare exclusive 4K source and validate exactly 360 frames, uniform 30 fps and zero A/V origin. Save command, probe and source provenance beside the fixture.
- [x] Run CPU then VideoToolbox native network tests in unique artifact folders. Require 360 captured/submitted/encoded/archived/decoded/output frames, no live drops/rejections or archive rejection, actual 4K dimensions in both MP4s, H.264/AAC, <=35 ms frame gaps, <100 ms track-start difference, full A/V decode. Save failures intact.
- [x] Correlate audio against the normalized fixture at 1/5/9 seconds using the existing diagnostic (<100 ms lag); visually inspect archive and overlaid live output. Update representative-match documentation and main plan with exact evidence and remaining limits, review diff, commit.

## Verification record

Component checks: profile RED failed on missing recipe; streaming GREEN passed 168 tests. Configuration RED failed on missing type; SDKProbe GREEN passed six tests and built the native executables. Debug live-selector RED reproduced accidental 4K acceptance. Full FilmModel GREEN passed 498 tests. Independent code review found equivalent candidate-selector widening; its added RED test failed all three live-profile cases, then the explicit candidate allowlist passed all 56 candidate tests. Simulator build passed. Logs use exclusive `artifacts/qa/repeated-live-checkpoint-native-4k-*` names. Network/media results are recorded below; historical 1080p and repeated adaptive tests remain independently scoped evidence.


## Failure diagnostic amendment

CPU v2 passed the full media gates. VideoToolbox v2 stopped native publishing after roughly three seconds (84 proxy-decoded frames); the independent 4K archive retained all 360 frames. Existing boolean health combines five failure boundaries and cannot identify the failed one. Do not guess or enlarge queues.

- [x] Add a typed `SRTPublisher.HealthSnapshot` observation to the existing five health reads (connection, stream state, muxer error, stream error, transport error). The predicate and read order remain unchanged; the optional observer is diagnostic, not atomic health evidence or policy authority. Forward through SRTMediaPublisher and use only the file-driven harness to emit one bounded first-failure event. No settings, buffering or retry changes.
- [x] RED: unit-test each failed boundary plus the actual unconnected adapter callback; GREEN: full Streaming suite and SDKProbe build. Run one new VideoToolbox experiment with the diagnostic, retaining every earlier failure. Diagnose from the first reported boundary before any runtime fix.

Diagnostic Streaming tests passed: 170 (including two new health tests). The SDKProbe incremental build failed linking SDKSmoke against the old SRTPublisher initializer symbol; cleaning that package and rerunning passed all six tests and rebuilt both tools. Independent code review approves the diagnostic; interpret first observed unhealthy state as a clue, not necessarily the initiating cause.


## Local outcome and evidence

Source `072685e` added explicit 4K configuration. Source `9a3e5b3` added diagnostics; `b998b5f` corrects the interim build-status record. The final CPU → VideoToolbox run used `b998b5f`; 1,148 tracked hashes stayed unchanged. Parent wrappers `native-4k-network-warm` and `native-4k-warm-audio` joined with exit zero. All native tools, proxy and recorder children joined; owned loopback ports are no longer held.

- CPU v2 and diagnostic VideoToolbox: each 360 captured/submitted/encoded/archived/proxy-decoded/output frames, actual 4K H.264/AAC, no raw queue loss/rejection, both MP4s fully decode. Separate previews confirm clean archive and live-only score overlay.
- Repeated CPU → VideoToolbox: same complete gates pass. Source scheduling lag maxima 2.520 ms / 2.351 ms. Live gaps 33–34 ms and A/V track-start difference 2 ms. Native runtime settings/limits were unchanged between the failed VT case and diagnostic passes.
- In each passing case, 150 startup frames correctly have no verified-write configuration. All 210 post-change frames match the 8 Mbps receipt ID/session. The 24 Mbps startup value is requested configuration, not verified or achieved bitrate. The first CPU runner incorrectly asserted otherwise; its failed artifacts stay intact.
- Audio correlations at 1/5/9 seconds: clean archives >0.9995 at zero lag; live >0.9856 at stable 67.25 ms lag. Length differences 9.375 ms archive / 28 ms live. Both original passing cases and the repeated pair meet the 100 ms diagnostic tolerance.
- The earlier VideoToolbox v2 case remains failed: 84 proxy-decoded frames, six dropped and 286 rejected live samples, but all 360 archive frames and no archive rejection. No first-boundary diagnostic was available in that old run. The standalone diagnostic run and repeated sequence did not reproduce it; no cause or fix is claimed.

Private evidence root: `artifacts/qa/match-footage-n6n1f13m/`. Successful complete pair: `network-native-warm-4k-software/`, `network-native-warm-4k-videotoolbox/`; correlation: `native-4k-warm-audio-correlation.json`; frozen source verification: `native-4k-warm-source-verification.json`. Earlier successful media/visuals: `network-native-aligned-v2-4k-software/`, `network-native-diagnostic-4k-videotoolbox/`. Failures and assessments remain in their original directories. Native final regression: 499 FilmModel tests pass, in addition to 170 Streaming and six SDKProbe tests. Final arm64 simulator rebuild also passed (`native-4k-health-simulator`, joined exit zero).

## Next bounded work

- [ ] Reproduce the intermittent 4K publishing stop with first-unhealthy diagnostics and bounded host-load/timing evidence. Distinguish transport disconnect, codec/mux queue pressure and receiver exit; do not infer the cause from the later successful runs or enlarge buffers without evidence.
- [ ] Continue historical relay startup-audio and narrow-readiness investigations independently. Keep their old failed records and the existing missing-audio gate.

This slice proves short representative 4K media paths on this Mac. It does not enable production 4K adaptation or qualify HDR/60fps, original camera timing, relay startup, network loss, long-match thermals, physical phone/watch or remote hosts.

Final independent read-only evidence review confirmed both complete runs, timing/audio checks, source hashes, cleanup and regression totals. It also confirmed that the documentation retains the unresolved failure and does not imply production 4K eligibility.
