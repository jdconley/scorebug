# Native Mac rate-control comparison

> **For agentic workers:** Use superpowers:executing-plans inline with test-driven qualification changes.

**Goal:** Determine whether the shared encoder path achieves controlled bitrate reductions on this Mac's native encoder, compared with retained simulator evidence.

**Architecture:** Compile the existing isolated encoder fixture as a separate macOS test target. Run only the existing controlled 6 Mbps → 1.5 Mbps → 6 Mbps / fresh 1.5 Mbps experiment, with identical 1080p pixels and paced 30 fps. Preserve simulator report versions and tests. A distinct version 9 identifies native Mac evidence and requires actual 1080p output and a positive native hardware-acceleration readback. No production settings, transport or recording behavior changes.

**Tech Stack:** XCTest, VideoToolbox, XcodeGen, existing Node scalar evidence qualifier.

The prior simulator runs accept rate properties but exceed them. Native macOS selects
Apple's hardware encoder through the existing production settings. Using that path
is a platform comparison, not a claim that macOS and iOS implementations are identical.
The probe must retain encoder ID/property readbacks, every source/configuration join,
actual bytes, submission timing, native failures and joined teardown. A successful
experiment may still show ineffective rate control; no decrease is presumed.

Alternatives were another simulator property guess or immediately adding smaller
profiles. Neither distinguishes environment support from shared-path behavior.
The existing Mac avoids waiting for the currently unavailable physical-device DDI.

- [x] Add a failing version 9 qualifier test using the existing valid report fixture,
      then reject wrong platform/experiment, missing hardware proof and wrong actual
      dimensions. Preserve old reports unchanged.
- [x] Add `ScorebugEncoderMacQualificationTests` target/scheme in `ios/Project.yml`,
      reusing `EncoderPayloadTests.swift`, `NativeEncoderSnapshot.swift` and the two
      fixture source files. Initially enable `testControlledRatesAndFreshLowEncoder` on
      macOS and emit version 9/native platform evidence there.
- [x] Extend `scripts/test-encoder-payload.mjs` with one exclusive `--native-mac`
      mode: no simulator allocation, `platform=macOS` destination, exact selector,
      separate artifact prefix, unchanged report bounds and owned process cleanup.
- [x] Add strict version 9 validation in `encoder-payload-qualification.mjs`; use
      actual native dimensions and hardware readback, not inferred platform labels.
- [x] Run red/green tooling tests, native Mac diagnostic and full tooling suite.
      Independently re-sum settled payload windows and confirm source hashes.
- [x] Record the result and its limited scope, update the main plan and commit.

Acceptance: 2,402 joined scalar frame records across two native sessions; all existing
pacing/session/configuration gates; both before/after snapshots bound to each session;
actual 1920×1080 H.264 output; explicit hardware true; native test and teardown exit 0.
Report observed phase rates and low/high ratios without labeling them network capacity.
If the Mac meets requested load, proceed to native Mac adaptation qualification and
keep simulator-dependent bitrate conclusions separate. If it also fails, use the
native statuses and measured output to choose the next bounded diagnosis.

## Evidence-driven follow-up

The first native Mac run confirms hardware encoding (`ave.avc`, hardware=true) but
still produces 5.659 Mbps after a 1.5 Mbps live request and 4.936 Mbps in a fresh low
session. This rules out an explanation confined to the simulator. Native frame
coverage and pacing qualify; this is not a bandwidth pass.

Use the existing fresh low-latency comparison on the same native Mac target as
a second bounded experiment. Version10 retains the version 5 ordered default/true
request pair and adds macOS identity, hardware proof and actual dimensions. The
exclusive runner argument is `--native-mac-low-latency`. Unsupported native creation
or missing frames remain failures with raw evidence preserved. The default scene,
rate, duration and unchanged production factory remain the baseline.

- [x] Add failing version 10 qualifier regressions, implement the explicit native
      mode and run the actual comparison after the baseline joins.
- [x] Replay retained simulator evidence and compile the original simulator test
      target to verify the added Mac modes preserve the existing diagnostics.

The native low-latency attempt (`encoder-native-mac-low-latency-GO9om3`) creates
`com.apple.videotoolbox.videoencoder.h264.rtvc`, but verified rate application fails
with `codecFailed(status: -12900)` before the paced phase. Its retained bootstrap
snapshot reports DataRateLimits unsupported and hardware status unavailable. Keep
version 10 rejected; do not infer that this encoder is hardware accelerated.

Next use a separate version 11 (`--native-mac-average-only`) to compare the unchanged
default session against the low-latency session with DataRateLimits explicitly nil.
The maintained verified setter already supports that configuration. Preserve
AverageBitRate readback, source/session/timing and actual-byte checks. Require
the default's hardware proof; preserve the low-latency encoder's actual status
without claiming hardware. Its unsupported DataRateLimits readback is explicit
and required in this platform-specific experiment; older protocols remain strict.
No production/vendor changes.

## Verified outcome

- Baseline `encoder-native-mac-QrOxha`: 2,402 consecutive joined frame records,
  native `ave.avc` hardware=true before and after both sessions. Measured settled
  phase means: 6.0077, 5.6591, 5.9996 and 4.9356 Mbps for requested 6, 1.5, 6 and
  fresh 1.5 Mbps. Every actual encoded frame is 1920×1080; native property readbacks
  match requested values. This passes evidence qualification, not the low-rate goal.
- Low-latency `encoder-native-mac-low-latency-GO9om3`: rejected with native
  `codecFailed(status: -12900)`. The selected `h264.rtvc` encoder does not expose
  DataRateLimits. Its default comparison retains 601 frames; low-latency retains
  one bootstrap frame and no successful rate receipt.
- Average-only `encoder-native-mac-average-only-mBkLHK`: the supported average
  setting is accepted and produces a rate receipt, but encoding fails with
  `codecFailed(status: -1)` after one retained bootstrap frame. This is also
  rejected. The current error latch does not distinguish every callback failure
  cause; this result alone does not prove dropped-frame cause or hardware use.
- All 1,195 tooling tests pass. The original iOS simulator encoder test target
  builds successfully. Five retained simulator runs and the native baseline replay
  with unchanged measured phases. Both failed native experiments remain rejected.
- An independent Python audit re-sums the baseline's 12 settled windows, verifies
  all frame identities/timestamps/dimensions and native session bindings, and
  rejects 10 damaged evidence variants. The audit agrees with the measured rates.

Raw reports, XCTest bundles, source inventories per experiment, failed logs and
final verification are retained under `artifacts/qa/mac-rate-*` and the three
named run directories. `mac-rate-final-verification.json` hashes this checkpoint's
source and evidence. Every parent process has joined; expected failed experiments
are recorded separately from successful regression checks.

No production codec, archive, transport or adaptation defaults changed. The hard
synthetic blocks16 scene is retained; this does not establish camera-scene quality,
network capacity or physical iPhone behavior. Automatic adaptation remains gated.

Next bounded diagnosis: capture the exact native callback status/drop flag/output
presence in the isolated low-latency fixture before interpreting generic -1, and
compare lower-resolution native output using the same workload. Select a lower
live tier only after measured cost and frame continuity pass. Do not count property
acceptance or smaller dimensions alone as a lower-bandwidth result. The progressive
policy, short delivery windows, real transition continuity, physical phone/watch
routes and remote worker qualifications remain open in the main plan.
