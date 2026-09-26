# Relative pacing with measured ordinary adaptation

**Goal:** Determine whether the existing relative SRT sender pacing option reduces collapse loss in the current measured 240/360/720 pipeline sufficiently to pass complete media acceptance.

**Status:** Comparison complete; not qualified. Initial360p confirmed, then fell to240p before720p and before any bandwidth cap. Full captured-span media passes, but progressive ramp/recovery fails. Keep relative pacing opt-in. [Session evidence](../../session-logs/2026-09-26-measured-relative-pacing.md).

**Architecture:** Add an explicit laboratory `--publish-pacing relative` option to the existing ordinary recovery720 launcher. Forward only to the server's existing `SRT_PUBLISH_PACING=relative` setting, which adds publish-URL `maxbw=0`. Leave absent behavior, app/SDK/policy, timing, queue bounds, worker read URL and independent archive unchanged. The run measures packet/media outcomes under an explicitly requested configuration. Effective native bandwidth-ceiling and packet-period gauges are not retained by the ordinary production diagnostics; no measured-gauge claim is made.

**Why now:** First-descent evidence places initial packet overflow before policy reduction. Historical relative pacing reduced bursts but failed a different 1080/540 experiment with an over-capacity upward trial and 400ms recovery. Current measured headroom admission, 720 ladder, 700ms upload delay and 3s broadcast timing remove those specific confounders. This justifies one controlled new comparison; it does not rehabilitate the old failed run or support a new default. Source-cadence pacing and bitrate-first changes already failed under the current route and remain reverted.

Alternatives: changing pressure thresholds now would conflate detection with native replacement behavior; waiting for physical runner LAN permission leaves an independent comparison available. Use existing relative pacing before adding another controller mechanism. The owner authorized autonomous implementation/verification, so execute inline with independent review rather than a new approval stop.

## Implementation

- [x] Add behavioral red tests in `scripts/test/device-lab-options.test.mjs` and `scripts/test/ordinary-native-app.test.mjs`. Accept only explicit `relative`; reject empty, uppercase, whitespace, arbitrary strings, duplicate CLI flags and invalid API types before resource allocation. Absence must clear ambient pacing. Ordinary option requires recovery720.
- [x] Modify `scripts/device-lab.mjs`: add the CLI option and optional `publishPacing` value; extend `deviceLabPublishEnvironment(publishPeerLatencyMs, publishPacing)` to return `SRT_PUBLISH_PACING: publishPacing`, including undefined when omitted. Validate exactly undefined or relative. Pass this environment to the existing scoring server. Record `requestedPublishPacing` in lab setup only when explicitly supplied.
- [x] Modify `scripts/test-ordinary-native-app.mjs`: parse/forward the explicit option to the lab and record `requestedPublishPacing` in its result. Do not add app launch flags or alter physical/separate-scorer defaults. Preserve all existing recovery budgets and gates.
- [x] Run focused option/ordinary/physical/separate scorer regression checks and formatting/diff checks. Independent review, then commit source before capture.

## Controlled verification

- [x] Rehash existing 600-second representative fixture `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov` (expected SHA256 `6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`). Ensure all build/analysis jobs are joined before capture.
- [x] Run `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane recovery720 --publish-peer-latency-ms 700 --publish-pacing relative`. No hardware capture or heavy analysis concurrently. Owned simulator/runtime only; no downloads.
- [x] After native/lab jobs join, collect the actual new archive export, phase attachments and successful-application audit using the existing collectors. Verify the requested server option, tested publish-only grant mapping and unchanged native socket-option path. Keep this source/configuration evidence distinct from independent readback: this run does not retain its actual grant URL or effective native pacing scalars. Replay native/transport/geometry under the same contracts as Kfk8rj; configuration propagation alone cannot establish measured effective pacing or a media pass.
- [x] Run complete archive and both-live-output source-frame/cadence/audio/overlay checks. Compare first overflow, packet classes/bursts, decision/native timing and source loss. Preserve failure exactly; no accepted-window mapping from failed media. Keep uncertainty when encrypted packets cannot map to encoder output.
- [x] Record results in a new session log, hash evidence, update current plan/handoff. If media fails, keep relative pacing opt-in and do not run the same experiment again without a new cause. If it passes, repeatability and physical qualification remain required before production promotion.

## Evidence scope review

Independent review confirms that `SRTSocketURL` parses `maxbw` as the known Int64 option and `SRTSocket.open` applies post-connect options before publishing, failing on a rejected native set call. Existing authenticated API tests prove publish-only `maxbw=0` and unchanged worker read transport. Requested configuration plus this tested source path and native publishing success support a configured-treatment experiment, not an independent effective-rate measurement. Differences in the moment of collapse limit causal comparison with a prior single run. No new observer is added solely to manufacture a stronger label.
