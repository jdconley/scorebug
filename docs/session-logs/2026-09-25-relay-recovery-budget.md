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
