# Candidate cost and receiver headroom implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded implementation and independent spec then quality reviews. The parent owns native runs and final evidence. The user's autonomous instruction authorizes implementation of this continuation without another approval gate.

**Goal:** Join fresh complete candidate A/V cost with repeatedly delivered optional traffic during healthy recording and streaming, as the prerequisite to measured upward trials.

**Architecture:** Reuse the candidate source window and native staged SRT probe. Compare a candidate-specific required load against receiver-confirmed padding alone; current live throughput receives no capacity credit. Preserve publication/encoder/probe identity, freshness, resource budgets and joined teardown. Keep the existing quality-controller capacity field unset until its nominal-video contract can express measured candidate admission.

**Tech stack:** Swift/VideoToolbox/SRT, MediaMTX Go patch, TypeScript status parsing, independent Node replay, iOS 17.5 simulator.

## Design and alternatives

No existing measurement supplies current live delivered media bytes aligned to probe intervals. Adding nominal live bitrate to padding would overstate evidence. Adding relay-wide delivered-media counters could eventually improve utilization, but requires a new accounting contract. Use the conservative padding-only sufficient test first; a negative result means insufficient evidence, not an upper bound on link capacity.

The laboratory IPv4 recipe compares `1.25 * 8 * (transportBytes + 44 * transportMessageCount) / min(sourceDuration, submissionDuration)` with repeated receiver padding payload-rate lower bounds. The 44 bytes follow the native probe's IPv4 UDP/SRT accounting. This is explicitly a local fixture convention, not qualification of IPv6, tunnels or unknown mobile routes. Whole-stream candidate cost includes actual AAC, keyframes, tables, timestamp headers and TS padding. Rate settings and successful native sends never count as receiver capacity.

Staged v2 probes may reach 12 Mbps to cover the measured HD candidate cost. Legacy v1 stays capped at 2 Mbps. All versions retain one pending 1,316-byte message, 16 MiB total accepted/delivered payload, 60-second campaign, 32 stages, 300-ms renewable lease, current-owner authority, and withdrawal on transport pressure. The intended combined schedule is 500 kbps, 2 Mbps, and 12 Mbps, bounded to eight wall-clock seconds per stage; nominal total is 14.5 MB before native header pacing, within 16 MiB. Prior 500k/1m/2m qualification stays reproducible. Staged wakeups may use a 0.5-ms floor (at most 2,000 callbacks/second); legacy keeps its 2-ms floor. One-token capacity and coalesced wake signals remain unchanged, so scheduling delay cannot bank a burst.

The combined fixture wraps the native probe owner with the candidate observer. Forward native startup receipts. Begin candidate sampling only when the final stage is active and locally authorized; retain that exact probe ID/generation/stage through candidate completion. Observe four seconds of raw input, complete native drain and following AAC witness, then require fresh receiver evidence before stage retirement. Use receiver age bounds to map intervals to local uptime; never compare receiver elapsed timestamps directly to uptime. Repeated intervals must be nonoverlapping, from the same stage/publication and fresh at the decision. Missing, stale, contradictory or insufficient evidence cannot authorize an upgrade.

This checkpoint qualifies a historical candidate-specific load relation only. Saved archive/live continuity and the existing source, worker and ingress replay gates must pass, but they do not establish fresh online media health at the decision. The result explicitly reports `mediaHealthQualified: false` and `upgradeAuthorized: false`. Current receiver/worker/transport, thermal and ingress health remain required for the subsequent runtime admission owner, followed by profile trials with timeout, rollback, cooldown and recovery. Independent archive remains unchanged throughout.

## Tasks

