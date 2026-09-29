# Simulator acceptance checkpoint

Updated September 28, 2026. The normal local vertical works: native phone recording
and scoring, separate native Watch scoring, SRT upload, score overlay, RTMP to a
mock YouTube recorder, and optional proxy MP4. **The full release gate is still
open**, chiefly for severe congestion, sustained profiles and external deployment.

This checkpoint consolidates retained incremental results. It is not a claim that
every test was rerun at one Git revision. Artifact directories below are relative
to the authoritative checkout's `artifacts/qa/`; session logs retain revisions,
commands, failures and detailed limits. Re-run an affected workflow when its
production behavior changes, not when unrelated documentation or fixtures change.

| Capability | Evidence | Result and scope |
| --- | --- | --- |
| Two native phones, independent clean archive, changing overlay, both outputs | `native-created-simulators-opRrou/vertical-acceptance.json` | Passed. Native create/discovery/takeover/undo; continuous 30 fps archive and live media; waveform A/V and changing visible score verified. |
| Separate Watch scoring while phone films | `native-created-simulators-yjIyo3/native-media-verification/separate-watch-acceptance.json` | Native takeover/undo/relaunch/end passed on 41 mm Watch UI. Real HTTP; simulator setup fixture. Not WatchConnectivity qualification. Original cleanup false alarm and independent cleanup evidence retained. |
| Pending point, takeover and offline native recovery | `native-scoring-recovery-Ff9bG1` | Passed. Exactly seven durable outcomes, one applied point, two takeovers, two stale rejections, undo/end; app data preserved. Peer takeover uses a real API actor. |
| Source, storage and writer-pressure archive recovery | `recording-faults-20260928-fixed/media-verification/results.json` | Three native cases passed; each exports six seconds of consecutive 30 fps video. Source fault loses two seconds of uncommitted tail. |
| Live source interruption and fresh recording/broadcast | `ordinary-native-C7yloY/native-media-verification/` | Passed. Interrupted archive: 1,320 consecutive frames/44 seconds; fresh archive: 882 frames/29.4 seconds. Four accepted start/stop operations at generations 1–4. Both output sessions decode; final score 1–0. All measured A/V ends within 45 ms. Finite 45-second file source, not a physical camera interruption. |
| API and worker restart | `ordinary-native-QOuplL/native-media-verification/` and `ordinary-native-SvL3gk/native-media-verification/` | Automatic recovery passed, including worker SIGKILL; native archive continuous. Hard-crash interrupted outputs retain 508–548 ms extra audio. |
| Remote Watch end and stream drain | `ordinary-native-q9n288` | Passed; archive and live A/V ends within 40 ms. |
| Native 4K recording | `recording-quality-20260928-media/media-acceptance.json` and `archive-source-acceptance.json` | Quality selection, actual3840×2160 archive, export/playback/relaunch;247consecutive30fps frames, no audio gaps,21.333ms A/V ends. Short recording-only qualification; no4K upload/sustained/physical claim. |
| UHD app integration (partial) | `ordinary-native-z1va0e/attachments`, `production-report-timing-20260928` | Versioned report timing confirms360/720probation;1080applies after its gate. Higher admission is limited by measured padding headroom.4K gate now actually requires2160. Native archive retained; export wait was clipped by terminal test budget, corrected but not reverified. Full4K/live-media/sustained acceptance remains open. |
| 1080p production upload | `ordinary-native-PpPozK/1080-final-acceptance.json` | Native240→360→720→1080climb confirmed at6Mbps; receiver sees1077actual1080frames. Archive8518/live8260consecutive30fps frames, no audio gaps, waveform and changing score pass. Archive continues110frames. A/V ends≤34ms. Short local qualification; no4K/physical/full-match claim. |
| Adaptive upload | `ordinary-native-IZI72F` | Start-low, increase, minimum fallback and recovery work. Clean archive continuous. Severe-collapse live media **fails**: 87 missing frame IDs, 16 audio gaps, maximum video gap 2.4 seconds. |
| Buffered adaptation scheduling and bounded stop | `ordinary-native-kStE7J` | Full720p increase/fallback/recovery, transport, geometry and transitions pass; archive12,991 consecutive frames. Stop ends within97ms A/V. Larger buffering worsens severe-congestion media (149missing IDs,15audio gaps,4.033s maxgap), so production timing is restored. Packet analysis is incomplete due to truncated ranges. |
| Healthy periods around congestion | `retained-congestion-phase-analysis-20260928.json` | Baseline and buffered candidate: every measured five-second window before constraint/after restore has30freshfps, no missing IDs or audio timestamp gaps. All missing IDs are within the imposed constraint. Does not replace failed whole-stream media checks. |
| Relay generations and late readers | `relay-generation-green-20260928.log` | Real API/relay replacement rejects stale generation/session reports and old stream credentials; late current reader decodes A/V; owned cleanup passes. Control telemetry is harness-authored. |
| Local portable server stack | `vps-stack-wozlWz`, `backend-capabilities-20260928`, `device-lab-P7D4bv/macos-service-result.json` | Container persistence/managed relay and encoder initialization passed. Actual Mac launchd worker produces both decoded MP4s with score 1–0 and A/V ends within71ms; clean worker exit and owned descendant cleanup verified. Sustained capacity and external hosts remain open. |

