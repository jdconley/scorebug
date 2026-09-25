# Actual relay recovery-budget comparison

Continues from `2b9214f` in the local-validation worktree. The previous session made progress by reproducing missing-reference damage offline. No physical device session started here.

## Actual transport evidence

`artifacts/qa/reference-loss-relay-20260925/` retains a twelve-second VideoToolbox encode of the prepared volleyball source, exact commands, sender TS, actual relay output TS, logs, decoded barcode bytes, comparisons and a SHA-256 manifest. Relay image is the same campaign-v3 digest as the native experiment: `sha256:3b21c9f328586ac2dbebc7bbef217a5a0d6e517b1dee6b195d733f98c0a4ee23`.

Four isolated scenarios use the actual SRT publisher, MediaMTX relay and SRT reader. The controlled network fault drops one data packet and holds its retransmissions until approximately600ms after the drop; all target sequence/timing observations are retained. This models a delayed recovery, not the full constrained-bandwidth native experiment.

| Scenario | Captured frames | Missing IDs within span | Pixel mismatches at original PTS |
| --- | ---: | ---: | ---: |
| Intact400ms | 359 | 0 | 0 |
| Missing compressed reference400ms | 297 | 2 | 57 |
| Delayed retransmission400ms | 297 | 2 | 53 |
| Delayed retransmission1000ms | 299 | 0 | 0 |

The damaged relay outputs emit no FFmpeg corruption warnings. This directly reproduces the silent damaged-video path through the actual relay. The1000ms case receives the delayed packet and matches every pixel checksum and frame ID in its captured span, with33.33ms timestamp spacing. Reader acquisition boundaries differ; these are captured-span comparisons, not proof of startup/tail completeness. The fixture is video-only and does not qualify native application adaptation, archive/audio, overlay/RTMP, or the full1.5-second delivery deadline.

## Timing follow-up

A repeated1000ms case again matches299 captured frames. Its raw stdout capture batches64KiB, producing loose1.2–3.0-second ingress upper bounds; retain this observation in `reference-loss-relay-timed-20260925`. It does not establish actual media latency.

`reference-loss-relay-udp-timed-20260925` replaces only that observation boundary with individually timestamped UDP output datagrams from the SRT reader. It again matches299 captured frames, with no missing IDs, wrong identities or pixel differences. The298 complete PES arrival upper bounds range1202.2–1256.3ms from sender TS write, median1217.8ms and95th percentile1229.3ms. These end at raw relay-reader ingress and exclude worker decoding, overlay, encoding and RTMP. There is approximately244ms remaining below the unchanged1500ms budget in this controlled case; the complete native route must measure it.

All three diagnostic processes joined, all owned containers were removed, and evidence hashes verified. Source footage and original failures remain intact.

## Implementation and next native test

Add exact1000ms as an explicit laboratory selection through the existing peer-latency setting only for the complete owned retry route. Preserve400ms and all legacy route contracts. Host selection requires owned1, capacity750k-retry, token-budget-v1 and the full270-second route; the worker fixture additionally requires diagnostic mode. Swift accepts1000ms only with its existing complete owned retry environment and preserves exact URL query encoding. Host-only token evidence need not be newly forwarded to the app. Diagnostic collection remains non-passing; the delivery deadline stays1500ms.

Implemented in `c2e0973`. Focused JavaScript237/237 and full FilmModel618/618 pass; both sequential specification and quality reviews approve. Red/green logs and hashes are retained by `artifacts/qa/c2e0973-imported-verification-logs.json`. The media-leaf replay helper was checked against the original failed `mAluZi` run: native probe/compressed-frame/clock leaves still pass, and profile/media leaves still reject the damaged identity.

The full native1000ms diagnostic started under wrapper session9675, log `repeated-live-checkpoint-owned-diagnostic-latency1000-20260925.log`. Exact environment is retained in `owned-latency1000-native-environment-20260925.json`; launch script `run-owned-latency1000-native-20260925.py`. Result pending. Inspect all three recordings and delivery evidence after the process joins. A short relay success alone does not justify production enablement.


