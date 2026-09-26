# Ordinary camera adaptation — September 25

## Starting point

Authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starts at `1ed26e8`. Both reviews approve production probe/cost `5c707e5`;641 full FilmModel tests,34 streaming tests,71 configuration checks and actual arm64 Release build pass. Earlier continuous delivery and owned lifecycle slices are reviewed. Full vertical goal remains active.

## Work in progress

Execute [ordinary camera runtime integration](../superpowers/plans/2026-09-25-ordinary-camera-adaptation.md). One implementer owns app construction/model tests; root independently prepares the normal local-stack/native-test integration and documentation. No overlapping source edits.

Scope: normal minimum-first publisher plus campaign AAC forwarding, continuous owned measurement and delivery, explicit production admission, guarded progressive 240p/360p ladder, recognized current backend limits and production diagnostic-history opt-out. Preserve all explicit laboratory routes. Add only a current acknowledged quality value for UI/testing, without retained history or new authority. Native UI/media verification follows runtime review.

## Local-stack findings

- `scripts/device-lab.mjs` still starts stock MediaMTX1.21.0. `docker-compose.dev.yml` also selects stock. Stock lacks Scorebug origin, reader association and campaign probe metadata, so normal app measured increases cannot work there even after app wiring.
- `apps/home-daemon/src/config.ts` defaults to 1,000 ms reports; device lab explicitly sets1,000 ms. Adaptive fixtures use100 ms. Existing250 ms delivery freshness needs a coherent normal reporting cadence; do not weaken freshness to hide stale reports. App worker/control polling already switches to100 ms when a quality driver exists.
- The arm64 campaign-v3 image is present: `sha256:3b21c9f328586ac2dbebc7bbef217a5a0d6e517b1dee6b195d733f98c0a4ee23`. An isolated `docker run --rm ... --version` returns `v1.21.0-scorebug-campaign-probe-v3`, exit0. This is version/readiness evidence only, not an active relay or media test. Source build is pinned in `vendor/MediaMTX/Dockerfile`.
- Remote `infra/vps` templates still use stock latest, old path hooks and no authenticated relay-management settings. Portable deployment configuration is real remaining work; laboratory containers do not establish it.
- Existing NativeStreamingTests always opts into VIDEO_OBSERVATIONS and its laboratory 1080p default. A new ordinary test must omit that selector. SimulatorCaptureSource supplies file/synthetic input independently; actual acknowledged source profiles need separate evidence because the proxy's scaled output hides source-size changes.

No physical test launched. The latest read-only device state remains unavailable for both phone and Watch; installed 26.2 phone/Watch simulator runtimes remain usable. Preserve all originals and failed artifacts.

## Verification in progress

The first focused run passes143tests. New tests separately connect default model construction and sole continuous readers/stop, actual AAC callback to the campaign owner's native encoder, production64byte receiver admission with stop revocation, and recognized versus missing/unknown worker backend pressure. Existing full session/owned-driver fixtures cover increase/reset/fresh shared-source+delivery recovery. A second large mock cycle is not being added just to duplicate those tests; the complete ordinary-construction media cycle remains an explicit native integration gate, and no such pass is claimed.

Implementation is committed as `2b48876884611a0ff49795eace49d72a281d50c8`. Full FilmModel passes 648 tests, final focused run passes 146 tests, and the actual arm64 Release simulator build succeeds. All build processes joined. Logs and SHA-256 manifest are preserved in `artifacts/qa/ordinary-camera-runtime-20260925/`. Independent specification and quality reviews approve the change. Quality review independently verifies all three preserved log hashes. Neither review reran broad tests. A possible early bootstrap/status-callback ordering edge was inspected but not reproduced; it is recorded as nonblocking presentation follow-up for the native UI slice. The AAC test uses a typed compressed frame with a synthetic payload: it proves callback/owner/native-encoder handoff, not physical camera audio qualification. Prepared real-match derivative `artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov` remains available,391,321,588bytes, with unchanged SHA256 `c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`. No source preparation or media rerun was repeated.

## Device readiness update

The user approved the phone automation prompt and reported both devices ready. A fresh `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcrun devicectl list devices` completed successfully but still reports both physical devices unavailable. Requested reconnection/unlock; no new automation test has been launched. Prompt approval is recorded and must not be requested again without a new prompt.
