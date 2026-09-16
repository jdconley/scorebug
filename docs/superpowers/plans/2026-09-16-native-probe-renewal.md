# Native renewed-probe qualification

**Goal:** Qualify sustained lease renewal and pressure withdrawal on the actual native publishing connection while preserving the independent archive and fixed-profile live media.

**Runtime baseline:** `857d4ab9bac5ded57ad3565673698b2f85f84f1d`, iOS 17.5 simulator, Xcode 26.2, native 540p H.264/AAC publishing, 1080p30 independent archive, relative SRT pacing, 400 ms peer latency, slice-threaded worker input decoder, full processing/publication evidence and direct RTMP recorder. The archive and frame/A/V gates are unchanged. These are isolated local runs, not production adaptation.

## Sustained renewal result

Run `native-app-BKvdTc` uses `SCOREBUG_TEST_BANDWIDTH_PROBE=renew`, passthrough uplink and a 90-second UI hold. It completes the native UI workflow, scoring/overlay check, clean full decoding and existing diagnostic media gates.

- 484 renewals; 1,502 accepted probe messages / 1,976,632 payload bytes.
- Actual acceptance spans 50.063 seconds, followed by another 40.606 seconds of capture/publishing. Cancellation is sticky through final joined stop.
- Payload rate is **0.315865 Mbps**, and the primitive's accounted rate including its fixed overhead is **0.326425 Mbps**, against the requested 1 Mbps target.
- Archive: all 3,691 consecutive 1080p30 frames, all 61 audio markers, +16.000 ms A/V end coverage.
- Live: all 3,284 consecutive retained identities (192–3475), with a separately accounted 36-frame startup acquisition interval; 54 matched audio markers and +32.032 ms A/V end coverage.
- Minimum reported receiver cadence is 30 fps. Full decode logs contain no errors. Both proxy directions reconcile exactly with no drops, errors or pending packets; forward residence peaks at 5.154 ms.
- Native workflow and owned recorder/worker exits are zero; all parent-owned sessions terminate and are joined.

The fixture evaluates its 50-second observation limit on 100 ms polling boundaries, then revokes. This is not a hard real-time promise to stop at exactly 50.000 seconds: the native SDK independently enforces the 300 ms lease and 60-second/16 MiB bounds. The measured acceptance span is retained rather than rounded into an exact deadline claim.

## Capacity implication

The measured rate matches one seven-packet message per roughly 30 Hz media opportunity (`30 × 1316 × 8 ≈ 0.316 Mbps`). Reliable renewal does not remove this scheduling limit. A requested rate is not delivered headroom; this run cannot admit an upgrade needing 1 Mbps of additional bandwidth, much less the previously measured higher-profile cost.

The next scheduling design must supply the required actual additional load while retaining media priority, bounded ownership and prompt revocation. It needs separate tests for saturation and underdelivery. Receiver evidence must bind the same authenticated publishing connection and probe interval; generic null-packet totals alone cannot identify a stage. Preserve the distinction between native accepted bytes and receiver delivery.

## Pressure run

Run `native-app-siyvpV` uses the same source with `SCOREBUG_TEST_UPLINK_PROFILE=rate4m` and a 180-second hold. The proxy independently records a 60,000.261 ms constrained phase, forwarding 29,154,156 wire bytes during it, then restores the unbounded phase.

The native probe reports `transportPressure` after 401 renewals and 1,245 accepted messages (1,638,420 payload bytes). Its accepted traffic spans 41.507 seconds at 0.315785 Mbps payload / 0.326343 Mbps accounted rate. The first reported pressure observation occurs 41.557 seconds after probe start; 41.507 seconds is the last acceptance span, not the observation time. Terminal bytes remain unchanged. Capture/publishing continue another 138.218 seconds after the last probe acceptance.

The archive preserves all 6,331 consecutive 1080p30 frames, all 105 audio markers and +16.000 ms A/V end coverage. The fixed540p live file preserves all 5,955 consecutive retained identities (192–6146), a separately accounted 37-frame startup acquisition interval, all 99 matched audio markers and +16.998 ms end coverage. Minimum reported receiver cadence is 30 fps. Both decode logs are empty. Proxy conservation and timeline bins reconcile with no drops/errors/pending packets; forward residence reaches 65.116 ms. Native workflow, recorder and worker exits are zero; the parent command terminates and is joined.

This proves an observed native pressure withdrawal alongside healthy fixed-profile media in this finite scenario. The fixture does not export the precise local statistics sample that caused withdrawal, nor an exact cross-clock pressure-onset mapping. Do not infer a specific RTT/buffer threshold crossing time or receiver-confirmed probe throughput from the terminal reason alone.

## Evidence

`artifacts/qa/verify-native-probe-renewal.py` independently reconstructs picture identities from saved barcode pixels, validates raw renewal deadlines/counters and actual reported receiver windows, and reconciles terminal proxy counters against their timeline bins. Per-run output is `probe-renewal-independent.json`. Native logs use `native-probe-renew.log` and `native-probe-pressure.log`. No changes to runtime source were required for these runs.

Independent verification rejects five deliberately damaged copies: archive identity loss, live identity loss, a receiver window below 24 fps, a conserved proxy drop and excessive A/V end offset. These cases reproduced acceptance before the verifier assertions were strengthened and all five are rejected afterward; both original runs still pass. A bounded read-only re-review found no blockers. Terminal artifacts, helpers, logs and source documents are hashed in `artifacts/qa/native-probe-renewal-final-verification.json`.

Highest-sustainable adaptive video quality, receiver-confirmed headroom, physical iPhone/Watch routes, remote hosts and long soaks remain open. The earlier failed adaptive runs are not superseded by a passing fixed-profile experiment.

## Decision and next work

The primitive has now passed actual expired lease, sustained renewal and scheduled-pressure media scenarios at its measured ~0.316 Mbps extra payload rate. Keep it opt-in. Do not convert its requested 1 Mbps target, total receiver traffic or a healthy lower video profile into upgrade headroom.

Next remove the demonstrated opportunity bottleneck with a bounded, publication-owned optional-send schedule. Preserve a single media writer, synchronous media-priority/revocation checks, native nonblocking sends, no catch-up bursts, joined stop and the same archive/live gates. Qualify the actual requested load before increasing bounds for larger measured candidate costs. Authenticated pre-demux receiver accounting must distinguish this probe interval from ordinary null packets and preserve attempt/connection identity across reconnects. Only then can a receiver-confirmed trial support an upward profile admission. Missing feedback must withdraw the probe, and improved conditions must remain discoverable later.
