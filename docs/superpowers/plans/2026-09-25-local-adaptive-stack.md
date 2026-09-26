# Local adaptive streaming stack implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development, with independent specification and quality reviews before native qualification.

**Goal:** Make the ordinary local stack supply the metadata and report cadence required by the production camera controller.

**Architecture:** Select the already maintained campaign-v3 ingest relay in device-lab and local Compose. Keep the mock output sink separate and preserve all explicit historical laboratory image selections. Use 100 ms worker reports by default, retaining explicit supported overrides and existing freshness contracts.

**Tech stack:** Node/TypeScript, Docker Compose, pinned MediaMTX source build, FFmpeg worker.

## Implementation

- [ ] Change only normal ingest selection in `scripts/device-lab.mjs` and `docker-compose.dev.yml` to `scorebug/ingest:campaign-probe-v3`. Add Compose build context `./vendor/MediaMTX` so a clean host can build it. Keep output sink stock and loopback management/authentication unchanged. Do not alter `nativeRelayImageTag`'s explicit laboratory routes or retag qualified images.
- [ ] Change `apps/home-daemon/src/config.ts` report default from 1000 to 100 ms. Preserve validated 100–5000 ms explicit overrides. Set device-lab's explicit interval to 100 ms. Add configuration tests for default and explicit 1000 ms; explain that a slower override can prevent adaptive increases without making recording fail.
- [ ] Verify selection through a small reusable normal-stack settings module if needed for behavioral tests; avoid brittle tests that merely search source strings. Do not add a generalized configuration layer. Compose validation must establish the actual ingest image/build context, management bindings and unchanged sink.
- [ ] Update `docs/device-testing.md`, `vendor/MediaMTX/README.md`, and normal configuration examples as needed to explain building the custom ingest image and reporting cadence. Preserve historical laboratory results; current documentation must no longer claim regular local selection is stock. Remote deployment remains separately unqualified.
- [ ] Run focused device-lab/config tests, relevant worker tests and typecheck, plus `docker compose -f docker-compose.dev.yml config`. Use existing image/version for a bounded real device-lab startup/shutdown smoke; preserve artifacts and join all children. No media claim from readiness alone.
- [ ] Review specification, then quality; fix findings before continuing. Commit only the slice's files.

## Native verification next

- [ ] Add an ordinary-construction simulator UI route with source injection only, omitting VIDEO_OBSERVATIONS and all controller-enabling flags. Reuse real setup/scoring/record/stream/stop/export workflow without weakening physical-only tests.
- [ ] Expose bounded current acknowledged streaming quality to the UI, so source transitions are visible independently of proxy output scaling.
- [ ] Run real-match derivative through clean archive, overlay MP4 and mock RTMP MP4; verify all three decode, native score change, start-low, measured increase and archive continuation. Then qualify faults/reset/recovery, paired Watch and physical camera separately.
