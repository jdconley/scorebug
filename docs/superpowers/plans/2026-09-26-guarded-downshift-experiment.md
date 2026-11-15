# Guarded downshift experiment

**Goal:** Test whether applying the target bitrate before replacing a downward-resolution encoder improves complete720p collapse/recovery, while preserving the clean recording and one authoritative application.

**Status:** Experiment completed and rejected. The native/controller workflow passes, but both live outputs still fail video/audio continuity during collapse. The clean archive passes. The previous production sequence is restored exactly and its17targeted restoration tests pass. No wider recovery or deployment acceptance is claimed.

## Design

Use the existing guarded application only when the profile moves downward with non-increasing dimensions, at least one smaller dimension, and a lower target bitrate. Same-profile, upward and unguarded paths retain their sequence.

Keep one application and original deadline: verified baseline receipt → preliminary target-rate write on that same encoder → replacement expecting the intermediate receipt → final verified rate on the new encoder → one Core acknowledgment. Validate generation, encoder, configuration, timing and non-regressing PTS at each boundary. Keep the intermediate receipt private; it earns no recovery credit and does not change acknowledged settings.

Track any successful native effect before further validation or suspension. A typed admission refusal before the first effect can consume the advice without stopping. After any effect, subsequent refusal, invalid receipt, cancellation, expiry or loss of ownership must join terminal shutdown. Late completion cannot stop a new owner.

## Work and acceptance

- [x] Complete and independently review native host/simulator comparisons at mutation frames180/181, retaining all failures and hashes.
- [x] Review the bounded three-stage application design and identify existing guarded fixture assumptions.
- [x] Add causal tests for eligibility, exact receipt chaining, a single deadline/ACK, initial refusal, partial effects, invalid receipts, cancellation/stop and expiry.
- [x] Implement candidate only in application/session code; retain policy, ladders, queues, archive, freshness,24fps and audio checks.
- [x] Run focused session/profile/Driver/owned-candidate tests and required Debug/Release builds. Independently review exact source before capture.
- [x] Run one fresh full720p collapse/recovery with the same verified600s source,700ms requested SRT budget and750kbps constraint. Join all builds first.
- [x] Export the actual native archive and verify all three outputs, source continuity, audio, score glyphs, negotiated delay and native/transport/geometry receipts. Preserve failed media and do not map accepted windows on failed outputs.
- [x] Reject the candidate after failed complete media verification; restore and verify the prior production sequence. Preserve all evidence and do not map failed output to accepted windows.

[Native comparison plan](2026-09-26-native-downshift-output-comparison.md) · [Session evidence](../../session-logs/2026-09-26-simulator-downshift-comparison.md)
