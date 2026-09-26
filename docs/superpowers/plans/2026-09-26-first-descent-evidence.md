# First-descent evidence implementation plan

**Goal:** Capture the successful first downshift's cause, admission and native-write timing so the observed early packet overflow can be located relative to actual control work.

**Status:** Implementation and host checks complete; independent reviews complete; fresh capture pending. This is diagnostic work, not a new recovery policy or media acceptance.

**Architecture:** Retain at most16successful application records of at most8192encoded bytes each in a DEBUG ordinary-session audit. Reuse the existing applied-transition fields, adding timing fields only to the audit copy. Export once after joined native shutdown to an attempt-specific QA file. Release keeps a nil exporter; normal policy, UI4096byte limit, polling, queues and capture remain unchanged. No file writes during capture.

Full512-event Driver history would overflow early at100ms sampling and adds unnecessary history. A second protected UI record consumes the fixed UI budget and still depends on polling. The bounded successful-application audit directly captures all accepted revisions, including the currently missed first descent. It does not claim coverage of failed or unacknowledged native effects.

## Contract

File `Scorebug/QA/quality-transitions-<lowercase-attempt-UUID>.json` uses formatVersion1, scope `successful applications only`, attemptID, timingContract (scope `ordinary-successful-applications`, explicit budgets for every profile), maximumRecords16, maximumRecordBytes8192, closed:true, overflow and records. Each record retains the current applied-transition string dictionary plus admittedAt, completionDeadline, optional profileRequestedAt, and rateRequestedAt. Existing fields include cause evaluation `at`, profileNativeAt, nativeAt, ackAt, application/revision/attempt IDs and exact source boundaries. Use the injected uptime only for observational request timestamps when an audit is enabled; do not mutate the authoritative policy clock or add native awaits. Reject oversize records by setting overflow while preserving the prefix. Missing, open, overflowed or inconsistent evidence cannot pass the offline verifier.

A default-nil `appliedTransitionExport` callback on both session initializers is ignored in Release. DEBUG production factory supplies the file exporter. Tests inject an in-memory exporter. Successful records are appended only after the existing Core ACK. All stop callers join the same shielded native-stop-and-export task; export is once, after native shutdown, even if the caller cancels. Use an immutable snapshot when closing so a retired application cannot append to exported evidence.

## Implementation and verification

- [x] Add causal tests in `ios/FilmModelTests/PublishingQualitySessionTests.swift` and new `PublishingAppliedTransitionAuditTests.swift`: early record survives later ACKs/UI refresh; no record before ACK or on rejected work; exact admission/request/native/ACK fields; limits/oversize/overflow; no export before native stop joins; concurrent/cancelled stop exports once; nil exporter preserves existing behavior.
- [x] Add DEBUG `ios/Sources/Scorebug/Capture/PublishingAppliedTransitionAudit.swift`; wire default-nil exporter in `PublishingQualitySession.swift` and DEBUG ordinary factory in `PublishingQualityDriver.swift`. Regenerate ignored Xcode project with `xcodegen generate --spec ios/project.yml`.
- [x] Implement `scripts/applied-transition-audit.mjs` plus meaningful negative tests: bounds, canonical IDs/revisions/times, attempted-vs-completed distinction, source continuity, same attempt and agreement with every sampled existing applied-transition object. Return diagnostic analysis only, never media qualification. Local comparison binds first descent to the captured constrain request's native-clock interval.
- [x] Run focused host tests with Xcode26.2, project `ios/Scorebug.xcodeproj`, scheme `ScorebugFilmModelTests`, destination `platform=macOS`, DerivedData `ios/DerivedData/FilmModel`, ad-hoc signing. Run Node verifier tests, unchanged UI-budget tests, Release build and independent review of exact blobs.
- [ ] Run one fresh ordinary720p campaign with the verified600s source,700ms requested upload budget and750kbps constraint. All builds must join before capture. Collect the new audit from preserved app data; independently reconcile with native phase evidence and packet timeline. Preserve full media failures; never relabel prior runs or map failed output to accepted windows.
- [ ] Use first-descent evidence to choose the next intervention. Prioritize an actual physical-phone collapse comparison when unlocked. Do not repeat unsupported simulator low-latency/frame-delay properties.
