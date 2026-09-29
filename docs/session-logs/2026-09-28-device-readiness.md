# September 28 — quality admission audit and device readiness

Starting4d7ab9b, clean. Previous goal turn made concrete progress: Linux container
adapter and real native SRT/RTMP/three-recording integration pass. No lab/test jobs
were active.

Inspected current CaptureStreamingModel capability gates, PublishingQualitySession
owned retirement, QualityController.settleCandidateMeasurementFailure and existing
QualityOwnedCandidateMeasurementTests. Failed measurement settles only its joined
owner, keeps applied settings, clears stale health/readiness, increments the bounded
failure episode and requires fresh health/backoff. UHD worker output is eligibility,
not a capacity promise. No evidence justifies inventing a hard-coded simulator cap
or modifying queues. Existing test evidence is retained; no unchanged test rerun.
This review does not close simulator throughput or general abrupt-tail gates.

The local functional workflows now support advancing to real device validation.
Read-only `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcrun
devicectl list devices --timeout 15` exited0. Physical iPhone16Pro and Ultra2 both
show unavailable. Three owned manual simulators remain connected; unrelated devices
were untouched. No signing, install, automation, passcode request or Keychain change
was attempted. An existing readiness request is pending; do not duplicate it.

Replaced accumulated NEXT history with a compact current handoff, preserving all
open plan gates and links to exact session/evidence files. This prevents stale
next-action instructions from causing repeated tests. No production code changed.
No lab/test jobs active. Goal remains active; hardware unavailability is not a claim
that the whole project is blocked or complete.
