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
| Clean recording | 1080p/4K selection, segmented recovery, export/playback; storage, queue and source fault recovery | Sustained/physical capture profiles |
| Proxy and outputs | SRT, changing score overlay, RTMP mock recorder and optional final MP4; automatic API/worker recovery | Severe-congestion loss, abrupt output tails and sustained profiles |
| Adaptive upload | Normal240→2160 ladder and saved4Kmedia verified locally with software proxy; minimum fallback/recovery retained | Sustained/backend qualification and remaining fault matrix |
| Deployment | Local Mac service; persistent Linux container stack and CPU/GPU runbooks | External networking/TLS and runtime/backend qualification |

The [acceptance matrix](../../simulator-acceptance.md) owns retained results and
platform limits. [Session logs](../../session-logs/README.md) own experiments,
commands and reviews. [NEXT](../../session-logs/NEXT.md) owns the current checkout
and immediate handoff. Checkmarks mean the stated scope passes, not release readiness.

## Completed local workflows

- [x] Native phone A records/streams while phone B creates, joins and scores without
  capture permission; archive/export and both changing-overlay outputs verified.
- [x] Separate native Watch takes over, scores/undoes, relaunches and ends the match
  while filming continues; real HTTP with explicitly limited simulator setup.
- [x] Lost-reply/offline relaunch and pending-command takeover/stale rejection retain
  exactly one intended durable outcome per command.
- [x] Clean archive recovery/export through source interruption, storage shortage and
  writer pressure; forced-termination/relaunch and playback coverage retained.
- [x] Automatic API/worker restart and hard worker-crash recovery preserve the archive;
  fresh recording/broadcast after source failure succeeds.
- [x] Graceful remote match end and bounded publisher stop preserve final A/V tails.
- [x] 1080p measured upload ladder and healthy periods around congestion meet media
  criteria. Local recording continues after streaming stops.
- [x] Native 4K recording/export/playback and bounded UHD probe protocol implemented;
  source/output capability gating preserves the 1080 ceiling when unsupported.
- [x] Relay credential isolation, revocation, generations, admission drain and late
  current-reader decoding pass local checks.
- [x] Worker readiness/backend/output reporting, local Mac service operation and
  persistent VPS Compose wiring pass their local checks.
- [x] README, architecture, runbooks and platform matrix reconciled; path-filtered
  native CI added alongside existing server/relay/worker/container checks.

## Remaining local work, in order

- [x] Implement automatic native-publisher reconnection bound to the active recording
  and authorized broadcast. Fresh control, bounded retries and Stop/ownership guards
  pass; an actual SRT disconnect rejoins without another broadcast Start. Clean
  archive remains continuous and both outputs resume; measured live gap is reported.
  Prolonged25s relay suspension also recovers across failed retries, with a continuous
  archive and35.5667s live gap.

- [x] Verify normal local adaptive4K with clean archive and both final MP4 outputs.
  Software proxy passes330s, including74s of actual4K/24Mbps; no source-frame/audio
  gaps and A/V ends≤14ms. Static overlay is visually checked; dynamic scoring has
  separate simulator evidence. Sustained/backend limits remain tracked below.
- [x] Qualify native local congestion recovery with actual decoded media: Mac native
  capture/software proxy passes a 25-second 750 kbps collapse, normal minimum reset
  and return to 720p, with no video/audio gaps and 30 fresh fps throughout.
  Earlier simulator media failures remain backend limits, not retroactive passes.
- [x] Verify retained deterministic stale-report/no-progress, ownership/revision,
  thermal/queue-pressure and continuous-control coverage in the
  [local fault matrix](../../local-fault-coverage.md). Native1080 boundaries/media
  retain their separate integration pass; physical pressure is not simulated proof.
- [x] Verify isolated publishing-hop packet blackhole and restoration:25s bidirectional
  loss, repeated retries, same broadcast and continuous clean archive; both outputs
  recover with29.3333s measured live gap.
- [x] Verify combined client API/SRT outage and restoration: 25 seconds offline,
  continuous clean archive, same broadcast, automatic recovery and both MP4 outputs.
  Measured live gap 27.233 seconds; physical radio routes remain deferred.
- [x] Verify periodic packet-loss recovery: every100th datagram lost in both
  directions, all dropped data repaired, continuous archive/live30fps and gap-free
  audio in both outputs. Short nativeMac/software-proxy qualification.
- [x] Reconcile optional delivery-audit retention/terminal coverage: production uses
  continuous bounded-state monitoring; selected finite audits report overflow and
  cannot return health for unretained rows. Row/byte/serialization terminal behavior
  and runtime monitoring beyond audit caps have retained focused passing evidence.
  Missing live audio remains a separate media failure; limits are unchanged.
- [ ] Bound interrupted output tails across abrupt failure timing/load. Graceful stops
  pass; hard-crash interrupted outputs can retain about half a second of extra audio.
- [ ] Qualify sustained local profiles/backends beyond the short UHD run. Resolve or
  document the colocated VideoToolbox/probe limit, simulator congestion loss and UHD ceiling;
  preserve the working software proxy path. Full-match qualification remains open.
- [ ] Confirm hosted native CI when a push is authorized. Hosted builds do not replace
  local simulator/media acceptance.

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
Batch related fixes, run focused checks, reuse passing evidence and incremental
builds, and run broad integration only at workflow checkpoints. Use the headless
native pipeline for media diagnosis. Do not repeat unchanged failing experiments.

Preserve Downloads originals, recordings and unrelated simulators. No agents,
pushes, cloud purchases, production keys or real broadcasts without authorization.

Complete when all simulator-testable pieces work together, faults have bounded and
truthful outcomes, and documentation reflects measured capabilities. Hardware and
external configurations require their own qualification before release claims.

References: [progressive design](../specs/2026-09-16-progressive-streaming-design.md),
[ordinary recovery](2026-09-26-ordinary-recovery-integration.md),
[platform timing research](../../research/2026-09-25-live-platform-adaptation.md),
[transport budget](2026-09-26-ordinary-transport-budget.md).