## Tested platform boundaries

| Configuration | What the evidence establishes |
| --- | --- |
| Apple Silicon Mac, Xcode 26.2, iPhone 14/iOS 26.2 simulator | Current full native file-source workflows and real local media pipeline. Build arm64 explicitly; local SRT binaries do not support the attempted x86_64 simulator link. |
| Series 7 41 mm/watchOS 26.2 simulator | Native layout, scoring, restoration and real HTTP while the phone publishes. Companion registration/radio routes remain separate. |
| iOS 17.5/18.5 simulator | Preserved earlier archive/relaunch/export results in [native recording](native-film-app.md); not a fresh full-feature matrix. Use installed runtimes, never assume deleted runtimes remain. |
| Mac software/VideoToolbox worker | Encoder initialization and local pipeline evidence; no blanket 1080p/4K or full-match throughput guarantee. |
| Local Linux container stack | API persistence, managed relay and software worker checks. Not external TLS/firewall/NVIDIA qualification. |
| Physical iPhone/Watch and external hosts | Deferred until the remaining simulator-testable integration gates are resolved. |

## Fault coverage

The [local fault matrix](local-fault-coverage.md) records19retained passing cases
for stale/stall/pressure/ownership and continuous-control behavior. Native publisher
connection loss now has its own actual headless SRT disconnect/rejoin pass:
headless-native-omoEsi preserves the same recording/generation,2137consecutive clean
archive frames and both recovered output recordings. The4.567second live gap remains
explicit. A25s owned relay suspension also passes in headless-native-WH3nME:
failed attempts back off and recover automatically,2733consecutive clean archive
frames, both destinations resume with fully decoded within-session continuity.
The live gap is35.5667s; interrupted audio tail is108ms. Neither result qualifies
isolated packet blackholes or physical radio changes.

The distinct publisher-only blackhole now passes in headless-native-K87zVV:
25s actual bidirectional packet loss, automatic retries/recovery on generation1,
2731consecutive clean archive frames, both output sessions fully decoded without
within-session video/audio gaps. Live gap29.3333s; all A/V ends within42ms. API and
relay management remain reachable. This is native headless integration, not physical
radio or whole-device network-loss qualification.

## Iteration and CI

Batch one behavior change, run its focused checks, then run the affected integration
workflow once. Keep existing incremental Xcode build directories. Use
`node scripts/test-apple.mjs --pending-takeover --ui-only` for that scoring workflow;
it skips unrelated model suites and physical builds. Use
`node scripts/test-ordinary-native-app.mjs --host <LAN-IP> --source <prepared.mov> --lane source-interruption`
with a 45-second prepared clip for the live interruption case. The runner's workflow
result does not by itself qualify the saved media; retain the output analysis too.

