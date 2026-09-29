# Simulator acceptance checkpoint

Updated September 28, 2026. The normal local vertical works: native phone recording
and scoring, separate native Watch scoring, SRT upload, score overlay, RTMP to a
mock YouTube recorder, and optional proxy MP4. **The full release gate is still
open**, chiefly for platform limits, interrupted output tails, sustained profiles and external deployment.

This checkpoint consolidates retained incremental results. It is not a claim that
every test was rerun at one Git revision. Artifact directories below are relative
to the authoritative checkout's `artifacts/qa/`; session logs retain revisions,
commands, failures and detailed limits. Re-run an affected workflow when its
production behavior changes, not when unrelated documentation or fixtures change.

| Capability | Evidence | Result and scope |
| --- | --- | --- |
| Physical paired iPhone16Pro/Ultra2 vertical | `physical-paired-live-LlJlWn/vertical-acceptance.json` | Both native workflows pass using real WatchConnectivity setup. Watch takeover/point/undo/away/end observed by recording phone. Clean1080p archive3829frames/127.637s; both live MP4s3283frames with changing1–0/0–1 overlay. All3fully decode; no video gaps>50ms/audio gaps>5ms; track ends≤72ms. Independent archive continuation/export and cleanup pass. Upload stayed240p; adaptive recovery, fresh-motion/perceptual-sync/full-match/radio handoffs remain unqualified. |
| Physical TV volleyball capture | `physical-recovery-EcJuQu/media-validation.json` | Short physical1080p archive:4297frames/143.24s; both overlaid MP4s3735frames. All three fully decode, no encoded video gaps over50ms or audio gaps over5ms. Native phone point and archive continuation/export observed. Adaptive workflow failed:360p trial returned to240p on missing capacity/unknown thermal evidence before impairment. Encoded continuity does not establish fresh-motion, perceptual sync or recovery acceptance. |
| Linux worker image timing and both output formats | `linux-worker-20260928/acceptance.json` | Trixie/FFmpeg7.1.5: compiled worker, actual encoder timing, paced2s720p overlay FLV+MP4, full A/V decode and clean shutdown pass on local Linuxarm64 Docker VM. Bookworm/FFmpeg5.1.9 lacked timing options. No real RTMP/SRT network, sustained or remote-host claim. |
| Native capture and Linux proxy over real local SRT/RTMP | `headless-native-wJYttO/linux-integration-acceptance.json` |120s passes: normal240→360 confirmation, actual receiver1467frames240p/2080frames360p. Clean archive3628consecutive frames; both outputs3547matching frames. All3MP4s decode with audible/gap-free audio and A/V ends≤26ms. Static overlay; no new UI/Watch/full-ladder/remote-host claim. |
| Current two-phone/Watch vertical after DTS interleaving | `native-created-simulators-m1tVpX/vertical-acceptance.json` | All three native workflows pass; archive6495/live6068consecutive30fps frames, gap-free audio,9waveform anchors, visible phone/Watch score changes, clean archive, ends≤48ms and7.8s archive continuation. Original runner cleanup race independently reconciled; owned devices absent and app data preserved. Simulator setup fixture, real HTTP; no companion/radio claim. |
| Two native phones, independent clean archive, changing overlay, both outputs | `native-created-simulators-opRrou/vertical-acceptance.json` | Passed. Native create/discovery/takeover/undo; continuous 30 fps archive and live media; waveform A/V and changing visible score verified. |
| Separate Watch scoring while phone films | `native-created-simulators-yjIyo3/native-media-verification/separate-watch-acceptance.json` | Native takeover/undo/relaunch/end passed on 41 mm Watch UI. Real HTTP; simulator setup fixture. Not WatchConnectivity qualification. Original cleanup false alarm and independent cleanup evidence retained. |
| Pending point, takeover and offline native recovery | `native-scoring-recovery-Ff9bG1` | Passed. Exactly seven durable outcomes, one applied point, two takeovers, two stale rejections, undo/end; app data preserved. Peer takeover uses a real API actor. |
| Source, storage and writer-pressure archive recovery | `recording-faults-20260928-fixed/media-verification/results.json` | Three native cases passed; each exports six seconds of consecutive 30 fps video. Source fault loses two seconds of uncommitted tail. |
| Live source interruption and fresh recording/broadcast | `ordinary-native-C7yloY/native-media-verification/` | Passed. Interrupted archive: 1,320 consecutive frames/44 seconds; fresh archive: 882 frames/29.4 seconds. Four accepted start/stop operations at generations 1–4. Both output sessions decode; final score 1–0. All measured A/V ends within 45 ms. Finite 45-second file source, not a physical camera interruption. |
| Current API/worker crash after DTS interleaving | `ordinary-native-Ha71gs/crash-tail-verification/results.json` | Native iPhone14 simulator workflow passes; all six proxy/mock interrupted/recovered MP4s fully decode with43–60ms end offsets (100ms gate). Cleanup passes. Tail/decode scope only; source identity, archive continuity and waveform were not rechecked. One timing/load/software configuration, not a general bound. |
| API and worker restart | `ordinary-native-QOuplL/native-media-verification/` and `ordinary-native-SvL3gk/native-media-verification/` | Automatic recovery passed, including worker SIGKILL; native archive continuous. Hard-crash interrupted outputs retain 508–548 ms extra audio. |
| Combined client API/SRT outage | `headless-native-KJYNvL/client-network-acceptance.json` | 25-second loss; continuous 2,727-frame archive, same broadcast, automatic reconnect, both MP4 destinations restored. Live gap 27.233 seconds; all five files decode, no within-session frame/audio gaps, A/V ends within 49 ms. Native local fixture, not physical radio qualification. |
| Native worker SIGKILL recovery | `headless-native-MAuIfq/worker-crash-analysis.json` | Mac native/software proxy: worker absent15.186s, same publisher and broadcast, archive2,124consecutive frames/gap-free audio, both output sessions decode. Live gap17.3s. Interrupted audio tail107ms; recovered ends≤36ms. Tail qualification across timing/load remains open. |
| Native worker SIGKILL after guardian pipe isolation | `headless-native-8guvcT/worker-crash-acceptance.json` | Continuity/recovery passed: archive2,125consecutive frames; both outputs62–443 then962–2104,17.267s live gap. All five MP4s decode with no within-session frame/audio gaps. Interrupted audio tail still106–107ms; recovered≤37.5ms. No general bound. |
| Remote Watch end and stream drain | `ordinary-native-q9n288` | Passed; archive and live A/V ends within 40 ms. |
| Native 4K recording | `recording-quality-20260928-media/media-acceptance.json` and `archive-source-acceptance.json` | Quality selection, actual3840×2160 archive, export/playback/relaunch;247consecutive30fps frames, no audio gaps,21.333ms A/V ends. Short recording-only qualification; no4K upload/sustained/physical claim. |
| Earlier UHD app integration (superseded for native media; UI remains separate) | `ordinary-native-z1va0e/attachments`, `production-report-timing-20260928` | Versioned report timing confirms360/720probation;1080applies after its gate. Higher admission is limited by measured padding headroom.4K gate now actually requires2160. Native archive retained; export wait was clipped by terminal test budget, corrected but not reverified. Full4K/live-media/sustained acceptance remains open. |
| 1080p production upload | `ordinary-native-PpPozK/1080-final-acceptance.json` | Native240→360→720→1080climb confirmed at6Mbps; receiver sees1077actual1080frames. Archive8518/live8260consecutive30fps frames, no audio gaps, waveform and changing score pass. Archive continues110frames. A/V ends≤34ms. Short local qualification; no4K/physical/full-match claim. |
| Native adaptive UHD and complete saved media | `headless-native-nZ4tzv/final-acceptance.json` | Normal ladder confirms4K/24Mbps;2234UHD receiver frames, no input loss. Archive9927/live9846consecutive30fps frames, gap-free audio, both3840×2160outputs and clean archive; A/V ends≤14ms. Local software proxy; headless native, not UI/physical/full-match. |
| Intermittent packet loss | `headless-native-MUpcfR/loss-acceptance.json` | Every100th datagram dropped each direction:167forward/63reverse losses. All124 dropped data events later retransmitted. Archive2,724/live2,643consecutive frames, gap-free audio, every5s window30freshfps; A/V ends≤15ms. NativeMac/software proxy,90s, same publisher. |
| Sustained native UHD | `headless-native-yFO9Hu/sustained-acceptance.json` | Normal adaptive ladder,1050s capture; receiver22,635actual4Kframes/754.5s. Archive31,534/live31,452consecutive frames, zero input/media loss, gap-free audible audio and A/V ends≤35ms. All three files decode, including the qualified600s source loop. Mac/software proxy; not physical or full-match qualification. |
| Native congestion recovery | `headless-native-44b0fy/congestion-analysis.json` | Mac native/software proxy: normal 720→240→720 recovery through 25 seconds at 750 kbps. Archive9,926/live9,844 consecutive frames, no audio gaps, all five-second windows30 fresh fps, A/V ends≤35ms. Both saved outputs decode. No production changes; earlier simulator results remain separate failures. |
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
| Mac software/VideoToolbox worker | Software proxy passes330s native adaptive UHD/media; local VideoToolbox proxy has a measured UHD/probe interaction. No blanket backend/full-match guarantee. |
| Local Linux container stack | API persistence, managed relay and software worker checks. Not external TLS/firewall/NVIDIA qualification. |
| Physical iPhone/Watch | Short paired phone/Ultra2 functional vertical and saved encoded A/V pass. Physical360p recovery confirmation failed before impairment; sustained profiles and radio handoffs remain open. |
| External hosts | Deferred; local Linux container results do not qualify remote networking or other hardware. |

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

