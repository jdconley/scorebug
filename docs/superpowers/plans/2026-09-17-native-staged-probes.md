# Native Staged Probe Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent probe value/budget implementation and spec/quality reviews. Parent owns stream lifecycle, integration, and sequential heavy verification.

**Goal:** Let one native SRT publication explicitly replace its optional bandwidth probe without overlapping native send authority or resetting cumulative traffic limits.

**Architecture:** Preserve the default v1 entry point. An explicit staged start emits v2 stage 1. Replacement supplies the exact current UUID, generation, and stage; the native stream chooses the next ordinal. It synchronously revokes the old probe, cancels and joins its wake owner, then rechecks publication/configuration identity after each suspension before admitting a replacement. Existing probe locks serialize cancellation with native acceptance; the single transport consumer continues to prioritize media. Each staged snapshot exposes its campaign start and total locally accepted payload for diagnostics, never as receiver capacity.

**Tech Stack:** Swift actors/locks, libsrt, MPEG-TS v2 null-packet probe protocol, Swift Testing, vendored HaishinKit patch provenance.

## Bounded qualification campaign

This step retains the existing qualification limits: 300 ms renewable stage lease, 1...2 Mbps offered traffic, at most 32 stages, 16 MiB cumulative accepted payload, and 60 seconds elapsed from first stage admission. Replacement cannot renew that campaign lifetime. Native production adaptation remains disabled. These finite qualification limits are not a complete long-session recovery policy; repeated campaigns and long-session transport behavior remain a later production gate.

## Probe value and budget

Files: `vendor/HaishinKit/SRTHaishinKit/Sources/SRT/SRTBandwidthProbe.swift`, new `Tests/SRT/SRTStagedBandwidthProbeTests.swift`.

- [x] Write failing tests for stage wire encoding/authority, stage-local sequence restarting at zero, cumulative byte exhaustion, campaign time exhaustion, malformed staged configuration, accepted-send restoration failure accounting, and legacy compatibility.
- [x] Extend the internal initializer with defaulted `stage: UInt32? = nil`, `campaignStartedAt: Double? = nil`, `previouslyAcceptedPayloadBytes: UInt64 = 0`. Legacy mode requires nil campaign and zero previous bytes. Staged mode requires generation > 0, stage 1...32, finite campaign start between 0 and stage start, elapsed < 60, canonical message-aligned previous bytes with space for one message, and stage 1 requires zero prior bytes and campaign start equal to stage start. Snapshot adds optional campaign start and cumulative accepted bytes; nil for legacy. The existing `stage` and authority are set from this locally admitted identity.
- [x] Use `encodeStage` for staged offers. Both ordinary and restoration-failure acceptance increment cumulative accounting. `check` enforces the campaign deadline and total budget. No shared mutable historical array or resettable external counter.
- [x] Run focused red/green tests with Xcode 26.2 selected. Keep SDK build ownership serialized with parent.

## Stream replacement lifecycle

Files: `vendor/HaishinKit/SRTHaishinKit/Sources/SRT/SRTStream.swift`, `Tests/SRT/SRTStreamPaddingTests.swift`.

- [x] Write red tests for staged begin and replacement, exact identity/ordinal rejection, v1/v2 separation, revoked held authority before a gated wake join, no new stage before join, cancellation/configuration/finish/close during replacement, and old acceptance included in the new cumulative snapshot.
- [x] Extend `beginBandwidthProbe(bitRate:publishingGeneration:staged: Bool = false)` to create stage 1 only when explicitly requested. Keep initial begin unavailable after any previous attempt.
- [x] Add `replaceBandwidthProbe(id: UUID, publishingGeneration: UInt64, stage: UInt32, bitRate: Int) async throws`. Validate current staged identity and available next ordinal before side effects. Reserve the existing admission guard, revoke the old owner synchronously, cancel its wake task, await its completion, and revalidate cancellation, current generation/probe identity/configuration revision/video replacement state. Capture final accepted counters after revocation, sample fresh statistics, and revalidate again before installing stage + 1 using preserved campaign origin and cumulative acceptance. A failed admission leaves the old stage terminal and can be explicitly retried against its still-current identity; successful admission never permits a replay of the old identity.
- [x] A scoped cancel increments the admission revision so it invalidates a suspended replacement. A fresh publish is blocked while an old start/replacement is pending; callers of the pending operation must join it. Close/finish immediately revoke and continue existing owned shutdown. No new publication may share an old pending probe owner.
- [x] Run targeted lifecycle tests then full SDK suite. Test helpers use gated wake/statistics hooks and real probe/stream code, with bounded waits and all handles joined.

## Integration and evidence

- [x] Regenerate only changed maintained HaishinKit patch sections against pinned upstream, verify all original hashes and exact round trip. Update README with opt-in staged API, cumulative limits, and remaining gates.
- [x] Run full SDK, streaming, Core and native model suites; ARM64 simulator and unsigned combined iPhone/Watch Release builds. No license changes or remote broadcasts.
- [x] Spec review, then quality review; resolve findings and rerun affected checks. Preserve new-prefix logs, source hashes and unchanged previous evidence. Update main plan and commit.

## Next integration gate

Expose joined replacement through both native publisher adapters and the bounded DEBUG scheduler, export cumulative sender diagnostics, then run real staged SRT media plus independent recording against the staged relay. Candidate-cost admission, automatic upward trials/recovery, long-session campaign policy, physical phone/Watch and remote-worker qualification remain open. Native SDK tests alone do not qualify these outcomes.


## Verified checkpoint

Opt-in staged native start/replacement now emits v2 and preserves campaign origin
and cumulative accepted bytes. Replacing revokes the old permit before joining its
wake owner; the native send lock accounts for an accepted in-flight message before
copying the retired total. Publication/configuration/cancellation checks reject
interrupted admissions after both suspension points. A failed replacement can be
retried against the retired current identity. A pending old admission prevents a
new publication until it returns. The default legacy path remains v1.

All 397 Core, 224 SDK, 88 streaming and 292 native model tests pass. The ARM64
simulator build and unsigned combined iPhone/Watch Release pass, including
arm64_32 in the embedded Watch executable (unchanged Watch source reused its
previously compiled target). SDK provenance verifies all 162 original hashes and exact patch replay.
Spec and quality reviews are approved. Two deliberate mutations are detected:
removing the pending-admission publish guard and dropping carried accepted bytes.
Production source was restored exactly before the full suite.

The initial streaming suite found a stale test object referencing the old internal
initializer. Cleaning that package's generated build directory and rebuilding
passes; the failed and successful logs are both retained. A restart fixture was
also corrected to await its initial media write before gating statistics, isolating
probe admission from the existing abort-on-cancelled-media-send behavior.

Evidence: `artifacts/qa/native-staged-probe-final-verification.json`. Previous frozen
evidence is unchanged. No real staged SRT/media or automatic recovery qualification
is claimed. Next expose these APIs through both publisher adapters, forward sender
campaign diagnostics, add the DEBUG repeated scheduler and run real staged relay
traffic alongside the independent archive. A production policy for full-game
repeated campaigns remains open alongside candidate-cost and device/remote gates.
