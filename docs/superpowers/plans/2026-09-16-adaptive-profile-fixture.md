# Native adaptive profile recovery qualification

Continue the authorized portable streaming plan using inline TDD and bounded
read-only review. Production automatic selection remains gated by qualification.

Use an explicit receiver-validated profile-trial strategy: the existing 30-second
healthy evidence requirement, bounded trial deadline, 10-second confirmation,
sticky rollback and 60-second cooldown remain. At the current profile's maximum,
this strategy may try only the next profile's minimum; known capacity still must
cover the proposed setting. Existing bitrate-only trials keep their 10% ceiling.
No configured bitrate, achieved payload or send throughput becomes capacity.

The DEBUG simulator fixture has fixed qualified settings: 1080p30 at requested
6 Mbps and 540p30 at requested 1.5 Mbps. Prior measured structured-source payloads
were approximately 6.020 and 3.521 Mbps, respectively; requested values are not
achieved-rate claims. Pressure recommendations replace resolution using the
quality owner's joined profile/bitrate binding. Recovery trials can return to
1080p; failed trials restore 540p and wait through cooldown.

Extend existing bounded format/encoder observation to an explicit adaptive mode
with at most 17 phases/16 changes, retaining strict default three-phase behavior.
Export only after quality and publishing shutdown; no fixed transition driver runs
in adaptive mode. Record applied profile IDs and native format receipts alongside
the existing independently replayable quality telemetry.

- [x] Add red core tests for opt-in cross-profile trials, unchanged default behavior,
      pressure/unknown rollback, confirmation, deadline and capacity limits.
- [x] Implement the strategy without enabling it in production.
- [x] Add strict simulator flag validation, bounded adaptive format observation,
      native driver selection and joined evidence export, with regression tests.
- [x] Extend the native verifier to bind every profile action to actual native
      format/session/source receipts and independently replay pressure/recovery proof.
      Preserve existing source loss, frame cadence, archive and A/V gates.
- [x] Run core/model/tool checks and Apple Release build sequentially, then the
      local rate4m native experiment with at least 240 seconds holding time.
- [x] Preserve the failed experiment and validate its independent archive.
- [ ] Diagnose the receiver exit and retry path; fix causes before calling
      adaptive recovery qualified.

The proxy schedule begins at its first publisher datagram, not at the app's quality
bootstrap. This run may prove applied cap phases and pressure-driven policy behavior
separately. Do not claim cap-to-decision latency without causal clock correlation.
Actual camera thermal/storage behavior, receiver wall-clock stalls, physical
phone/Watch and remote worker installations remain separate gates.

## Implemented fixture and preflight

`SCOREBUG_TEST_ADAPTIVE_PROFILES=1` requires native quality and confirmation,
rate4m, structured blocks16 motion, processing/publication evidence, a direct
recorder and 240–600 seconds holding time. It excludes fixed540 and scheduled
profile transitions. Native launch validates its generated loopback proxy port.
The publisher wrapper observes compressed dimensions and independent encoder
callbacks; the quality driver alone requests replacements. Capture teardown joins
quality and publishing before closing and exporting bounded format evidence.

The format verifier retains exact session/receipt/source boundaries, per-phase
99% source coverage, 24fps five-second cadence, and full initial/final phase tails.
Only an intermediate 1080p trial that rolls back may be shorter than 15 seconds
(one-second minimum); startup, reduced and recovered phases still need 15 seconds.
The policy verifier independently replays raw pressure and receiver windows,
matches every action to a qualified format receipt, and requires a pressure-driven
decrease plus a confirmed recovery ending at 1080p. It does not infer bandwidth
from bitrate receipts or native frame dimensions.

Review exposed two verifier gaps, both reproduced as missing exceptions in
`artifacts/qa/adaptive-profile-review-red.log`: a bitrate boundary beyond its
native phase tail and a timeout rollback whose native profile acknowledgment
preceded expiry while the follow-up bitrate acknowledgment followed it. Both are
now rejected. Positive five-phase regressions cover pressure and timeout rollback,
cooldown, retry and confirmation; early retries and wrong baselines fail. Review
approved the corrected checks and found no runtime strategy/lifetime blocker.

Preflight passes 284 core, 200 app-model and 933 tooling tests, plus the unsigned
combined iPhone/Watch Release build, with heavy workloads run sequentially using
Xcode 26.2. Reproduce the native experiment with:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer SCOREBUG_TEST_RELAY_PUBLICATION=1 SCOREBUG_TEST_WORKER_PROCESSING=1 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_MOTION_FIXTURE=blocks16 SCOREBUG_TEST_STREAM_HOLD_SECONDS=240 SCOREBUG_TEST_NATIVE_QUALITY=1 SCOREBUG_TEST_NATIVE_CONFIRMATION=1 SCOREBUG_TEST_UPLINK_PROFILE=rate4m SCOREBUG_TEST_ADAPTIVE_PROFILES=1 pnpm test:native-streaming
```

## First pressure experiment: archive passes, live recovery fails

`native-app-TffI7s` on iPhone 14 / iOS 17.5 failed live qualification. The
controller applied a pressure-driven 1080p → 540p replacement approximately
61.6 seconds after quality bootstrap. Independent native evidence retained 8341
frames (1850 at 1080p, 6491 at 540p), no raw-video queue drops, and a maximum
source timestamp gap of 1/30 second in each phase. No recovery trial ran: the
worker lost usable receiver evidence. These facts do not qualify live frame delivery.

The first worker pipeline ended after 1767 decoded frames with telemetry EOF and
encoder exit 0. Later pipelines decoded no frames and exited 195. The one-shot
RTMP fixture recorder closed naturally after the initial pipeline; its design
cannot accept another connection, so it cannot exercise retry recovery. The cause
of the initial decoder exit is unresolved. Raw FFmpeg stderr and ingest logs were
not retained; do not infer a cause from exit codes alone or relax media gates.

The proxy completed its unlimited → 4 Mbps → unlimited schedule and continued
forwarding traffic, with 1065 overflow packets during the cap. Schedule and
conservation qualification passes independently of failed media recovery.

The app stopped and exported its clean local recording normally despite the live
failure. Full A/V decoding, every-frame barcode/cadence checks, archive counters,
and finalization attachment verification pass: 8712 consecutive frames (0–8711)
at 1920×1080 / 30 fps, 290.4 seconds, zero rejected/dropped archive samples,
145/145 audio markers aligned (maximum absolute offset 0.0209 ms), and 9.33 ms
A/V tail difference. See `finalized-failure-analysis.json` in the run artifact.
This is simulator-source evidence, not camera/thermal or physical-device proof.

Next add bounded, credential-free receiver diagnostics to distinguish the first
input termination from the later unavailable output listener, then repeat the
same pressure experiment. Preserve all existing recovery and media gates.
