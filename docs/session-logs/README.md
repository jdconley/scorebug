# Session logs

The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns current goals, acceptance gates and all delivery checkboxes. [NEXT](NEXT.md) is the compact handoff.

## Convention

Create one `YYYY-MM-DD-short-topic.md` per work session; use a suffix if needed. Record purpose/scope, starting branch/commit, exact commands and exit/results, decisions, failures/unresolved limits, resulting commits/reviews, and concrete next steps. Link evidence without embedding long test output. Append findings to the session’s own log; do not append chronology to the main plan. Update NEXT and current plan status after the session. Never convert a failed run into a pass or infer hardware qualification from component tests.

## Index

- [September 28 faster media iteration](2026-09-28-faster-media-iteration.md) — opt-in native media diagnostics without simulator UI/export overhead.

- [September 28 UHD app integration](2026-09-28-uhd-app-integration.md) — capability-gated4K pipeline, bounded probe propagation and native integration diagnosis.

- [September 28 UHD probe protocol](2026-09-28-uhd-probe-protocol.md) — explicit bounded v4 sender/receiver support; legacy limits preserved.

- [September 28 recording quality](2026-09-28-recording-quality.md) — configurable camera/archive geometry and focused native 4K recording qualification.

- [September 28 1080p upload](2026-09-28-1080-upload.md) — production ladder extension, one native climb, true decoded geometry and complete A/V/overlay verification.

- [September 28 relay generation and healthy media](2026-09-28-relay-generation-and-healthy-media.md) — stale session/generation rejection, late reader, and retained phase acceptance.

- [September 28 buffered candidate scheduling](2026-09-28-buffered-candidate-scheduling.md) — bounded production phase alignment and focused regression.

- [September28 transport recovery budget](2026-09-28-transport-recovery-budget.md) — rejected long-buffer candidates expose source/candidate phase mismatch; bounded SRT stop fix retained.

- [September28 source recovery and Mac service](2026-09-28-source-recovery-and-mac-service.md) — live source interruption/restart, actual launchd output, consolidated simulator checkpoint and native CI.

- [September28 scoring and recording faults](2026-09-28-scoring-and-recording-faults.md) — pending-command takeover/stale rejection and one three-case native recording recovery batch.

- [September28 native lost reply](2026-09-28-native-lost-reply.md) — real native outbox restoration through lost reply/relaunch, exact durable command/receipt verification, faster UI-only runner.

- [September28 earlier pressure and crash](2026-09-28-earlier-pressure-and-crash.md) — focused sender-retention warning, existing-workflow hard-crash mode, plan reconciliation.

- [September28 minimum keyframes](2026-09-28-minimum-keyframes.md) — saved-backlog diagnosis, one rejected native congestion experiment, exact source restoration.

- [September28 backend capabilities](2026-09-28-backend-capabilities.md) — actual encoder initialization, fresh worker/output preflight, native recording independence.

- [September28 server recovery](2026-09-28-server-recovery.md) — native publishing survives API failure/restart, worker restart recovers automatically, clean archive remains continuous.

- [September28 separate Watch vertical](2026-09-28-separate-watch-vertical.md) — three native simulator workflows, three scoring identities, Watch takeover/end, clean archive and final score in both output recordings.

- [September28 bounded stream retirement](2026-09-28-bounded-stream-retirement.md) — remote Watch end preserves the stream tail; simulator A/V end mismatch reduced from454ms to under40ms with focused checks.

- [September 28 portable deployment](2026-09-28-portable-deployment.md) — repaired Compose, persistent native API/relay wiring, focused container-recreation check and CI.

- [September 26 evening device resume](2026-09-26-evening-device-resume.md) — current LAN corrected, phone automation works, fresh network probe still denied, Watch connection reset.

- [September 26 device acceptance blocker audit](2026-09-26-device-acceptance-blocked.md) — no live jobs; device prerequisites still prevent the next acceptance tests.

- [September 26 runner network setting](2026-09-26-runner-network-setting.md) — reviewed read-only phone diagnostic; Settings remains inaccessible to the bounded test and permission state is unknown.

- [September 26 paired Watch approval retry](2026-09-26-watch-approved-retry.md) — signed builds pass; unlocked Watch runner launches but UI automation initialization times out before capture.

- [September 26 measured relative pacing](2026-09-26-measured-relative-pacing.md) — configured pacing comparison with clean captured media but failed unconstrained climb.

- [September 26 separate native scorer](2026-09-26-separate-native-scorer.md) — native role separation during real phone capture and streaming.

- [September26 ordinary source-cadence pacing](2026-09-26-ordinary-source-cadence-pacing.md) — controlled integration of the existing pacer after packet-loss attribution.

- [September26 collapse packet diagnosis](2026-09-26-collapse-packet-diagnostics.md) — bounded packet evidence at the actual bandwidth-collapse boundary.

- [September26 production broadcast timing](2026-09-26-production-broadcast-timing.md) — coherent ordinary timing after clean media failed the strict benchmark.

- [September26 ordinary upload recovery budget](2026-09-26-ordinary-transport-budget.md) — isolated publishing-hop comparison after720media loss.