Linux CI already covers protocol/scoring, real API recovery, relay credentials and
revocation, software worker media, and container startup/persistence. The new
path-filtered [native workflow](../.github/workflows/native.yml) adds shared Swift
and native scoring-model tests plus a full phone/embedded-Watch simulator build.
It has not yet run on GitHub. It uses the published
[macOS 15 arm64 image and Xcode 26.2](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
Hosted compilation is not Watch UI or Docker media acceptance; those remain bounded
local workflow checkpoints. No physical signing or full media soak runs for each edit.

All outstanding work remains in the [delivery plan](superpowers/plans/2026-09-13-portable-streaming-and-watch.md).

## Latest UHD checkpoint

The short SDK simulator diagnostic reproduces a4K encoder pending-input limit;
low-latency mode cannot create an encoder. Keep that platform limit explicit.
`headless-native-gZctuL` verifies the real native Mac path after the missing-processing
and v4 byte-accounting fixes:360/720/1080confirm, then24Mbps4K reaches the receiver
as444actual3840×2160frames. Probation falls back after real source-frame loss;
recording/publishing survive and lower-quality recovery works. Sustained4K remains
unqualified. Native export and212segment hashes pass. Redundant full-file decode was stopped
after receiver geometry proved real gaps; no full-media qualification is claimed.
This is headless native integration, not simulator UI or hardware acceptance.
See the [session log](session-logs/2026-09-28-missing-processing-race.md).

The follow-up native boundary capture `headless-native-nm6xCH/boundary-analysis.json`
reproduces UHD probation loss and localizes the dropping boundary: SDK raw-input
queue evictions rise to7, app ingress evictions/rejections stay0, and native encoder
submission duration reaches90.8ms. Recording/publishing continue and fallback works.
Host contention versus intrinsic native throughput remains open. No queue/timing
limits changed; full archive decode was not repeated after receiver loss was proven.

A35s fixed-profile native diagnostic (`headless-native-KS4ILp/fixed-uhd-analysis.json`)
shows the combined archive/SRT/proxy path delivering998consecutive4Kreceiver frames
with0SDK/app queue drops. It skips adaptive quality/probing and uses different source
time from the failing climb; not adaptive/sustained/full-media acceptance. The later
scalar-readiness optimization passes11focused history checks and an incremental
FilmModel build. Its adaptive follow-up `headless-native-iOmUFd` still drops29SDK
raw-input frames (app ingress0), reaches87.1ms native submission time and falls back
from UHD; recording/publishing survive. A35s fixed-UHD comparison on a remux of the
same250–300s content region (`headless-native-aWay18`) delivers997consecutive4K
receiver frames with0SDK/app drops and36.4ms maximum submission. This narrows the
difference to adaptive workload/accumulated state, without proving a cause. Both
jobs exit0 and cleanup succeeds; those runner exits are not adaptive quality passes.
No redundant full media decode. Hashed comparison: `uhd-readiness-20260928/comparison.json`.

Short combined guarded1080→UHD diagnostic `headless-native-19R4qp` passes with
908consecutiveUHD frames,0SDK/app drops and hardware selection. Direct adaptive
240→UHD diagnostic `headless-native-MuMtrg` reproduces SDK loss by37s, before stack
profiling; hardware selection confirmed. It skips middle rungs and does not qualify
the normal ladder. See each `isolation-analysis.json` and the
[session log](session-logs/2026-09-28-fast-uhd-reproduction.md). These results narrow
the difference to adaptive workload without requiring long accumulated state.

Further short isolation: `headless-native-mx1Wwc` freezes adaptive polling after
real UHD admission but still has18SDK raw drops; `headless-native-dZDuaa` uses the
production publisher wrapper without measurement campaigns and manually changes
240→UHD, delivering909consecutiveUHD frames with0drops. Both select hardware and
preserve recording/publishing. See their `isolation-analysis.json` and
[session log](session-logs/2026-09-28-uhd-polling-isolation.md). Pre-upgrade measurement
work remains the differentiator; no adaptive fix or full-media pass is claimed.

Warmup/backend comparisons further narrow this: real candidate-only warmup
(`headless-native-fw3Zum`) passes with786consecutiveUHD receiver frames; probe-only
warmup with VideoToolbox proxy (`headless-native-LC8Cpq`) incurs17SDK drops; the
same probe-only path with software proxy (`headless-native-zDpc9c`) passes with
790consecutiveUHD frames and0SDK/app drops. All retain native hardware encoding,
recording/publishing and clean lab shutdown. Hashed `isolation-analysis.json`
reports are retained. Normal adaptive software-proxy verification is in progress;
no full-ladder/media acceptance is claimed from these short comparisons.
