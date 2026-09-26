# Local adaptive streaming stack implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development, with independent specification and quality reviews before native qualification.

**Goal:** Make the ordinary local stack supply the metadata and report cadence required by the production camera controller.

**Architecture:** Select the already maintained campaign-v3 ingest relay in device-lab and local Compose. Keep the mock output sink separate and preserve all explicit historical laboratory image selections. Use 100 ms worker reports by default, retaining explicit supported overrides and existing freshness contracts.

**Tech stack:** Node/TypeScript, Docker Compose, pinned MediaMTX source build, FFmpeg worker.

## Implementation

- [x] Change only normal ingest selection in `scripts/device-lab.mjs` and `docker-compose.dev.yml` to `scorebug/ingest:campaign-probe-v3`. Add Compose build context `./vendor/MediaMTX` so a clean host can build it. Keep output sink stock and loopback management/authentication unchanged. Do not alter `nativeRelayImageTag`'s explicit laboratory routes or retag qualified images.
- [x] Change `apps/home-daemon/src/config.ts` report default from 1000 to 100 ms. Preserve validated 100–5000 ms explicit overrides. Set device-lab's explicit interval to 100 ms. Add configuration tests for default and explicit 1000 ms; explain that a slower override can prevent adaptive increases without making recording fail.
- [x] Verify selection through a small reusable normal-stack settings module if needed for behavioral tests; avoid brittle tests that merely search source strings. Do not add a generalized configuration layer. Compose validation must establish the actual ingest image/build context, management bindings and unchanged sink.
- [x] Update `docs/device-testing.md`, `vendor/MediaMTX/README.md`, and normal configuration examples as needed to explain building the custom ingest image and reporting cadence. Preserve historical laboratory results; current documentation must no longer claim regular local selection is stock. Remote deployment remains separately unqualified.
- [x] Run focused device-lab/config tests, relevant worker tests and typecheck, plus `docker compose -f docker-compose.dev.yml config`. Use existing image/version for a bounded real device-lab startup/shutdown smoke; preserve artifacts and join all children. No media claim from readiness alone.
- [x] Review specification, then quality; fix findings before continuing. Commit only the slice's files.

## Native verification next

- [x] Add an ordinary-construction simulator UI route with source injection only, omitting VIDEO_OBSERVATIONS and all controller-enabling flags. Reuse real setup/scoring/record/stream/stop/export workflow without weakening physical-only tests.
- [x] Expose bounded current acknowledged streaming quality to the UI, so source transitions are visible independently of proxy output scaling.
- [ ] Run real-match derivative through clean archive, overlay MP4 and mock RTMP MP4; verify all three decode, native score change, start-low, measured increase and archive continuation. Then qualify faults/reset/recovery, paired Watch and physical camera separately.

## Ordinary native route details

Use a dedicated method alongside `PhysicalStreamingTests` and share its real setup/scoring/capture/stop/export helper. Keep both existing physical entry points explicitly simulator-skipped, and allow the new method only on a simulator with explicit disposable device-lab credentials. Only the new method launches with `SCOREBUG_TEST_FILE_CAPTURE=1`; omit `SCOREBUG_TEST_VIDEO_OBSERVATIONS`, native-quality, owned-measurement and all trial/timing selectors. It must use the same normal publisher/controller factory as the phone. Do not bypass the real setup UI or native scoring.

For UI evidence, display the current acknowledged profile and bitrate in `StreamingControlsView` with a stable accessibility value. The model already exposes `appliedPublishingSettings`; inspect/close the possible bootstrap-before-start-completion callback edge with one targeted regression. Never display a desired or merely requested setting as acknowledged. Existing detach/cancel ownership checks must remain.

The ordinary simulator workflow must observe acknowledged 240p, then wait for acknowledged 360p with a bounded deadline, score HOME from 0 to 1 during live delivery, stop streaming, prove archive time continues, stop and export a newly created recording. Failure to increase is a failed adaptive gate even when all outputs exist. Preserve media and bounded status evidence for diagnosis rather than silently extending timing or switching to lab flags.

Use a separate focused launcher instead of adding production behavior to the large historical laboratory launcher. It should create one owned iPhone 14 simulator using installed iOS 26.2, build/install the Debug app, copy and hash the existing real-match derivative into its container, and inject credentials through the private xctestrun environment. Keep secrets out of argv/shared logs. Join the test and lab, copy the app recording/export and retain all failed artifacts before deleting only its owned simulator. Record HEAD and actual source SHA. No missing runtime downloads or original Downloads modifications.

Media verification must fully decode all three MP4s, confirm both output streams have audio and video, match direct/proxy frame identities and native score change using existing analysis helpers where compatible, and verify archive continuity/continuation. Reuse prepared source `artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov` (SHA-256 `c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`). This initial ordinary smoke does not close fault/reset/recovery, paired Watch, physical camera, wider resolutions or sustained-network gates.
