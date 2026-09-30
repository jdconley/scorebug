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
| Native Watch | Scoring, takeover, undo, relaunch and match end through real HTTP; 41 mm UI; physical Ultra2 companion setup and scoring while paired phone captures | Physical route handoffs, Series7 and sustained qualification |
| Clean recording | 1080p/4K selection, segmented recovery, export/playback; storage/queue/source faults; physical60m26s4K/audio recovered with continuous encoded A/V; long-archive memory fix | Confirm fixed phone stop/recovery/export; fresh-motion/sync and full-match profiles |
| Proxy and outputs | SRT, changing score overlay, RTMP mock recorder and optional final MP4; automatic API/worker recovery; hour physical outputs fully decode and meet encoded cadence | Distinguish cap omissions from overload; simulator/backend limits, abrupt tails and full-match profiles |
| Adaptive upload | Normal240→2160 ladder, minimum fallback/recovery,754.5s actual4K; physical240→1080p/6Mbps; hour decoded1080 input14m20s total | Receiver-proof resets, cap-omission false pressure, serious phone heat; sustained/fallback qualification and other backends |
| Deployment | Local Mac service; persistent Linux container stack and CPU/GPU runbooks | External networking/TLS and runtime/backend qualification |

The [acceptance matrix](../../simulator-acceptance.md) owns retained results and
platform limits. [Session logs](../../session-logs/README.md) own experiments,
commands and reviews. [NEXT](../../session-logs/NEXT.md) owns the current checkout
and immediate handoff. Checkmarks mean the stated scope passes, not release readiness.

## Local feature checklist

These checks reuse retained evidence in the acceptance matrix; they are not a new
full-suite run. The current two-phone/Watch simulator checkpoint after DTS
interleaving passes all native workflows and full saved-media checks; see the
acceptance matrix for its cleanup reconciliation and exact scope.

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

## Immediate delivery checkpoint

The short physical paired-phone/Ultra2 vertical also passes at240p upload: real
companion setup, Watch scoring/undo/end, clean1080p recording/export and both
changing-overlay MP4 outputs. Physical adaptive recovery remains open.