- [September 26 pipeline geometry correlation](2026-09-26-pipeline-geometry-correlation.md) — exact stream identity and accepted decoder-window evidence for higher-rung qualification.

- [September 26 recovery repeatability and 720p](2026-09-26-recovery-repeatability.md) — second complete ordinary recovery pass and the next native quality profile.
- [September 26 ordinary recovery](2026-09-26-ordinary-recovery.md) — causal diagnostics, first verified recovery, and the physical Watch unlock boundary.
- [September 25 ordinary recovery](2026-09-25-ordinary-recovery.md) — production upload routing, event-driven congestion qualification and longer finite media.
- [September 25 Watch readiness retry](2026-09-25-watch-readiness-retry.md) — approved prompt, bounded physical preparation retry, connection evidence and ordinary recovery prerequisites.
- [September 25 ordinary camera adaptation](2026-09-25-ordinary-camera-adaptation.md) — normal Debug/Release runtime, independent reviews and local-stack/native qualification.
- [September 25 production probe sizing and cost](2026-09-25-production-probe-cost.md) — next-profile plans, explicit transport estimate, Release verification and ordinary camera integration handoff.
- [September 25 production owned measurement](2026-09-25-production-owned-measurement.md) — Release lifecycle, bounded retries beyond laboratory limits, independent reviews and IPv4/IPv6 accounting research.
- [September 25 continuous delivery control](2026-09-25-continuous-delivery-control.md) — bounded full-match control extraction and lossless audit-storage diagnosis.

- [September 25 owned admission and probe pressure](2026-09-25-owned-admission-and-probe-pressure.md) — complete admission/application joins and reproduced smoothed-versus-current SRT queue readings.

- [September 25 native recovery and audio timeline](2026-09-25-native-recovery-and-audio-timeline.md) — completed3000/1000experiment, preserved telemetry/audio failures, and presentation-time analysis.

- [September 25 reliability profiles and paired hardware](2026-09-25-reliability-profile-and-paired-hardware.md) — coherent diagnostic timing and a fresh physical phone/Watch vertical.
- [September 25 platform streaming research](2026-09-25-platform-streaming-research.md) — published sender/viewer adaptation and reliability-first timing proposals.

- [September 25 actual relay recovery budget](2026-09-25-relay-recovery-budget.md) — real SRT relay loss/recovery comparison and native1000ms experiment.
- [September 25 reference-loss reproduction](2026-09-25-reference-loss-reproduction.md) — controlled compressed-frame loss, decoder-option checks and remux diagnostics.

- [September 25 owned measurement app integration](2026-09-25-owned-measurement-app.md) — native lease, application and retry integration with four-phase preparation.
- [September 25 progressive vertical continuation](2026-09-25-progressive-vertical-resume.md) — paired hardware retry and guarded app application ownership.
- [September 25 three-output vertical](2026-09-25-three-output-vertical.md) — proxy recording, full native simulator route, device lab and physical installation.

- [September 25 guarded SDK](2026-09-25-guarded-sdk.md) — imported checkpoint, `2aa6162`.
- [September 25 guarded adapters](2026-09-25-guarded-adapters.md) — imported checkpoint, `8947c0f`.
- [September 25 guarded Core settlement](2026-09-25-guarded-core.md) — imported checkpoint, `055b0b5`.
- [September 25 guarded PublishingSession](2026-09-25-guarded-session.md) — imported checkpoint, `b65ca7f`; both reviews approved.
- [September 25 plan cleanup](2026-09-25-plan-cleanup.md) — documentation reorganization and handoff.
- [Legacy history, readable](legacy-portable-streaming-plan.md) — older history with unknown session boundaries preserved intact.
- [Original source bytes](legacy-portable-streaming-plan-at-b65ca7f.txt) — lossless snapshot.

## Legacy provenance

Original repository path: `docs/superpowers/plans/2026-09-13-portable-streaming-and-watch.md`.
Source commit: `b65ca7fe1d58be9ac27e88a63c67867d428f1b10` (`codex/local-validation`).
Original line count: 3,206. Original SHA-256: `f8382e9b39359d1355eaa3bad469451ac21576ab0f82cc2c33217b4b60d31fe1`.

The `.txt` file is exactly the original UTF-8 bytes, without an added header. Interpret its relative Markdown links from the original path above; plain `artifacts/`, `ios/`, `scripts/`, and other code-formatted paths are repository-relative. The readable `.md` copy adds only a provenance comment and rebases relative Markdown link destinations to this folder; original prose, failures, checkbox statuses and headings remain. Historical checkpoint anchors live in that readable archive; the live plan contains no checkpoint inventory. No source date or unknown session boundary has been invented; dated headings retain only their original attribution.

The four named September 25 imports come from `docs/superpowers/plans/2026-09-25-owned-application-admission.md` at the same commit, with exact available command arrays imported from local exit records. These are checkpoint extracts, not claims about the start/end of actual sessions. Imported “next” descriptions are contemporaneous; follow NEXT for today’s order.
