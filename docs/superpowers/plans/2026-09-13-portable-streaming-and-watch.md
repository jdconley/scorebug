# Portable streaming and native scoring delivery plan

## Goal

A complete native system: reliable clean iPhone audio/video recording; native phone
and Apple Watch scoring; adaptive SRT upload to a portable score-overlay proxy;
RTMP output to a mock YouTube endpoint that records MP4; and optional proxy-side
MP4 of the final overlaid stream.

## Requirements

- Score on the filming phone and its paired Watch, or another native phone and its
  Watch. No browser scorer or camera-permission requirement for scoring.
- Support iPhone 14 and newer, older capable devices where practical, and the current
  stable iOS generation plus two previous generations. Preserve iOS 17/watchOS 10
  deployment targets and availability checks. Include Ultra 2 and Series 7 41 mm.
- Prefer reliability across Watch Wi-Fi, cellular and paired-phone fallback. Persist
  uncertain actions and reuse command identities across retries and routes.
- Record clean local A/V independently of the network and match state. Support
  recovery, playback/export and safe storage-pressure behavior. Overlay only at the proxy.
- Start upload at minimum quality and increase with measured headroom. On sustained
  congestion/loss, return to minimum and recover cautiously. Target 30 fps; healthy
  periods must reach 24 fresh fps in 99% of rolling five-second windows. Stable
  30 fps profiles must lose less than 1% of fresh frames. Report outage/transition
  loss separately; network failure must not corrupt or stop the clean archive.
- Make the proxy portable across local/home/cloud hosts, with CPU and qualified
  hardware encoding, explicit endpoints, RTMP/MP4/both output, bounded queues,
  process recovery and secret isolation.

## Current status

| Area | Working locally | Remaining |
| --- | --- | --- |
| Native phone scoring | Create/discover/join, durable scoring/undo, takeover, end and restoration; separate scorer while filming | Sustained/physical qualification |
| Native Watch | Scoring, takeover, undo, relaunch and match end through real HTTP; 41 mm UI | Actual companion/radio routes; simulator setup fixture is not WatchConnectivity qualification |
| Clean recording | 1080p/4K selection, segmented recovery, export/playback; storage/queue/source faults;1050s native4K archive | Physical camera and full-match profiles |
| Proxy and outputs | SRT, changing score overlay, RTMP mock recorder and optional final MP4; automatic API/worker recovery; native congestion/loss and sustained4K pass | Simulator/backend limits, abrupt output tails and full-match profiles |
| Adaptive upload | Normal240→2160 ladder, minimum fallback/recovery,754.5s actual4K and complete saved media with software proxy | Other backends, physical and full-match qualification |
| Deployment | Local Mac service; persistent Linux container stack and CPU/GPU runbooks | External networking/TLS and runtime/backend qualification |

The [acceptance matrix](../../simulator-acceptance.md) owns retained results and
platform limits. [Session logs](../../session-logs/README.md) own experiments,
commands and reviews. [NEXT](../../session-logs/NEXT.md) owns the current checkout
and immediate handoff. Checkmarks mean the stated scope passes, not release readiness.

## Local feature checklist

These checks reuse retained evidence in the acceptance matrix; they are not a new
full-suite run. Local functional integration is complete on the documented paths.

- [x] Phone A records and streams while native phone B creates/joins and scores.
- [x] Native Watch scores, takes over, undoes, relaunches and ends the match through
  the real API while filming continues. Companion setup/radios remain unqualified.
- [x] Durable commands reconcile offline/lost replies and reject stale authority.
- [x] Clean archive supports recovery, export/playback, storage/queue/source faults,
  and continues after streaming stops.
- [x] SRT → changing score overlay → mock RTMP MP4, plus optional proxy MP4.
- [x] Progressive upload starts low, climbs with measured headroom, falls back under
  congestion and reconnects automatically without another Start.
- [x] API/worker restart, publisher/relay outages and periodic packet loss have
  retained recovery and saved-media evidence.
- [x] Native Mac/software-proxy 1080p and sustained adaptive 4K pass with complete
  clean archive and both final outputs. Simulator UHD limits remain below.
