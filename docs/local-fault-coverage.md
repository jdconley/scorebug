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

A native publisher failure currently detaches the publisher, schedules an owned
broadcast stop and displays a manual Retry message. API/worker recovery does not
prove automatic reconnection after the filming device loses its SRT connection.
This is an implementation gap for the total-network-outage workflow, not another
missing test of already working automatic recovery.

Real packet loss/total network outage and restoration still need their own native
integration evidence. Severe congestion has measured media loss; healthy periods
pass. The recent 4K run reaches actual 4K input, then correctly rejects probation
on observed pre-receiver frame loss. Exact local drop origin and sustained 4K
performance remain unqualified. Physical thermal/radio behavior stays deferred.

Complete retained delivery audits are laboratory evidence requirements. Runtime
control continuing beyond their caps is already covered; do not confuse the two or
increase audit bounds to claim long-run completeness.