## Current UHD qualification

`headless-native-nZ4tzv/final-acceptance.json` passes one330s native Mac workflow
with the normal240→360→720→1080→2160 ladder and software proxy. UHD confirms at270s;
2234actual3840×2160 receiver frames span about74s. No SDK/app input loss.
Native export verifies167segments; archive9927and both outputs9846consecutive
30fps source frames. All three files fully decode with gap-free audible audio;
A/V ends differ by at most13.436ms. Preview frames show a clean archive and the
proxy score overlay. Dynamic-score/Watch/UI qualification retains separate evidence.

The initial verifier rejected normal33/34ms RTMP timestamp steps. Retained packet
analysis shows at most0.667ms anchored cadence error across9846frames, with matching
consecutive source identities; correction requires no second decode. Original
failed report and corrected report are both retained.

Use the software proxy for this local UHD configuration. Bandwidth-probe warmups
reproduce native input loss when this Mac simultaneously hosts the VideoToolbox
proxy; the shared-resource cause remains unproven. Candidate-only and software
proxy comparisons pass. The iOS simulator's separate UHD encoder pending-input
limit remains explicit. Neither this short native run nor isolated encoder startup
probes qualify physical4K, all backends, or a full match.

Diagnostic history and hashes are in the [UHD session logs](session-logs/README.md).