- [x] Relay credentials/generations, bounded telemetry and worker readiness covered.
- [x] Mac service and persistent Linux API/relay deployment wiring implemented.
- [x] Portable Linux worker image provides required encoder timing; compiled paced
  overlay pipeline decodes both FLV/MP4 outputs on local Linux arm64 Docker VM.
- [x] Linux CPU container proxy works with native Mac capture, real local SRT/RTMP,
  confirmed240→360 increase, clean archive and both final MP4s; short integration.
- [x] Hands-on simulator launcher opens two native phones and a Watch with the local
  lab, without UI automation; preserves app data and recordings after shutdown.

## Remaining local work

- [x] Keep encoder progress/telemetry writable after worker death so finalization
  cannot fail on a broken parent pipe. Guardian owns and drains those readers;
  bounded shutdown, focused process checks and a short FFmpeg comparison pass.
  This fixes pipe ownership, not the still-open live A/V tail bound.

- [ ] Bound interrupted output tails across abrupt failure timing/load. Current
  native/software-proxy crash retains 107 ms extra audio; older simulator/
  VideoToolbox outputs retain 508–548 ms. Graceful stops pass. Reuse saved output
  and inspect the responsible path before choosing another targeted reproduction.
- [ ] Resolve or explicitly gate unsupported simulator/backend combinations:
  simulator UHD pending-input limit, simulator severe-congestion media gaps, and
  colocated VideoToolbox/probe input drops. Preserve the working software-proxy
  path; no repeated parameter sweeps or larger queues to hide overload.

## Later qualification (not missing local features)

- [ ] Qualify remaining profiles/backends and full-match operation. Reuse the passed
  sustained native Mac/software-proxy UHD result; do not repeat it unchanged.
- [ ] Confirm hosted native CI when a push is authorized. Hosted builds do not
  replace local simulator/media acceptance.

## Deferred hardware and external acceptance

- [ ] Restore physical readiness and reconcile only the identified test-owned pending
  Watch pairing. Preserve Keychain and uncertain commands until ownership is known.
- [ ] Verify filming-phone/Watch and separate-phone/Watch scoring on Ultra 2 and
  Series 7: wrist lowering/reopen, Wi-Fi/cellular, paired fallback and route handoff.
- [ ] Run 10-minute 1080p30 and supported 4K30 capture, then two-hour release profiles;
  measure frames, A/V sync, heat, battery, storage, reconnect and archive continuity.
- [ ] Verify physical camera/audio interruption, lock/background, low space, forced
  termination and detached-debugger behavior; record OS/profile ceilings.
- [ ] Move unchanged proxy configuration to home/cloud hosts. Qualify actual Linux
  amd64/arm64 CPU, NVIDIA, Windows/WSL2 and other supported runtimes.
- [ ] Test external TLS/firewalls, colocated/split relay-worker layouts, private
  management, restart, credential revocation and explicit worker moves.
- [ ] With an authorized test destination/key, verify YouTube ingest/playback,
  reconnect, quality changes and glass-to-glass latency. Use the local mock by default.

## Iteration and completion policy

Simulator-first; defer hardware until simulator-testable features work together.
Batch related fixes, run one affected check after the batch, and reuse passing
evidence and incremental builds. No application tests for documentation-only work.
Run the full native vertical only after changes across component boundaries or a
meaningful feature checkpoint; do not run every runner in sequence. Use the
[fast iteration guide](../../fast-iteration.md) to select a check. Long soaks,
hardware and other-host qualification do not belong in the routine edit loop.
Use the headless native pipeline for media diagnosis. Before any new capture,
state which unresolved question it answers. Do not repeat unchanged experiments.

Preserve Downloads originals, recordings and unrelated simulators. No agents,
pushes, cloud purchases, production keys or real broadcasts without authorization.

Complete when all simulator-testable pieces work together, faults have bounded and
truthful outcomes, and documentation reflects measured capabilities. Hardware and
external configurations require their own qualification before release claims.

References: [progressive design](../specs/2026-09-16-progressive-streaming-design.md),
[ordinary recovery](2026-09-26-ordinary-recovery-integration.md),
[platform timing research](../../research/2026-09-25-live-platform-adaptation.md),
[transport budget](2026-09-26-ordinary-transport-budget.md).