## Native1000ms result: clean media, failed timing/progression

`native-app-siloC2` and wrapper9675 joined with intentional diagnostic exit1; collection errors are empty, owned simulator/services cleaned. All three recordings decode. Archive has9276 sequential IDs0–9275; both live outputs have8845 identical sequential IDs221–9065, max video gap34ms. No missing/reversed IDs occur within any recorded span. Detailed probes, frame tables, raw barcode bytes, hashes and results are under `owned-recording-diagnostic/`.

The app remained240p with no measurement registrations or applications. Complete quality history contains344 events: bootstrap,286 delivery failures,56 stale-source rejections, and stop. Source ages are about2.03s, exceeding the unchanged2s freshness bound. The bounded429-row delivery audit stays within its limit. The common media and clock leaves pass, while four-phase checks fail1≠4; the diagnostic native-probe helper also reports no registration (its original missing-first-receipt error is retained). None of these leaf results grants complete recovery qualification.

Actual native encoded-frame observations explain most of the missing budget: median435.37ms and maximum438.54ms submission-to-completion across the final1024 observations. The raw relay experiment used preencoded input and omitted this cost. Earlier native experiments also observed13-frame encoder buffering; MaxFrameDelayCount3 and low-latency encoder creation were unsupported in their tested simulator configurations. Do not repeat those settings as presumed fixes or infer physical hardware support from simulator results.

The AVIO32KiB-fill hypothesis is unsupported: FFmpeg SRT reads return messages and the read loop requires only progress, not a full32KiB. No buffering flag or freshness/deadline change was made.

##700ms candidate

The measured600ms retransmission and roughly435ms encoder delay suggest a700ms recovery buffer could fit below the same1500ms end-to-end deadline. This is an experiment, not a production recommendation. `reference-loss-relay-700-20260925` confirms299 captured frames match source pixels/IDs exactly after the controlled delayed retransmission.298 complete PES ingress upper bounds range900.1–960.1ms; median918.2ms,95th percentile930.0ms. All processes/owned containers joined and hashes verified.

The same explicit owned diagnostic option is being extended to exact700ms, retaining400/1000, all legacy contracts and unchanged deadlines. Focused tests/reviews precede another complete native experiment. The original1000ms failure is retained.


##700ms native run started

Committed `85bc29e` passes250 focused JS tests and14 Swift fixture tests; both specification and quality reviews approve. The full618-test result remains the `c2e0973` baseline, not a rerun claim. Red/green logs and hashes are retained in `85bc29e-imported-verification-logs.json`.

Full native700ms experiment `native-app-7JYkdI` is active under wrapper86509, log `repeated-live-checkpoint-owned-diagnostic-latency700-20260925.log`. Exact environment and launcher use unique700 filenames. No phone test was started. Result pending; source/frame/deadline limits remain unchanged.

A read-only audit of the original four-owner history found the telemetry needed for full owned qualification already exists. The next complete verifier must join original owner/campaign/revision indices across receiver, candidate, witness, application and retry policy evidence. A shared raw candidate validator is being extracted as a bounded prerequisite, preserving existing legacy envelope checks and adding no recovery authority or normal-runner bypass.


## 700 ms native result: clean A/V and score, uncertain timing

`native-app-7JYkdI` and wrapper 86509 joined with intentional diagnostic exit 1. The UI workflow succeeded and collection errors are empty. All three recordings fully decode: archive 9,274 sequential IDs 0–9,273; direct and proxy overlay each 8,826 sequential IDs 224–9,049. Maximum video gaps are 33.334 ms in archive/proxy and 34 ms in direct. No IDs are missing or reversed within any acquired span.

`owned-av-overlay-diagnostic/results.json` additionally passes decoded A/V coverage and 64 archive / 61 each live natural-waveform samples, including a five-second source grid. All three outputs average approximately 30 fresh fps. Both live recordings match the initial 0–0 and final 1–0 glyph templates exactly on their discriminating pixels. The archive continues 224 frames (7.47 seconds) beyond both live tails. These are recorded-media checks; there is no adaptive-phase audio or complete policy pass.

