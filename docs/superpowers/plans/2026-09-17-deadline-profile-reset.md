# Deadline-triggered profile reset implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task.

**Goal:** Qualify an actual 540p-to-240p encoder transition caused by classified delivery-deadline failure, while independent1080p recording continues.

**Architecture:** Reuse the existing explicit `reset540` native transition fixture and the isolated deadline driver from `099024c`. Extend the independent verifier to bind the deadline decision, admission, native acknowledgment and compressed-frame/receiver evidence across the two profiles. Keep production automatic quality disabled and recovery credit suppressed.

**Tech Stack:** Swift/VideoToolbox, MPEG-TS/SRT, local FFmpeg proxy, Node independent evidence verifier, iOS17.5 simulator under Xcode26.2.

## Implementation and verification

- [x] Extend `scripts/native-deadline-decisions.mjs` using shared validation for minimum holds and profile resets. Add `qualifyNativeDeadlineReset({quality,audit,reports,fault,scope,format,snapshot,liveIDs})`. Reconstruct every deadline row using `qualifyNativeDeliveryDeadlines`; preserve exact decision/proof/context/receipt/time/count matching, strict thresholds, current authority, TTL and sample age. Before application require observed540p at1500000; afterward observed240p at350000 and revision1. Bind exactly one reset recommendation/application to its failure sequence and attempt. Check validUntil and bounded native completion, distinct configuration/session, profile receipts and compressed-frame transition evidence via `qualifyNativeProfileTransitions(...,{sequence:'stall540',requireFrameEvidence:true})`. Reject watchdog, skipped/failed writes, unauthorized changes and fabricated recovery. Keep existing minimum-only API behavior intact.
- [x] Add synthetic failing-then-passing verifier tests for actual acknowledgment/format binding and mutations of revision, configuration, encoder session, application sequence/attempt/expiry, action, missing transition, duplicated application, stale old-profile evidence after acknowledgment, and non-failure decisions. No frozen actual artifact is a unit fixture.
- [x] Add a native driver regression through classified deadline failure into a profile-changing owner, showing one540p-to240p application, acknowledgment/revision, unchanged failure source binding and no legacy-window credit. Parent owns Apple test processes. Retain teardown/error and explicit activation checks.
- [x] Wire `scripts/test-native-app.mjs` to the new verifier for `deadlineResets && stallReset`; remove the current early prohibition only when the verifier exists. Retain old watchdog/minimum qualification routes. Persist exact experiment configuration and the deadline decision result.
- [x] Obtain specification then quality reviews. Run targeted tests, full tooling/Core/native model suites, simulator build-for-testing and unsigned combined iPhone/Watch Release builds with Xcode26.2. Freeze source inventory before the actual experiment.
- [x] Run `SCOREBUG_TEST_DEADLINE_RESETS=1 SCOREBUG_TEST_DECODER_STALL=reset540` with the existing cadence fixture, 1500ms deadline,90s hold, blocks16 motion, slice decoding,400ms peer latency and relative pacing. Require healthy higher-profile delivery before the ownedpause; reject an unrelated earlier reset. Reconcile all raw deadlines and native/receiver transition frames, fully decode archive/live outputs, verify archive continuity/audio and join all owned processes. Preserve every previous artifact; new evidence prefix `deadline-profile-*`.
- [x] Record the measured result and remaining gates, rehash source/runtime/evidence, and commit. A successful test qualifies the downward transition only; minimum-first startup followed by qualified upgrades, controlled recovery, actual candidate cost/headroom, reconnect/soaks, physical phone/Watch and remote workers remain open.

## Fault ownership refinement

A fresh decoder sample immediately before `SIGSTOP` and another sample while the
owned decoder remains stopped now bridge the parent fault evidence to the phone's
raw cadence reports through exact context, decoder scope and PTS. Request brackets
use only the parent Node clock; phone decision times stay in the phone clock. Each
HTTP request has a200ms timeout. Pre-pause progress, report freshness and status TTL
must all remain valid at the pause; the paused anchor must match the resetting
failure's associated native stall. This prevents an unrelated earlier stall from
qualifying the reset. Failed reads before pause send no signal; failed reads during
pause still resume the exact owned decoder in `finally`, with regression tests.

## Verified result

Actual iPhone14/iOS17.5 simulator run `native-app-2ocCqq` completed with joined
cleanup and exit0. The higher profile had14 healthy one-second windows and6 healthy
two-second windows before the fault. A1.983-second owned decoder pause produced a
fully classified one-second window with30 expected frames,16 on-time frames and14
missing at measurement. One `freshFrameFloor` decision reset540p/1500000 to
240p/350000. Decoder progress was fresh immediately beforeSIGSTOP; the in-pause
sample's context, decoder scope and lastPTS exactly match the phone's associated
stall evidence. No no-progress watchdog or legacy source evaluation participated.

The actual first240p compressed frame appeared0.476seconds after the decision and
native acknowledgment followed at0.477seconds. Profile/configuration/encoder
session receipts and source frame IDs prove one transition from frame1029 to1030,
with the first new frame and complete tail decoded downstream. The higher phase
contains872 native frames; the minimum phase contains2424 native/decoded frames.
Initial receiver acquisition accounts for34 frames before the first received frame;
there is no source loss within either qualified phase. The worker's output canvas
stays240p throughout this input-resolution experiment.

The independent1080p archive finished with3686 fully decoded frames, zero source
loss and61/61 audio markers. Live output fully decoded with3262 frames and54/54
markers. The raw verifier reconciles837 reports and143 deadline windows:121 are
classified,22 remain freshness-unknown. Overlapping lanes never confer recovery
credit. All1442 tooling,385 Core and287 native model tests pass, together with ARM64
simulator and unsigned combined iPhone/Watch Release builds. Specification and
quality reviews are approved. The evidence manifest is
`artifacts/qa/deadline-profile-final-verification.json`.

Next qualify minimum-first automatic upgrades using actual encoder cost/headroom,
then recovery/oscillation and reconnect/longer soaks. This result proves an actual
downward profile reset and continuous archive, not automatic recovery, physical
phone/Watch performance or remote systems. Production automatic quality remains
disabled pending the remaining gates.
