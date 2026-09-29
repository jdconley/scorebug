# Local fault coverage

This is retained incremental evidence, not a same-revision suite rerun or physical
qualification. September 28 audit matched 19 actual passing XCTest lines to current
test methods and assertions. The source/log hashes and exact cases are in
`artifacts/qa/fault-coverage-20260928/retained-coverage.json`.

| Contract | Evidence | Scope |
| --- | --- | --- |
| Stale, duplicate, incomplete and wrong-owner observations cannot establish health | QualityControllerTests in progressive-reset-core.log | Deterministic controller inputs; current test assertions retained |
| Minimum capacity, disconnected and stalled states remain explicit | QualityControllerTests/testMinimumProfileInsufficiencyAndOutageRemainExplicit | Model states, not a native network disconnect |
| Qualified two-second loss resets to minimum; local pressure remains distinct | ProgressiveQualityTests in progressive-reset-core.log | Controller policy |
| Fresh decoder stall resets once; old/wrong-native-owner evidence cannot reset | PublishingDecoderStallTests in continuous-delivery-agent/full-film-model-final.log | App adapter/session with controlled native receipts |
| Thermal/queue/transport pressure needs fresh enclosing history; unknown delivery cannot raise quality | PublishingQualityTelemetryTests in the same FilmModel log | Injected pressure; not real-device heat |
| Old revisions cannot accumulate health; deadline rollback preserves receipt revisions | QualityControllerTests and PublishingQualitySessionTests in those logs | Ownership/lifecycle |
| Optional probes retire on drops, stale thermal data or missing diagnostics | NativeCandidateFixtureTests/testNewDropsStaleThermalAndMissingDiagnosticsRevokeOptionalOnly | Optional measurement ownership |
| Production delivery control does not end at diagnostic retention limits | PublishingDeliverySourceWindowTests: continuous consumer and driver cases | 600 polls, more than 256 owner changes; finite audit still reports its own overflow |
| Actual native bitrate/profile boundaries and healthy media | ordinary-native-PpPozK/1080-final-acceptance.json | Full local 1080p ladder/media; not sustained 4K or physical capture |
| API/worker disappearance and recovery | ordinary-native-QOuplL and ordinary-native-SvL3gk | Real process outages; publisher's SRT connection is a separate failure mode |

## Remaining integration gaps

Native publisher failure now reconnects automatically after joined teardown and
fresh control, using the same authorized broadcast generation. Focused ownership,
backoff, cancellation and in-flight Stop checks pass. headless-native-omoEsi verifies
an actual SRT connection termination and automatic rejoin, a continuous clean archive,
and both output recordings. The measured live outage is4.567seconds. This is not
sustained packet-blackhole or physical radio-route qualification.

headless-native-WH3nME additionally verifies a25s owned relay suspension, repeated
failed native attempts and automatic restoration on the same recording/generation.
Its archive has2733 consecutive frames with gap-free audio; both destinations
resume and fully decode. Actual live gap35.5667s, interrupted audio tail108ms.
This makes both SRT and relay management unavailable; it is not an isolated packet
blackhole. See the [outage session](session-logs/2026-09-28-prolonged-relay-outage.md).

headless-native-K87zVV qualifies an isolated25s bidirectional publishing-hop packet
blackhole: real517forward/664reverse drops, zero sends during loss, repeated native
retries, same recording/generation and automatic recovery.2731consecutive archive
frames and gap-free audio; both outputs fully decode with no within-session loss.
The live gap is29.3333s. See the [session](session-logs/2026-09-28-publisher-blackhole.md).

headless-native-KJYNvL verifies combined client API/SRT loss for 25 seconds. The API
fixture rejects 366 connections and transfers no bytes during loss; SRT drops
510 forward/669 reverse packets. Native recording remains continuous (2,727 frames,
gap-free audio), generation stays 1, and publishing resumes automatically after
control returns. Both destinations decode with no within-session loss; live gap
27.233 seconds and A/V ends within 49 ms. Backend API/worker remain online. This is
scoped client networking, not physical radio loss. See the
[session](session-logs/2026-09-28-client-network-outage.md).

Intermittent loss still needs integration evidence. Severe congestion has measured
media loss; healthy periods pass. Normal adaptive UHD and complete saved media now
pass with the software proxy; sustained/backend and physical thermal/radio limits
remain open in the delivery plan.

Complete retained delivery audits are laboratory evidence requirements. Runtime
control continuing beyond their caps is already covered; do not confuse the two or
increase audit bounds to claim long-run completeness.

The audit-retention reconciliation is complete. Six retained focused checks cover
row/byte exhaustion, invalid serialization, no health from unretained rows, continued
production classification and cancellation. Current Consumer selection keeps audited
and continuous modes explicit; overflow never switches modes. Evidence/source hashes:
`artifacts/qa/uhd-boundaries-20260928/audit-reconciliation.json`. This closes the
retention/terminal-behavior TODO, not missing-audio or long-run media qualification.