- [x] 1. Extend only staged-v2 probe ceiling consistently across native producer, relay parser, authenticated API, app snapshot validation and independent verifier. Add boundary tests for 12,000,000 accepted, 12,000,001 rejected, and unchanged v1 2,000,000/2,000,001 behavior. Exercise high-rate pacing, byte/time limits and revocation. Regenerate exact vendor patches; test real relay parser before building a fresh image tag.
- [x] 2. Add the combined fixture route and explicit rate schedule, preserving legacy fixture behavior. Test composition/startup forwarding, final-stage readiness, wrong/retired authority, stop during readiness/sampling, bounded stage duration and exactly-once joined cleanup. Add environment parsing tests in Swift and Node before implementation.
- [x] 3. Implement candidate-specific headroom evaluation and independent replay with mutation tests: real cost and message overhead, identity, clocks, stale candidate, stage replacement, duplicate/overlapping intervals, insufficient and sufficient sustained delivery. Require the existing media replay gates before this historical relation; report online media health and upgrade authorization as false. No inferred current-media capacity.
- [ ] 4. Run fresh native combined trials with independent archive/live frame identity, audio markers, source intervals, pressure, exact mux replay and sender/receiver probe accounting. Include insufficient-headroom and withdrawn-probe cases; preserve failed runs without editing their evidence. Investigate causes before changing thresholds.
- [x] 5. Obtain spec and quality review. Run affected Swift, Node, API and Go suites, simulator and unsigned phone/Watch builds, provenance and image checks. Hash source/runtime/evidence, verify prior frozen artifacts unchanged, update the main plan and commit. The subsequent milestone connects runtime admission to upward trials/recovery; keep the full goal active.

Worktree: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Apple toolchain: `/Applications/Xcode-26.2.0.app/Contents/Developer`. Heavy jobs are sequential and parent-owned. Evidence prefix `candidate-headroom-`; never rewrite earlier QA helpers, logs or manifests. No external broadcast, deployment or license acceptance.


## Checkpoint results

Two fresh combined iOS 17.5 simulator runs pass the independent replay gates:

| Candidate | Accounted A/V transport cost | Required padding delivery (25% margin) | Minimum of two delivered intervals | Archive/live saved frames |
| --- | ---: | ---: | ---: | ---: |
| 360p30 | 4.072 Mbps | 5.090 Mbps | 10.024 Mbps | 3,668 / 3,262 |
| 1080p30 | 7.405 Mbps | 9.257 Mbps | 9.770 Mbps | 3,666 / 3,261 |

Each candidate contains 121 consecutive frames over four source seconds. The
archive and live saved ranges remain consecutive at approximately 30 fps; all
expected audio markers match (61/54 and 60/54 respectively). Candidate-window
capture/publishing pressure counters do not increase. Raw evidence is retained
in `artifacts/qa/native-app-odzqIY` and `artifacts/qa/native-app-pFfywk`.

The opt-in fixture observes the same final-stage probe through native candidate
startup, each raw offer, monitoring and completion. Review reproduced cached-lease
and actor reentrancy errors. Fresh reads, lifecycle rechecks and at most three
actual re-reads after a superseding observation prevent stale admission, false
monotonic regressions and late mutation of joined proof. An uncontested regression
still revokes the optional candidate.

Task 4 is partially complete: sufficient-load native trials pass; insufficient
load, withdrawal, stale evidence and temporal mismatch are covered by automated
rejection tests. Dedicated combined native impairment/withdrawal campaigns remain
open. The fixture remains diagnostic. Neither run authorizes production upgrades
or proves current online media health, physical-device performance, unknown IP
encapsulation overhead, long-session stability or remote deployment.

Next connect a candidate-specific measured admission type to fresh online health
and the owned profile trial/rollback path. Do not put whole-stream measured cost
into the existing nominal-video `usableVideoCapacity` field. Run controlled
negative native campaigns before enabling production automatic increases.


Checkpoint verification passes 270 SDK, 398 Core, 139 Streaming, 327 native model,
480 API and 1,902 tooling tests, type checking, formatting, clean simulator and
unsigned combined phone/Watch Release builds. SDK provenance verifies all 162
original files and the exact patch round trip. The real relay parser passes its
probe suite with the Go race detector; the new image preserves the old image tag.
Spec and quality reviews approve after the reproduced timing fixes. All 4,839
prior frozen evidence files remain unchanged. Source, runtime, binary and evidence
hashes are recorded in `artifacts/qa/candidate-headroom-final-verification.json`.