The core simulator vertical is available now: two native phones, a native Watch,
clean recording/export, adaptive SRT, changing score overlay, mock RTMP MP4 and
optional proxy MP4. Use the [hands-on launcher](../../fast-iteration.md#hands-on-simulator-session)
with the software proxy and a prepared 1080p source. Reuse the current accepted
recordings; no fresh full-suite run is needed to demonstrate these features.

Keep these boundaries explicit during local use:

| Configuration | Delivery status |
| --- | --- |
| iPhone/Watch simulators, 1080p fixture, software proxy | Core functional vertical accepted; available for hands-on use |
| Physical iPhone16Pro/Ultra2, software proxy | Short paired recording/scoring/output workflow and saved encoded A/V pass at240p upload; adaptive recovery unqualified |
| Native Mac publisher, software proxy, adaptive UHD | Retained sustained media pass; does not qualify simulator UHD |
| Simulator UHD | Not accepted: encoder pending-input limit; failed candidates retain the applied profile |
| Simulator severe congestion | Not accepted for continuous live media: saved video/audio gaps; archive and recovery pass |
| Colocated VideoToolbox proxy plus bandwidth probes | Not accepted: measured publisher input drops; use the software proxy locally |
| Abruptly interrupted output tails | Current native and simulator/software-proxy regressions pass100ms; other timing/load/backends remain open |

These are delivery/qualification boundaries, not new hard-coded product ceilings.
Do not silently disable capable devices or label the failed configurations green.
Do not make an AMD64 image smoke check, another soak, or a hardware availability
probe a prerequisite for using the accepted simulator workflow.

Next implementation work must address an observed functional failure in that
workflow or a specific open fault below. For each fault, state a bounded hypothesis
and use saved evidence or a minimal reproduction; do not automatically start another
full capture. Physical testing has resumed with the supplied phone, Watch and TV volleyball footage; remote-host work remains deferred.

## Remaining local work

- [x] Bound archive recovery/assembly memory independently of payload size; retain
  checksum, path and corruption guarantees. Focused regressions and real-hour Mac
  replay pass; current signed iPhone build installed.
- [ ] Confirm fixed phone recovery/export of the preserved hour recording, then a
  short stop check. Preserve originals and interrupted status; no new hour required.
- [ ] Separate intentional proxy timestamp-cap omissions from resource overload.
  Replay the single-omission healthy window against the stated frame-loss target;
  preserve meaningful capture/delivery/processing pressure checks.
- [ ] Log exact receiver-proof unavailability/revocation reasons and resolve
  unnecessary resets while preserving real authority/context-change guards.
- [ ] Isolate phone thermal load after adaptation faults are addressed; measure
  capture/encoding/probe load and charging conditions. Keep serious/critical fallback.


- [x] Keep encoder progress/telemetry writable after worker death so finalization
  cannot fail on a broken parent pipe. Guardian owns and drains those readers;
  bounded shutdown, focused process checks and a short FFmpeg comparison pass.
  This fixes pipe ownership, not the still-open live A/V tail bound.

- [x] Bounded packet-tail diagnostics survive worker death and locate incoming versus
  outgoing A/V track ends; one live crash boundary is measured.

- [x] Interleave dual-track publisher PES by decode timestamps with finite retention
  and lossless clean drain; SDK checks and one short native crash/media run pass.

- [x] Recheck the known simulator/software-proxy crash regression after publisher
  interleaving. Current API/worker crash workflow passes; all six interrupted and
  recovered output files fully decode with at most60ms A/V end offset, within the
  unchanged100ms gate. Current native short crash also passes at59ms. Historical
  107ms/native and508–548ms/simulator failures remain retained, not current passes.
- [ ] Qualify interrupted output tails across remaining failure timing/load and
  backends. The current targeted passes are not a general bound. Do not repeat
  those same runs unchanged or widen the100ms gate.
- [x] Explicitly gate unsupported simulator/backend combinations in the immediate
  delivery checkpoint (qualification boundaries, not product capability ceilings):
  simulator UHD pending-input limit, simulator severe-congestion media gaps, and
  colocated VideoToolbox/probe input drops. Preserve the working software-proxy
  path; no repeated parameter sweeps or larger queues to hide overload. Resolving
  these failures remains part of the backend/profile qualification below.

## Later qualification (not missing local features)

- [ ] Qualify remaining profiles/backends and full-match operation. Reuse the passed
  sustained native Mac/software-proxy UHD result; do not repeat it unchanged.
- [ ] Confirm hosted native CI when a push is authorized. Hosted builds do not
  replace local simulator/media acceptance.

## Hardware and external acceptance

Current hour qualification failed sustained1080 and physical stop/export. The
preserved60m26s4K/audio recording recovered on Mac and both final overlaid outputs
fully decode; encoded cadence meets the24fps rolling-window target. The archive
memory defect is fixed and installed, with device recheck pending. Reuse this saved
recording and focused evidence before another soak. Current fault tracking is above;
exact results belong in the acceptance matrix and session log.

Physical phone automation and the app-loopback control route work. A short TV
volleyball capture produced a clean1080p archive and both overlaid MP4 outputs;
all fully decode with continuous encoded video/audio. Physical240→360→720→1080p
now confirms at6Mbps after correcting fair-temperature classification and redundant UI updates. The receiver decoded
1254 actual1080p frames at30fps. An earlier intermittent sender-retention warning
needs longer-run diagnosis; physical adaptive recovery remains unqualified. Watch
saved-setup inspection and normal expiry reconciliation pass, as does paired
Watch scoring/undo/end during real camera capture. Both output recordings visibly
carry the Watch score changes; archive/export and encoded A/V checks pass. See the current session
log and acceptance matrix for evidence and limits.

- [x] Fix fair-temperature misclassification and high-frequency telemetry redraws;
  retain full-rate control checks and serious/critical thermal fallback.
- [x] Confirm real physical1080p upload at6Mbps through the normal adaptive ladder.
- [ ] Qualify sustained physical1080p and fallback/recovery after the current
  proof-reset, cap-omission and heat faults are resolved; inspect
  bounded sender-buffer gauges if the retention warning recurs. Keep measured
  headroom/frame gates.
- [x] Restore Watch automation readiness and reconcile only the identified test-owned pending
  Watch pairing. Preserve Keychain and uncertain commands until ownership is known.
- [x] Short physical filming-phone/Ultra2 setup, takeover, point, undo, away point,
  match end, independent archive/export and both recorded score overlays.
- [ ] Verify sustained filming-phone/Watch and separate-phone/Watch scoring on Ultra 2 and
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

Simulator-first; the core simulator vertical now passes and the user has supplied
hardware for targeted physical acceptance. Prioritize functional
failures over additional qualification of already-passing paths.

Batch related fixes and run one affected check after the batch. Reuse passing
recordings, diagnostics and incremental builds. No application tests for docs-only
work; no broad suite after a focused pass unless a new failure or shared-contract
change warrants it. Use the [fast iteration guide](../../fast-iteration.md).

Run the full native simulator vertical at a finished feature checkpoint or after
changes across component boundaries. Keep hardware, other-host qualification and
long soaks out of the edit loop. Simulator runtime limits and native media results
must remain separately labeled; neither is evidence that the other passes.

Before a new capture, identify the unresolved question and why saved evidence
cannot answer it. Prefer a model replay or isolated reproduction. Do not repeat
unchanged experiments, tune queues to conceal overload, or spend another batch
reconfirming a known platform limit. Record the actionable result and move to the
next unresolved delivery item.

Preserve Downloads originals, recordings and unrelated simulators. No agents,
pushes, cloud purchases, production keys or real broadcasts without authorization.

Complete when all simulator-testable pieces work together, faults have bounded and
truthful outcomes, and documentation reflects measured capabilities. Hardware and
external configurations require their own qualification before release claims.

References: [progressive design](../specs/2026-09-16-progressive-streaming-design.md),
[ordinary recovery](2026-09-26-ordinary-recovery-integration.md),
[platform timing research](../../research/2026-09-25-live-platform-adaptation.md),
[transport budget](2026-09-26-ordinary-transport-budget.md).
