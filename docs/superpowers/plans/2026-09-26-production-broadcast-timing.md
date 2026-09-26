# Production broadcast timing integration

**Goal:** Let the ordinary broadcaster evaluate intact buffered video under an explicit reliability-first timing contract, then verify full720p recovery and all media outputs.

**Design:** Select existing `broadcast-reliability3000-v1` in the production quality factory. Its3000ms capture-to-decoder budget and3500ms capture-window evaluation allowance share one immutable profile across session, driver and continuous delivery classifier. The explicit strict1500 fixture benchmark remains available. Do not change250ms cadence/report freshness,1000ms no-progress detection, local-pressure age, candidate/advice expiry,30fps target/24fps floor, loss checks, transport limits or resource bounds. This changes the real app's default contract, not an offline verifier.

Three seconds is a product test budget, not a platform standard: prior clean700ms media exceeds1.5s, and this broadcast prioritizes reliable motion/audio over conversational delay. No constant delay is inserted; frames still flow as soon as ready. Upload recovery remains independently configured by the server; use explicit700ms for the next matched comparison.

**Files:** `PublishingQualityDriver.swift` selects the profile and protects timing ID/decoder budget/capture age in its bounded current diagnostic. `CaptureStreamingModelTests.swift` verifies ordinary construction reports it. `PublishingQualityDriverTests.swift` verifies the explicit strict path and diagnostic compaction retain exact timing fields. Existing Core timing/delivery tests continue checking independent freshness/expiry/stall boundaries.

- [x] Add failing tests for ordinary default timing and protected diagnostic fields; run focused app tests and retain the failure.
- [x] Set production timing to `.broadcastReliability3000`; add `timingProfileID`, `decoderBudgetMilliseconds`, `captureWindowMaximumAgeMilliseconds` to current diagnostics after other producers, protecting them during4096byte compaction. Update the Core profile comment without changing historical fixture metadata.
- [x] Run affected app tests, Core timing boundaries, Debug UI/Release builds; independently review source before committing.
- [ ] Run ordinary recovery720 with requested700ms, identical600s source/750kbps cap and unchanged finite test gates. Confirm emitted timing fields and actual ACK-bound sender-delay receipts.
- [ ] Join, collect native archive and both live recordings, replay native/transport/geometry, fully verify frame/audio/glyphs/clean archive, and map accepted windows only if all required producing checks pass. Preserve any failure under its actual contract.

This change does not claim to fix the223packet overflow or original720loss. If the new run progresses but live media remains damaged, investigate that remaining cause using the preserved phase/transport evidence and existing pacing implementation. Hardware paired acceptance remains pending Watch unlock.