The app remains at 240p. Its 41-event owned history contains one registration, cancelled before candidate binding and settled once. Native lifecycle replay and complete common-media/clock leaves pass; both four-phase checks fail 1≠4. Of 427 delivery windows, 109 are fully on time and 318 have uncertain frames; none classifies definite loss/lateness. The overlapping window totals are not unique video counts.

`latency-budget-diagnosis-v2.json` reconstructs 17,070 per-window arrival bounds: median lower 1445.37 ms / upper 1514.25 ms, with median clock bracket width 69.54 ms. Native encoder submission-to-completion remains median 435.31 ms across the final 1,024 observations. Source evaluation age ranges 1966–2110 ms; the only registration has 0.219 ms readiness remaining. A fully uncertain delivery window immediately precedes cancellation. The first helper report retained as `latency-budget-diagnosis.json` had empty arrival aggregates due to a numeric/string PTS map mismatch; v2 normalizes keys and requires complete arrival coverage. Neither report changes runtime policy.

The next isolated test reruns the existing low-latency encoder request on installed iOS 26.2, since previous unsupported evidence was from iOS 17.5. Wrapper 63832, artifact `encoder-low-latency-H9eUhm`, log `repeated-live-checkpoint-encoder-low-latency-ios262-20260925.log`. Result pending. No production encoder setting, delivery deadline, freshness limit or physical device was changed.

## Raw candidate validation prerequisite

Commit `551828f` extracts shared raw encoding, resources and A/V cost validation. The new entry requires explicit independent owner/source bindings, generation, transferred measurement ID, exclusion of the live encoder, and pinned SDK resource limits. It retains complete original 514-event mAluZi audit bytes and provenance. Both actual candidate measurements pass; mutated frame/audio/resource/session/time evidence rejects. Legacy version/envelope/pressure checks and return shape remain intact. No runner wiring or recovery/admission permission is added.

Focused tests pass 55/55 and relevant regression suites 405/405. Independent spec review passes 144 tests and quality review 192; both approve. Logs and SHA-256 are retained in `551828f-imported-verification-logs.json`. Complete receiver/witness/application/retry joins remain open. Four-phase audio-anchor support is the next bounded prerequisite under implementation.


## Reviewed audio anchors and completed encoder experiments

`aa4f79d` adds four to the existing supported phase counts in `measuredAudioProbeFrames`. All ordering, source identities, coverage, head/tail and grid checks remain unchanged. New exact-anchor and malformed-coverage regressions pass; 87 related tests and 37 tests in each independent specification/quality review pass. Both reviews approve. This enables later four-phase audio verification without manufacturing phases or granting policy authority.

Both isolated iOS 26.2 encoder experiments are joined and their owned simulators cleaned. `encoder-low-latency-H9eUhm` fails native encoder creation with `codecFailed(status: -12908)` when requesting low-latency rate control; its default comparison has no native failure. `encoder-frame-delay-0YMWJx` fails both setting and copying `MaxFrameDelayCount` with -12900; default four-input runs emit only at finish. These reproduce unsupported simulator capabilities on the current installed runtime, not physical-device limitations. Raw attachments and failed verifiers remain preserved. No encoder setting was enabled.

The 700 ms analysis bundle has a 47-file SHA-256 manifest, `owned-diagnostic-analysis-manifest.json`. All analysis processes have joined. No device test started; the user's first-session passcode prompt explanation remains in the physical testing instructions.

Next investigate the relay-to-worker SRT hop separately from the phone uplink. Pinned MediaMTX uses `srt.DefaultConfig()` without latency overrides; pinned gosrt defaults PeerLatency and ReceiverLatency to 120 ms. The earlier raw-relay 700 ms run explicitly requested reader latency 120 ms. This is a concrete remaining buffer to measure, not evidence that reducing it is safe across hosts. Any controlled comparison must retain the 700 ms uplink retransmission buffer, original delayed packet fault, compressed input/output and exact decoder identity checks. Complete native A/V, short delivery windows and source freshness must follow before selecting a setting. Whole-history receiver/witness/application/retry qualification also remains open.
